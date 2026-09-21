//=============================================================================
// oled_i2c_write.v
// 极简开漏 Write-Only I2C 控制器（专为 SSD1306 OLED 显示设计）
//
// 特性：
//   1. 纯开漏驱动：FPGA 仅驱动 0 或高阻 Z，绝不主动输出 1；
//   2. 固定 100 kHz 标称速率（在 12 MHz 系统时钟下严格分频）；
//   3. 极简事务支持：
//      - start_req: 发送 START 条件并自动发送从机写地址 8'h78（7-bit 0x3C << 1），采样 ACK；
//      - write_byte_req: 发送单字节（MSB first）并采样 ACK；
//      - stop_req: 发送 STOP 条件并释放总线为高阻态。
//   4. 占用极小：无读支持、无重复起始、无总线仲裁，预计仅消耗约 30~40 Slices。
//=============================================================================

module oled_i2c_write #(
    parameter integer SYS_CLK_HZ     = 12000000,
    parameter integer I2C_BUS_HZ     = 100000,
    parameter [7:0]   I2C_ADDR_WRITE = 8'h78      // SSD1306 7-bit 0x3C 对应的写地址字节
) (
    input  wire       clk,
    input  wire       rst_n_sync,

    // 控制命令接口
    input  wire       start_req,       // 发送 START + 8'h78 地址
    input  wire       write_byte_req,  // 发送 1 字节数据
    input  wire [7:0] byte_in,         // 要发送的数据字节
    input  wire       stop_req,        // 发送 STOP

    // 状态与响应
    output reg        byte_done,       // 单周期脉冲：当前字节/START/STOP 完成
    output reg        ack_error,       // 采样到的 ACK 状态（1: NACK 异常，0: ACK 正常）

    // 物理总线（双向开漏）
    inout  wire       oled_scl,
    inout  wire       oled_sda
);

    //-------------------------------------------------------------------------
    // 时钟分频计算（四相位发生器）
    // 100 kHz 在 12 MHz 下周期为 120 拍，每相位 30 拍
    //-------------------------------------------------------------------------
    localparam integer CYCLES_PER_BIT   = SYS_CLK_HZ / I2C_BUS_HZ;
    localparam integer CYCLES_PER_PHASE = CYCLES_PER_BIT / 4;

    reg [5:0] clk_cnt;

    // 内部驱动控制（1 = 拉低为0，0 = 释放为Z）
    reg scl_drive_low;
    reg sda_drive_low;

    assign oled_scl = scl_drive_low ? 1'b0 : 1'bz;
    assign oled_sda = sda_drive_low ? 1'b0 : 1'bz;

    //-------------------------------------------------------------------------
    // 状态机定义
    //-------------------------------------------------------------------------
    localparam [3:0] ST_IDLE       = 4'd0,
                     ST_START_PRE  = 4'd1,   // SDA/SCL 释放为高
                     ST_START_SDA  = 4'd2,   // SCL=1 时 SDA 拉低（START）
                     ST_START_SCL  = 4'd3,   // SCL 拉低，准备发地址
                     ST_BIT_LOW    = 4'd4,   // SCL=0，设置 SDA 数据位
                     ST_BIT_HIGH   = 4'd5,   // SCL=1，从机采样
                     ST_ACK_LOW    = 4'd6,   // SCL=0，释放 SDA 为高阻等 ACK
                     ST_ACK_HIGH   = 4'd7,   // SCL=1，主机采样从机 ACK
                     ST_STOP_PRE   = 4'd8,   // SCL=0 时拉低 SDA
                     ST_STOP_SCL   = 4'd9,   // SCL 释放为高，SDA 仍为低
                     ST_STOP_SDA   = 4'd10;  // SCL=1 时释放 SDA 为高（STOP）

    reg [3:0] state;
    reg [7:0] shift_reg;
    reg [2:0] bit_cnt;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            state         <= ST_IDLE;
            clk_cnt       <= 6'd0;
            scl_drive_low <= 1'b0;
            sda_drive_low <= 1'b0;
            byte_done     <= 1'b0;
            ack_error     <= 1'b0;
            shift_reg     <= 8'd0;
            bit_cnt       <= 3'd0;
        end else begin
            byte_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    clk_cnt <= 6'd0;
                    if (start_req) begin
                        shift_reg <= I2C_ADDR_WRITE; // START 自动带入写地址 0x78
                        bit_cnt   <= 3'd7;
                        state     <= ST_START_PRE;
                    end else if (write_byte_req) begin
                        shift_reg <= byte_in;
                        bit_cnt   <= 3'd7;
                        state     <= ST_BIT_LOW;
                    end else if (stop_req) begin
                        state <= ST_STOP_PRE;
                    end
                end

                //-------------------------------------------------------------
                // START 发生序列：SCL=1, SDA: 1 -> 0, 然后 SCL -> 0
                //-------------------------------------------------------------
                ST_START_PRE: begin
                    sda_drive_low <= 1'b0; // 释放 SDA 为高
                    scl_drive_low <= 1'b0; // 释放 SCL 为高
                    if (clk_cnt == CYCLES_PER_PHASE - 1) begin
                        clk_cnt <= 6'd0;
                        state   <= ST_START_SDA;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_START_SDA: begin
                    sda_drive_low <= 1'b1; // SCL 为高时拉低 SDA (产生 START)
                    scl_drive_low <= 1'b0;
                    if (clk_cnt == CYCLES_PER_PHASE - 1) begin
                        clk_cnt <= 6'd0;
                        state   <= ST_START_SCL;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_START_SCL: begin
                    sda_drive_low <= 1'b1;
                    scl_drive_low <= 1'b1; // 拉低 SCL
                    if (clk_cnt == CYCLES_PER_PHASE - 1) begin
                        clk_cnt <= 6'd0;
                        state   <= ST_BIT_LOW;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                //-------------------------------------------------------------
                // 数据位发送序列（MSB 先发）
                //-------------------------------------------------------------
                ST_BIT_LOW: begin
                    scl_drive_low <= 1'b1;
                    // 设置数据位：若为0则拉低，若为1则释放Z
                    sda_drive_low <= (shift_reg[bit_cnt] == 1'b0);
                    if (clk_cnt == (CYCLES_PER_BIT / 2) - 1) begin
                        clk_cnt <= 6'd0;
                        state   <= ST_BIT_HIGH;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_BIT_HIGH: begin
                    scl_drive_low <= 1'b0; // 释放 SCL 为高让从机采样
                    if (clk_cnt == (CYCLES_PER_BIT / 2) - 1) begin
                        clk_cnt <= 6'd0;
                        if (bit_cnt == 3'd0) begin
                            state <= ST_ACK_LOW;
                        end else begin
                            bit_cnt <= bit_cnt - 1'b1;
                            state   <= ST_BIT_LOW;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                //-------------------------------------------------------------
                // ACK 接收序列（主机释放 SDA，读取从机响应）
                //-------------------------------------------------------------
                ST_ACK_LOW: begin
                    scl_drive_low <= 1'b1; // 拉低 SCL
                    sda_drive_low <= 1'b0; // 释放 SDA 为高阻输入
                    if (clk_cnt == (CYCLES_PER_BIT / 2) - 1) begin
                        clk_cnt <= 6'd0;
                        state   <= ST_ACK_HIGH;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_ACK_HIGH: begin
                    scl_drive_low <= 1'b0; // 释放 SCL 为高
                    // 在时钟高电平中间采样 ACK (0 = 从机拉低表示 ACK, 1 = NACK)
                    if (clk_cnt == (CYCLES_PER_PHASE) - 1) begin
                        ack_error <= oled_sda; // 采样 SDA 线路电平
                    end
                    if (clk_cnt == (CYCLES_PER_BIT / 2) - 1) begin
                        clk_cnt       <= 6'd0;
                        scl_drive_low <= 1'b1; // 拉低 SCL 保持总线锁定
                        byte_done     <= 1'b1; // 通知上层单字节完成
                        state         <= ST_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                //-------------------------------------------------------------
                // STOP 发生序列：SCL=0 下 SDA=0 -> SCL=1 -> SDA=1
                //-------------------------------------------------------------
                ST_STOP_PRE: begin
                    scl_drive_low <= 1'b1; // SCL=0
                    sda_drive_low <= 1'b1; // 先拉低 SDA
                    if (clk_cnt == CYCLES_PER_PHASE - 1) begin
                        clk_cnt <= 6'd0;
                        state   <= ST_STOP_SCL;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_STOP_SCL: begin
                    scl_drive_low <= 1'b0; // SCL 释放为高
                    sda_drive_low <= 1'b1; // SDA 保持拉低
                    if (clk_cnt == CYCLES_PER_PHASE - 1) begin
                        clk_cnt <= 6'd0;
                        state   <= ST_STOP_SDA;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_STOP_SDA: begin
                    scl_drive_low <= 1'b0; // SCL 保持为高
                    sda_drive_low <= 1'b0; // 释放 SDA 为高（产生 STOP 条件）
                    if (clk_cnt == CYCLES_PER_PHASE - 1) begin
                        clk_cnt   <= 8'd0;
                        byte_done <= 1'b1;
                        state     <= ST_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
