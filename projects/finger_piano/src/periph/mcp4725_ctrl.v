//=============================================================================
// mcp4725_ctrl.v
// MCP4725 DAC 控制器(standalone,不进顶层)—— P1 计划 C 阶段
//
// 协议依据:doc/MCP4725.pdf(Microchip DS22039C_CN),不采用网络示例:
//   - 器件地址:1100 + A2A1A0,默认 A2A1A0=000 -> 7'h60(参数化可改);
//   - **只允许 Fast Write**(6.1.1:C2=0,C1=0,C0=X):
//       START | addr+W | ACK | {C2C1C0=000, PD1=0, PD0=0, D[11:8]} | ACK
//             | D[7:0] | ACK | STOP
//     即首数据字节高半字节恒为 4'b0000,例如 12'hABC -> 8'h0A,8'hBC;
//   - **禁止写 EEPROM**(典型 25 ms / 最大 50 ms,且有擦写寿命;EEPROM 写
//     命令 C2C1C0 含 011 组合,本模块首字节 [7:5] 恒 000,结构上不可能发生);
//   - PD1PD0 = 00(正常功耗模式);VOUT 在第三字节的 ACK 下降沿更新
//     (图 6-1 注 2),对 8 kS/s 音频流水线即"字节发完即生效";
//   - VOUT = VDD * D / 4096(由外部电路保证,数字侧只发码)。
//
// 缓冲策略(计划冻结):**一项 pending 槽 + overrun 标志,禁止
// latest-value-wins**。DDS 每个 8 kS/s 样点都有意义,静默丢点会造成
// 波形失真:
//   - dac_code_ready = pending 空闲;
//   - valid && ready   -> 样点进入唯一 pending 槽,事务发完才清
//     (传输期间 ready=0,不双缓冲);
//   - valid && !ready  -> 置 dac_overrun(粘滞,直到复位),新样点被拒绝,
//     **不覆盖**已挂起样点;
//   - 正常 8 kS/s 必须 0 丢样 / 0 overrun(吞吐 TB 用真实 12 MHz 验证)。
// 事务出错时该样点被丢弃并报错(pending 清空),由上层决定重发。
//
// 错误码(error_code,粘滞到下一次事务成功完成时清零):
//   0 = 无错误;1 = 地址字节 NACK;2 = 数据字节 NACK;
//   3 = I2C master 超时;4 = 其它(协议异常)
// NACK 时 master 已自动补 STOP,controller 再补一次 STOP 收尾,
// 然后 pulse dac_error 回 IDLE。
//
// ENABLE = 0:不生成任何逻辑,不传输、不置任何标志;
//   dac_code_ready 恒 0(无人接收),SCL/SDA 保持 Z。
//
// 时序参数分层规则(与 ads1115_ctrl 相同,但 BUF 用 MCP 手册值):
//   默认 SYS_CLK_HZ == 12_000_000 且 I2C_HZ == 333_333 -> 18+18 = 36 拍
//   (actual 333333.333 Hz);其它 I2C_HZ 走强制公式(先除后取整):
//     LOW = ceil(1300ns)、PERIOD = ceil(SYS/I2C)、HIGH = max(ceil(600ns), PERIOD-LOW)
//   t_HDSTA/t_SUSTA/t_SUSTO >= 600 ns;**t_BUF >= 1300 ns(MCP 比 ADS 更严)**。
//=============================================================================

