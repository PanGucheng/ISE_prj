//=============================================================================
// i2c_master.v
// 通用 I2C 主机核心（命令级接口、开漏输出、单时钟域）—— P1 计划 A 阶段
//
// 设计边界（P1 计划冻结，不得违反）：
//   - 命令级接口：一次一个命令 START / RESTART / WRITE_BYTE / READ_BYTE / STOP，
//     master 不理解字节含义：地址字节与数据字节都走 WRITE_BYTE。
//   - 因此底层**只报告 NACK**，不区分 ADDR_NACK / DATA_NACK；细分由上层
//     controller（ads1115_ctrl / mcp4725_ctrl）根据自身 FSM 完成。
//   - 开漏输出：本模块只驱动 0 或释放（Z），**永不输出逻辑 1**；
//     总线高电平由外部上拉提供。SCL/SDA 不是时钟，全模块只有 posedge clk。
//   - 所有 SCL 时序参数（LOW/HIGH/START/STOP/BUF/timeout）**以时钟周期数
//     由实例化它的 controller 算好传入**；本模块不读 CFG_*_I2C_SPEED，
//     不做任何 Hz -> 周期换算（SYS_CLK_HZ 仅作为文档性参数保留，
//     保证 controller 与 master 的参数表一致）。
//
// 命令集（cmd[2:0]）：
//   0 START    : 起始条件（要求当前不在事务中，否则协议错误）
//   1 RESTART  : 重复起始（要求当前在事务中，否则协议错误）
//   2 WRITE    : 写一个字节 + 接收 ACK（wr_data）
//   3 READ     : 读一个字节 + 发送 ACK/NACK（nack_after=1 时主机发 NACK，
//                即“最后一个字节”；主机 NACK 不是错误，error_code 保持 0）
//   4 STOP     : 停止条件并释放总线（要求当前在事务中，否则协议错误）
//   5~7        : 协议错误
//
// 握手与结果：
//   - cmd_ready：IDLE 时为 1；命令被接受后拉低，命令完成（或出错中止）后回到 1。
//     仅在 cmd_ready==1 时 cmd_valid 被采样。
//   - error：命令以错误结束时产生**单周期脉冲**。
//   - error_code：**粘滞**，保存“最近一条已完成命令”的结果，直到下一条命令
//     被接受时清零。controller 必须在下一条命令发出前读取：
//       0 = 无错误 / 1 = NACK / 2 = timeout / 3 = 协议或内部错误
//   - WRITE 收到 NACK 时：本模块自动补发 STOP 释放总线，然后 error_code=1；
//     事务结束（再次写字节将得到协议错误 3）。READ 的主机 NACK 不是错误。
//   - timeout：任一非 IDLE 状态持续超过 TIMEOUT_CYCLES 个 clk 即中止：
//     立即释放 SDA/SCL -> error 脉冲 -> error_code=2 -> 回 IDLE。
//
// 复位（异步低有效 rst_n_sync，由外部 reset_sync 提供同步释放）：
//   sda_drive_low = scl_drive_low = 0（总线释放为 Z）、cmd_ready=1、
//   事务状态清空、error_code=0。
//
// 时序参数最小值：所有周期参数在模块内钳到 >=1；LOW/HIGH 另钳到 <=65535
//   （phase_cnt 为 32 位，其余参数不设上限钳制）。
//=============================================================================

