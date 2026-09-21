//=============================================================================
// bin_to_dec_volt.v
// ADS1115 16-bit 原始码转十进制电压 (伏特, 4 位小数)
//
// 量程规格 (PGA = 001, +-4.096 V):
//   1 LSB = 4.096 V / 32768 = 125 uV
//   单端有效范围: 0 ~ 32767 (0.0000 V ~ 4.0958 V)
//   负数底噪/偏置: 钳位至 0 V
//
// 算法:
//   1) 微伏计算: uV = raw * 125 = (raw << 7) - (raw << 1) - raw (无需乘法器)
//      最大 uV = 32767 * 125 = 4,095,875 (22 位无符号数, 2^22 = 4,194,304)
//   2) 22 拍 Double-Dabble (Shift-and-Add-3) 二进制转 BCD 转换器
//   3) 产出 7 个 BCD 数字:
//      [d_volt] . [d_tenths] [d_hundredths] [d_thousandths] [d_tenthousands] ...
//
// 时钟周期: 22 拍转换 + 1 拍锁存, 12 MHz 下耗时约 1.92 us (远小于 100 ms 发送周期)
//=============================================================================

`timescale 1ns / 1ps

module bin_to_dec_volt (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        start,
    input  wire [15:0] raw_code,
    output reg         done,
    output reg  [3:0]  d_volt,           // 整数位 0~4
    output reg  [3:0]  d_tenths,         // 十分位 0~9
    output reg  [3:0]  d_hundredths,     // 百分位 0~9
    output reg  [3:0]  d_thousandths,    // 千分位 0~9
    output reg  [3:0]  d_tenthousands    // 万分位 0~9
);

    // 状态机状态
    localparam [1:0] S_IDLE  = 2'd0,
                     S_CONV  = 2'd1,
                     S_DONE  = 2'd2;

    reg [1:0] state;
    reg [4:0] step_cnt; // 0 ~ 21 (共 22 步)

    // 50-bit 移位寄存器: [49:22] 为 28-bit BCD (7 个数字), [21:0] 为 22-bit 二进制
    reg [49:0] shift_reg;

    // BCD 调整逻辑 (大于等于 5 则加 3)
    // 注意: d6 对应整数伏特 (最大为 4), 加 3 调整后最大为 4, 永远不需要第 3 位 (MSB 恒为 0)
    wire [2:0] adj_d6 = (shift_reg[49:46] >= 4'd5) ? (shift_reg[48:46] + 3'd3) : shift_reg[48:46];
    wire [3:0] adj_d5 = (shift_reg[45:42] >= 4'd5) ? (shift_reg[45:42] + 4'd3) : shift_reg[45:42];
    wire [3:0] adj_d4 = (shift_reg[41:38] >= 4'd5) ? (shift_reg[41:38] + 4'd3) : shift_reg[41:38];
    wire [3:0] adj_d3 = (shift_reg[37:34] >= 4'd5) ? (shift_reg[37:34] + 4'd3) : shift_reg[37:34];
    wire [3:0] adj_d2 = (shift_reg[33:30] >= 4'd5) ? (shift_reg[33:30] + 4'd3) : shift_reg[33:30];
    wire [3:0] adj_d1 = (shift_reg[29:26] >= 4'd5) ? (shift_reg[29:26] + 4'd3) : shift_reg[29:26];
    wire [3:0] adj_d0 = (shift_reg[25:22] >= 4'd5) ? (shift_reg[25:22] + 4'd3) : shift_reg[25:22];

    wire [26:0] adj_bcd = {adj_d6, adj_d5, adj_d4, adj_d3, adj_d2, adj_d1, adj_d0};

    // 微伏值乘法 (无硬件乘法器: 128 - 2 - 1)
    wire [21:0] u_volt;
    wire [21:0] raw_ext = (raw_code[15] == 1'b1) ? 22'd0 : {7'd0, raw_code[14:0]};
    assign u_volt = (raw_ext << 7) - (raw_ext << 1) - raw_ext;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            state          <= S_IDLE;
            step_cnt       <= 5'd0;
            shift_reg      <= 50'd0;
            done           <= 1'b0;
            d_volt         <= 4'd0;
            d_tenths       <= 4'd0;
            d_hundredths   <= 4'd0;
            d_thousandths  <= 4'd0;
            d_tenthousands <= 4'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        step_cnt  <= 5'd0;
                        shift_reg <= {28'd0, u_volt};
                        state     <= S_CONV;
                    end
                end

                S_CONV: begin
                    // 移位与加 3
                    shift_reg <= {adj_bcd[26:0], shift_reg[21:0], 1'b0};
                    if (step_cnt == 5'd21) begin
                        state <= S_DONE;
                    end else begin
                        step_cnt <= step_cnt + 5'd1;
                    end
                end

                S_DONE: begin
                    // 移位结束, 锁存 BCD 输出
                    d_volt         <= shift_reg[49:46];
                    d_tenths       <= shift_reg[45:42];
                    d_hundredths   <= shift_reg[41:38];
                    d_thousandths  <= shift_reg[37:34];
                    d_tenthousands <= shift_reg[33:30];
                    done           <= 1'b1;
                    state          <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