`include "finger_piano_cfg.vh"

module mcp4725_ctrl #(
    parameter integer ENABLE     = `CFG_ENABLE_MCP4725,
    parameter integer I2C_ADDR   = `CFG_MCP4725_ADDR,   // 7 位器件地址
    parameter integer SYS_CLK_HZ = `SYS_CLK_HZ,
    parameter integer I2C_HZ     = `CFG_DAC_I2C_SPEED
) (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire [11:0] dac_code,        // 待发送的 12 bit DAC 码
    input  wire        dac_code_valid,  // 生产者样点有效
    output wire        dac_code_ready,  // pending 槽空闲可接收
    output wire        dac_busy,        // I2C 事务进行中
    output wire        dac_error,       // 事务失败,单周期脉冲
    output wire        dac_overrun,     // 粘滞:pending 满时又被推样点
    output wire [2:0]  error_code,      // 粘滞,见文件头
    inout  wire        dac_i2c_scl,
    inout  wire        dac_i2c_sda
);

    //-------------------------------------------------------------------------
    // ENABLE = 0:纯直连关闭分支,零 I2C 活动,总线无驱动(保持 Z)
    //-------------------------------------------------------------------------
    generate
        if (ENABLE == 0) begin : GEN_OFF

            assign dac_code_ready = 1'b0;   // 关闭态无人接收(不置 overrun)
            assign dac_busy       = 1'b0;
            assign dac_error      = 1'b0;
            assign dac_overrun    = 1'b0;
            assign error_code     = 3'd0;

        end else begin : GEN_DAC

    //-------------------------------------------------------------------------
    // I2C 时序参数(强制公式 + 默认 18+18 分层规则;BUF 用 MCP 的 1300ns)
    //-------------------------------------------------------------------------
    localparam integer Q_LOW   = 1000000000 / 1300;    // 拟合 1e9/1300ns
    localparam integer Q_HIGH  = 1000000000 / 600;     // 拟合 1e9/600ns
    localparam integer LOW_F   = (SYS_CLK_HZ + Q_LOW  - 1) / Q_LOW;    // >= tLOW
    localparam integer PERIOD_F= (SYS_CLK_HZ + I2C_HZ - 1) / I2C_HZ;   // 目标周期
    localparam integer HIGH_MIN= (SYS_CLK_HZ + Q_HIGH - 1) / Q_HIGH;   // >= tHIGH
    localparam integer HIGH_DIFF = PERIOD_F - LOW_F;
    localparam integer HIGH_F  = (HIGH_MIN > HIGH_DIFF) ? HIGH_MIN : HIGH_DIFF;
    localparam integer T600    = (SYS_CLK_HZ + Q_HIGH - 1) / Q_HIGH;   // 600ns 档
    localparam integer BUF_F   = (SYS_CLK_HZ + Q_LOW - 1) / Q_LOW;     // MCP tBUF=1300ns

    localparam integer SCL_LOW_CYC =
        ((SYS_CLK_HZ == 12000000) && (I2C_HZ == 333333)) ? 18 : LOW_F;
    localparam integer SCL_HIGH_CYC =
        ((SYS_CLK_HZ == 12000000) && (I2C_HZ == 333333)) ? 18 : HIGH_F;
    // 单条 master 命令最长 9*(LOW+HIGH) 拍,超时给 36 个位周期 + 余量
    localparam integer MASTER_TIMEOUT = 36 * (SCL_LOW_CYC + SCL_HIGH_CYC) + 1024;

    //-------------------------------------------------------------------------
    // 地址与 Fast Write 常量
    //-------------------------------------------------------------------------
    localparam [6:0] ADDR_B = I2C_ADDR % 128;

    // i2c_master 命令编码
    localparam [2:0] M_START = 3'd0,
                     M_WRITE = 3'd2,
                     M_STOP  = 3'd4;

    // FSM 状态
    localparam [3:0] S_IDLE     = 4'd0,
                     S_START    = 4'd1,
                     S_AW       = 4'd2,   // 地址字节 (addr+W)
                     S_B1       = 4'd3,   // {0000, D[11:8]}
                     S_B2       = 4'd4,   // D[7:0]
                     S_STOP     = 4'd5,   // STOP,释放 pending 槽
                     S_ERR_STOP = 4'd6,   // 错误收尾:补发 STOP
                     S_ERR      = 4'd7;   // dac_error 脉冲并回 IDLE

    //-------------------------------------------------------------------------
    // 状态寄存器(先声明后使用)
    //-------------------------------------------------------------------------
    reg [3:0]  state;
    reg        issued;
    reg [1:0]  iss_cnt;       // 发出后的 clk 计数(检测"即时完成")
    reg        saw_busy;
    reg [11:0] code_q;        // 事务中正在发送的样点
    reg        pend_valid;    // pending 槽占用
    reg [11:0] pend_code;
    reg        overrun_q;
    reg [2:0]  err_code_q;
    reg [2:0]  st_errcls;

    reg        r_busy;
    reg        r_error;
    reg [2:0]  r_errcode;

    // master 命令接口
    reg        m_valid;
    reg  [2:0] m_cmd;
    reg  [7:0] m_wdata;
    wire       m_ready;
    wire [1:0] m_ecode;

    i2c_master #(
        .SYS_CLK_HZ        (SYS_CLK_HZ),
        .SCL_LOW_CYCLES    (SCL_LOW_CYC),
        .SCL_HIGH_CYCLES   (SCL_HIGH_CYC),
        .T_HDSTA_CYCLES    (T600),
        .T_SUSTA_CYCLES    (T600),
        .T_SUSTO_CYCLES    (T600),
        .T_BUF_CYCLES      (BUF_F),
        .TIMEOUT_CYCLES    (MASTER_TIMEOUT)
    ) u_i2c (
        .clk        (clk),
        .rst_n_sync (rst_n_sync),
        .cmd        (m_cmd),
        .cmd_valid  (m_valid),
        .wr_data    (m_wdata),
        .nack_after (1'b0),
        .cmd_ready  (m_ready),
        .rd_data    (),
        .error      (),
        .error_code (m_ecode),
        .scl        (dac_i2c_scl),
        .sda        (dac_i2c_sda)
    );

    // 每步命令字段(组合)
    reg [2:0] st_cmd;
    reg [7:0] st_wdata;
    always @(*) begin
        st_cmd   = M_START;
        st_wdata = 8'h00;
        case (state)
            S_START:    st_cmd = M_START;
            S_AW:       begin st_cmd = M_WRITE;  st_wdata = {ADDR_B, 1'b0};      end
            // Fast Write 字节 1:C2=0,C1=0(命令码),C0=0(任意位发 0),
            // PD1=PD0=0(正常模式) -> 高半字节恒 4'b0000
            S_B1:       begin st_cmd = M_WRITE;  st_wdata = {4'b0000, code_q[11:8]}; end
            S_B2:       begin st_cmd = M_WRITE;  st_wdata = code_q[7:0];       end
            S_STOP:     st_cmd = M_STOP;
            S_ERR_STOP: st_cmd = M_STOP;
            default:    ;
        endcase
    end

    // 错误分类:地址字节 NACK -> 1;数据字节 NACK -> 2;master 超时 -> 3;其它 -> 4
    always @(*) begin
        case (state)
            S_AW:
                st_errcls = (m_ecode == 2'd1) ? 3'd1 :
                            ((m_ecode == 2'd2) ? 3'd3 : 3'd4);
            S_B1, S_B2:
                st_errcls = (m_ecode == 2'd1) ? 3'd2 :
                            ((m_ecode == 2'd2) ? 3'd3 : 3'd4);
            default:
                st_errcls = (m_ecode == 2'd2) ? 3'd3 : 3'd4;
        endcase
    end

    //-------------------------------------------------------------------------
    // 主时序
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            state      <= S_IDLE;
            issued     <= 1'b0;
            iss_cnt    <= 2'd0;
            saw_busy   <= 1'b0;
            code_q     <= 12'h800;
            pend_valid <= 1'b0;
            pend_code  <= 12'h800;
            overrun_q  <= 1'b0;
            err_code_q <= 3'd0;
            r_busy     <= 1'b0;
            r_error    <= 1'b0;
            r_errcode  <= 3'd0;
            m_valid    <= 1'b0;
            m_cmd      <= 3'd0;
            m_wdata    <= 8'h00;
        end else begin
            r_error <= 1'b0;            // 单周期脉冲

            //-----------------------------------------------------------------
            // pending 槽接收(与 FSM 并行):满时推入 -> overrun,不覆盖
            //-----------------------------------------------------------------
            if (dac_code_valid && !pend_valid) begin
                pend_code  <= dac_code;
                pend_valid <= 1'b1;
            end else if (dac_code_valid && pend_valid) begin
                overrun_q <= 1'b1;      // 粘滞;新样点被拒绝(不覆盖)
            end

            case (state)

            S_IDLE: begin
                if (pend_valid) begin
                    code_q <= pend_code;    // 锁存后 pending 仍占用(发完才清)
                    r_busy <= 1'b1;
                    state  <= S_START;
                end
            end

            // 错误收尾:pulse dac_error,丢弃出错样点(pending 清空,由上层
            // 决定重发;MCP4725 Fast Write 在第三字节 ACK 前不生效,NACK 帧
            // 重发安全),粘滞错误码保留
            S_ERR: begin
                r_error    <= 1'b1;
                r_errcode  <= err_code_q;
                r_busy     <= 1'b0;
                pend_valid <= 1'b0;
                state      <= S_IDLE;
            end

            //-------------------------------------------------------------
            // 命令状态:发命令 -> 等 master 完成 -> 检查结果
            // 完成判定双路:ready 回落再回 1(正常长命令),或发出 >=2 拍
            // 后 ready 一直为 1(master 即时拒绝协议错误命令)。
            //-------------------------------------------------------------
            default: begin
                if (!issued) begin
                    if (m_ready) begin
                        m_valid <= 1'b1;
                        m_cmd   <= st_cmd;
                        m_wdata <= st_wdata;
                        issued  <= 1'b1;
                        iss_cnt <= 2'd0;
                    end
                end else begin
                    m_valid <= 1'b0;
                    iss_cnt <= iss_cnt + 2'd1;
                    if (!m_ready) begin
                        saw_busy <= 1'b1;
                    end else if (saw_busy || (iss_cnt >= 2'd2)) begin
                        issued   <= 1'b0;
                        saw_busy <= 1'b0;
                        if (state == S_ERR_STOP) begin
                            state <= S_ERR;         // 收尾 STOP:无视结果
                        end else if (m_ecode != 2'd0) begin
                            err_code_q <= st_errcls;
                            state      <= S_ERR_STOP;
                        end else if (state == S_STOP) begin
                            pend_valid <= 1'b0;     // 样点发完:释放 pending 槽
                            r_errcode  <= 3'd0;     // 成功事务清粘滞错误码
                            r_busy     <= 1'b0;
                            state      <= S_IDLE;
                        end else begin
                            // 成功:按 Fast Write 流水推进
                            if (state == S_START) begin
                                state <= S_AW;
                            end else if (state == S_AW) begin
                                state <= S_B1;
                            end else if (state == S_B1) begin
                                state <= S_B2;
                            end else begin          // S_B2
                                state <= S_STOP;
                            end
                        end
                    end
                end
            end

            endcase
        end
    end

    //-------------------------------------------------------------------------
    // 输出连线
    //-------------------------------------------------------------------------
    assign dac_code_ready = ~pend_valid;
    assign dac_busy       = r_busy;
    assign dac_error      = r_error;
    assign dac_overrun    = overrun_q;
    assign error_code     = r_errcode;

        end
    endgenerate

endmodule