`include "finger_piano_cfg.vh"

module i2c_master #(
    parameter integer SYS_CLK_HZ        = `SYS_CLK_HZ,  // 文档性参数；时序一律以周期数传入
    parameter integer SCL_LOW_CYCLES    = 18,           // SCL 低电平周期数（含 t_LOW 下限裕量）
    parameter integer SCL_HIGH_CYCLES   = 18,           // SCL 高电平周期数
    parameter integer T_HDSTA_CYCLES    = 8,            // t_HD;STA 起始保持
    parameter integer T_SUSTA_CYCLES    = 8,            // t_SU;STA 重复起始建立
    parameter integer T_SUSTO_CYCLES    = 8,            // t_SU;STO 停止建立
    parameter integer T_BUF_CYCLES      = 8,            // t_BUF 总线空闲时间（START 前 / STOP 后）
    parameter integer TIMEOUT_CYCLES    = 1000000       // 单条命令的看门狗上限（clk 周期）
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [2:0] cmd,
    input  wire       cmd_valid,
    input  wire [7:0] wr_data,
    input  wire       nack_after,       // READ 用：1 = 本字节为主机 NACK（最后一字节）
    output reg        cmd_ready,
    output reg  [7:0] rd_data,
    output reg        error,            // 单周期脉冲
    output reg  [1:0] error_code,       // 粘滞：0/1 NACK/2 timeout/3 protocol
    inout  wire       scl,
    inout  wire       sda
);

    //-------------------------------------------------------------------------
    // 状态与命令编码
    //-------------------------------------------------------------------------
    localparam [3:0] ST_IDLE       = 4'd0,   // 空闲：按 xact 决定释放或保持 SCL 低
                     ST_START_BUF  = 4'd1,   // START 前的 t_BUF 总线空闲等待
                     ST_START_HD   = 4'd2,   // SDA 已拉低、SCL 为高：t_HD;STA 保持
                     ST_START_LOW  = 4'd3,   // SCL 拉低，等待第一个位周期
                     ST_RST_SETUP  = 4'd4,   // 重复起始：SCL 低相位短暂稳定
                     ST_RST_SCLHI  = 4'd5,   // 重复起始：SCL 拉高后等 t_SU;STA
                     ST_BIT_LOW    = 4'd6,   // 位低相位：置 SDA，等 LOW_CYCLES
                     ST_BIT_HIGH   = 4'd7,   // 位高相位：等 HIGH_CYCLES，末尾采样
                     ST_STOP_SDA   = 4'd8,   // 停止：SCL 低时拉低 SDA
                     ST_STOP_SCLHI = 4'd9,   // 停止：SCL 拉高，等 t_SU;STO
                     ST_STOP_FREE  = 4'd10;  // 停止：释放 SDA（STOP 条件），等 t_BUF

    localparam [2:0] CMD_START   = 3'd0,
                     CMD_RESTART = 3'd1,
                     CMD_WRITE   = 3'd2,
                     CMD_READ    = 3'd3,
                     CMD_STOP    = 3'd4;

    //-------------------------------------------------------------------------
    // 周期参数钳制（常量表达式，综合期完成）
    //-------------------------------------------------------------------------
    // 周期参数钳制与紧凑位宽推导（常量函数，纯 Verilog-2001，综合期静态求解）
    //-------------------------------------------------------------------------
    function integer calc_bits;
        input integer val;
        integer v, bits;
        begin
            if (val <= 1)
                calc_bits = 1;
            else begin
                v = val;
                bits = 0;
                while (v > 0) begin
                    bits = bits + 1;
                    v = v >> 1;
                end
                calc_bits = bits;
            end
        end
    endfunction

    function integer calc_max7;
        input integer a, b, c, d, e, f, g;
        integer m1, m2;
        begin
            m1 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
            m1 = (m1 > d) ? m1 : d;
            m2 = (e > f) ? ((e > g) ? e : g) : ((f > g) ? f : g);
            calc_max7 = (m1 > m2) ? m1 : m2;
        end
    endfunction

    localparam integer LOW_SAFE =
        ((SCL_LOW_CYCLES < 1) ? 1 : ((SCL_LOW_CYCLES > 65535) ? 65535 : SCL_LOW_CYCLES));
    localparam integer HIGH_SAFE =
        ((SCL_HIGH_CYCLES < 1) ? 1 : ((SCL_HIGH_CYCLES > 65535) ? 65535 : SCL_HIGH_CYCLES));
    localparam integer HDSTA_SAFE   = ((T_HDSTA_CYCLES  < 1) ? 1 : T_HDSTA_CYCLES);
    localparam integer SUSTA_SAFE   = ((T_SUSTA_CYCLES  < 1) ? 1 : T_SUSTA_CYCLES);
    localparam integer SUSTO_SAFE   = ((T_SUSTO_CYCLES  < 1) ? 1 : T_SUSTO_CYCLES);
    localparam integer BUF_SAFE     = ((T_BUF_CYCLES    < 1) ? 1 : T_BUF_CYCLES);
    localparam integer TIMEOUT_SAFE = ((TIMEOUT_CYCLES  < 1) ? 1 : TIMEOUT_CYCLES);

    localparam integer PHASE_MAX    = calc_max7(LOW_SAFE, HIGH_SAFE, HDSTA_SAFE, SUSTA_SAFE, SUSTO_SAFE, BUF_SAFE, 2);
    localparam integer PHASE_BITS   = calc_bits(PHASE_MAX);
    localparam integer TIMEOUT_BITS = calc_bits(TIMEOUT_SAFE);

    //-------------------------------------------------------------------------
    // 状态寄存器
    //-------------------------------------------------------------------------
    reg [3:0]              state;
    reg                    xact;             // 1 = 事务进行中（START 之后、STOP/中止之前）
    reg [7:0]              shifter;          // WRITE：待发字节 / READ：移入字节
    reg [3:0]              bit_i;            // 0..7 数据位，8 = ACK/NACK 槽
    reg                    is_read;          // 当前命令是 READ
    reg                    rd_nack;          // READ 的 nack_after 捕获
    reg                    aborting;         // 1 = 正在为 NACK 补发 STOP
    reg [PHASE_BITS-1:0]   phase_cnt;        // 相位内倒计数 (按参数动态推导紧凑位宽)
    reg [TIMEOUT_BITS-1:0] timeout_cnt;      // 当前命令已消耗周期 (看门狗紧凑位宽)
    reg                    scl_drive_low;
    reg                    sda_drive_low;

    wire phase_done      = (phase_cnt == {{(PHASE_BITS-1){1'b0}}, 1'b1});
    wire timeout_expired = (timeout_cnt >= TIMEOUT_SAFE[TIMEOUT_BITS-1:0]);

    // 开漏驱动：只输出 0 或 Z，绝不输出 1；高电平来自外部上拉。
    assign scl = scl_drive_low ? 1'b0 : 1'bz;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    //-------------------------------------------------------------------------
    // 主 FSM
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            state         <= ST_IDLE;
            xact          <= 1'b0;
            shifter       <= 8'd0;
            bit_i         <= 4'd0;
            is_read       <= 1'b0;
            rd_nack       <= 1'b0;
            aborting      <= 1'b0;
            phase_cnt     <= {PHASE_BITS{1'b0}};
            timeout_cnt   <= {TIMEOUT_BITS{1'b0}};
            scl_drive_low <= 1'b0;      // 复位后总线释放
            sda_drive_low <= 1'b0;
            cmd_ready     <= 1'b1;
            rd_data       <= 8'd0;
            error         <= 1'b0;
            error_code    <= 2'd0;
        end else begin
            error <= 1'b0;              // error 默认单周期脉冲

            if (state != ST_IDLE) begin
                //-----------------------------------------------------------------
                // 看门狗：任何命令超过 TIMEOUT_CYCLES 立即中止并释放总线
                //-----------------------------------------------------------------
                if (timeout_expired) begin
                    state         <= ST_IDLE;
                    xact          <= 1'b0;
                    aborting      <= 1'b0;
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    cmd_ready     <= 1'b1;
                    error         <= 1'b1;
                    error_code    <= 2'd2;
                end else begin
                    timeout_cnt <= timeout_cnt + 1'b1;

                    case (state)

                    // START 第一步：SCL 高、SDA 高，等待 t_BUF（总线空闲）
                    ST_START_BUF: begin
                        if (phase_done) begin
                            sda_drive_low <= 1'b1;      // SCL 高电平期间 SDA 下落 = START
                            phase_cnt     <= HDSTA_SAFE[PHASE_BITS-1:0];
                            state         <= ST_START_HD;
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // SDA 已低：保持 t_HD;STA 后拉低 SCL
                    ST_START_HD: begin
                        if (phase_done) begin
                            scl_drive_low <= 1'b1;
                            phase_cnt     <= LOW_SAFE[PHASE_BITS-1:0];
                            state         <= ST_START_LOW;
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // START/RESTART 完成：SCL 保持低，SDA 释放（在 SCL 低电平
                    // 期间变化，合法；必须释放以便 READ 时从机驱动数据位），
                    // 回 IDLE 等下一条命令
                    ST_START_LOW: begin
                        if (phase_done) begin
                            sda_drive_low <= 1'b0;
                            state         <= ST_IDLE;
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // 重复起始：SCL 低相位短暂稳定（SDA 保持释放为高）
                    ST_RST_SETUP: begin
                        if (phase_done) begin
                            scl_drive_low <= 1'b0;      // SCL 释放 -> 高
                            phase_cnt     <= SUSTA_SAFE[PHASE_BITS-1:0];
                            state         <= ST_RST_SCLHI;
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // 重复起始：SCL 高、SDA 高，等 t_SU;STA 后拉低 SDA
                    ST_RST_SCLHI: begin
                        if (phase_done) begin
                            sda_drive_low <= 1'b1;      // SCL 高电平期间 SDA 下落
                            phase_cnt     <= HDSTA_SAFE[PHASE_BITS-1:0];
                            state         <= ST_START_HD;   // 与 START 共用保持/拉低序列
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // 位低相位：按位角色置 SDA（数据在 SCL 低电平期间变化）
                    ST_BIT_LOW: begin
                        if (bit_i == 4'd8) begin
                            // ACK/NACK 槽
                            if (is_read) begin
                                sda_drive_low <= ~rd_nack;  // 主机 ACK=拉低；NACK=释放
                            end else begin
                                sda_drive_low <= 1'b0;      // 写字节：释放，等待从机 ACK
                            end
                        end else if (is_read) begin
                            sda_drive_low <= 1'b0;          // 读数据位：主机全程释放
                        end else begin
                            sda_drive_low <= ~shifter[7 - bit_i[2:0]];  // 写数据位，MSB first
                        end

                        if (phase_done) begin
                            scl_drive_low <= 1'b0;          // SCL 释放 -> 高
                            phase_cnt     <= HIGH_SAFE[PHASE_BITS-1:0];
                            state         <= ST_BIT_HIGH;
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // 位高相位：结束沿上采样/推进
                    ST_BIT_HIGH: begin
                        if (phase_done) begin
                            scl_drive_low <= 1'b1;          // SCL 拉低
                            phase_cnt     <= LOW_SAFE[PHASE_BITS-1:0];
                            bit_i         <= bit_i + 4'd1;
                            if (bit_i == 4'd8) begin
                                // 第 9 个时钟（ACK/NACK 槽）结束
                                sda_drive_low <= 1'b0;      // SDA 释放
                                if (is_read) begin
                                    rd_data <= shifter;     // 8 位移移完成
                                    state   <= ST_IDLE;     // 主机 NACK 不算错误
                                end else if (sda == 1'b1) begin
                                    // 写字节被 NACK：补发 STOP，事务结束（error_code=1）
                                    aborting  <= 1'b1;
                                    phase_cnt <= LOW_SAFE[PHASE_BITS-1:0];
                                    state     <= ST_STOP_SDA;
                                end else begin
                                    state <= ST_IDLE;       // 写字节 ACK 成功
                                end
                            end else begin
                                if (is_read) begin
                                    shifter <= {shifter[6:0], sda};  // SCL 高电平末尾采样
                                end
                                state <= ST_BIT_LOW;
                            end
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // 停止：SCL 低电平期间拉低 SDA（此时 SCL 刚落，SDA 晚一拍，
                    // 避免 SDA/SCL 同沿下落造成条件歧义）
                    ST_STOP_SDA: begin
                        sda_drive_low <= 1'b1;
                        if (phase_done) begin
                            scl_drive_low <= 1'b0;          // SCL 释放 -> 高
                            phase_cnt     <= SUSTO_SAFE[PHASE_BITS-1:0];
                            state         <= ST_STOP_SCLHI;
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // 停止：SCL 高、SDA 低，等 t_SU;STO 后释放 SDA
                    ST_STOP_SCLHI: begin
                        if (phase_done) begin
                            sda_drive_low <= 1'b0;          // SCL 高电平期间 SDA 上升 = STOP
                            phase_cnt     <= BUF_SAFE[PHASE_BITS-1:0];
                            state         <= ST_STOP_FREE;
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    // 停止：等 t_BUF 总线空闲后真正结束事务
                    ST_STOP_FREE: begin
                        if (phase_done) begin
                            xact      <= 1'b0;
                            aborting  <= 1'b0;
                            state     <= ST_IDLE;
                            cmd_ready <= 1'b1;
                            error     <= aborting;             // 仅 NACK 补发的 STOP 报错
                            error_code<= aborting ? 2'd1 : 2'd0;
                        end else begin
                            phase_cnt <= phase_cnt - 1'b1;
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                    end

                    endcase
                end
            end else begin
                //-----------------------------------------------------------------
                // ST_IDLE：总线按 xact 保持（事务中：SCL 低 + SDA 释放；
                // 空闲：两线全部释放），接受新命令
                //-----------------------------------------------------------------
                cmd_ready <= 1'b1;

                if (cmd_valid) begin
                    error_code  <= 2'd0;        // 新命令清空粘滞错误码
                    timeout_cnt <= {TIMEOUT_BITS{1'b0}};

                    case (cmd)

                    CMD_START: begin
                        if (!xact) begin
                            xact      <= 1'b1;
                            cmd_ready <= 1'b0;
                            phase_cnt <= BUF_SAFE[PHASE_BITS-1:0];
                            state     <= ST_START_BUF;
                        end else begin
                            error      <= 1'b1;     // 事务中重复 START：协议错误
                            error_code <= 2'd3;
                        end
                    end

                    CMD_RESTART: begin
                        if (xact) begin
                            cmd_ready <= 1'b0;
                            phase_cnt <= 2'd2;     // RST_SETUP 稳定一拍
                            state     <= ST_RST_SETUP;
                        end else begin
                            error      <= 1'b1;     // 无事务时的 RESTART：协议错误
                            error_code <= 2'd3;
                        end
                    end

                    CMD_WRITE, CMD_READ: begin
                        if (xact) begin
                            cmd_ready <= 1'b0;
                            is_read   <= (cmd == CMD_READ);
                            rd_nack   <= nack_after;
                            shifter   <= wr_data;
                            bit_i     <= 4'd0;
                            aborting  <= 1'b0;
                            state     <= ST_BIT_LOW;
                        end else begin
                            error      <= 1'b1;     // 无事务时读写一字节：协议错误
                            error_code <= 2'd3;
                        end
                    end

                    CMD_STOP: begin
                        if (xact) begin
                            cmd_ready <= 1'b0;
                            aborting  <= 1'b0;
                            phase_cnt <= LOW_SAFE[PHASE_BITS-1:0];
                            state     <= ST_STOP_SDA;
                        end else begin
                            error      <= 1'b1;     // 无事务时的 STOP：协议错误
                            error_code <= 2'd3;
                        end
                    end

                    default: begin
                        error      <= 1'b1;         // 非法命令编码
                        error_code <= 2'd3;
                    end

                    endcase
                end
            end
        end
    end

endmodule
