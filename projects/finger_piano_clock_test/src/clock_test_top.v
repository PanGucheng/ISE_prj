//=============================================================================
// clock_test_top.v
// finger_piano P7 — FPGA 启动与时钟分频板级诊断顶层。
//
// 目的(P7 计划 §4/§5/§7):用同一个 12 MHz 系统时钟产生三个精确 50% 方波,
// 上板后用示波器/频率计同时检查:
//   P110 ref_2mhz   = 2,000,000 Hz   (÷6,  每 3 个 clk 翻转)
//   P111 ref_100khz =   100,000 Hz   (÷120, 每 60 个 clk 翻转)
//   P113 ref_1khz   =     1,000 Hz   (÷12000, 每 6000 个 clk 翻转)
//
// 反推真实 FPGA 输入时钟:P110×6、P111×120、P113×12000 应一致(P7 §21)。
//
// 结构约束(P7 计划 §6):
//   - 全工程只有 clk 一个时钟域,时序逻辑一律 posedge clk / negedge rst_n;
//   - 三个输出是纯计数器分频产生的方波,**绝不**被当作任何逻辑的时钟;
//   - fout = fclk / (2*N),N 为"每 N 个 clk 翻转"。
//
// 复位(P7 §9):rst_n=0 时全部 counter 与三个输出归 0;释放后从完整半周期
// 重新开始,因此板测还能顺带验证 P3 外部复位。
//
// 位宽(P7 §8):按各自 N 取最小可用宽度,不建统一大计数器,保证 0 trim warning。
//=============================================================================

module clock_test_top (
    input  wire clk,          // P57, 12 MHz 有源晶振(唯一系统时钟)
    input  wire rst_n,        // P3, 低有效外部复位

    output reg  ref_2mhz,     // P110
    output reg  ref_100khz,   // P111
    output reg  ref_1khz      // P113
);

    // 每 N 个 clk 翻转一次 -> 输出周期 = 2*N 个 clk
    localparam [1:0]  N_2MHZ   = 2'd3;      // 2 MHz  = 12 MHz / 6
    localparam [5:0]  N_100KHZ = 6'd60;     // 100 kHz = 12 MHz / 120
    localparam [12:0] N_1KHZ   = 13'd6000;  // 1 kHz  = 12 MHz / 12000

    reg [1:0]  cnt_2mhz;
    reg [5:0]  cnt_100khz;
    reg [12:0] cnt_1khz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_2mhz   <= 2'd0;
            cnt_100khz <= 6'd0;
            cnt_1khz   <= 13'd0;
            ref_2mhz   <= 1'b0;
            ref_100khz <= 1'b0;
            ref_1khz   <= 1'b0;
        end else begin
            // 2 MHz:满 3 拍翻转、清计数,输出严格 50%
            if (cnt_2mhz == (N_2MHZ - 1'b1)) begin
                cnt_2mhz <= 2'd0;
                ref_2mhz <= ~ref_2mhz;
            end else begin
                cnt_2mhz <= cnt_2mhz + 1'b1;
            end

            // 100 kHz:满 60 拍翻转
            if (cnt_100khz == (N_100KHZ - 1'b1)) begin
                cnt_100khz <= 6'd0;
                ref_100khz <= ~ref_100khz;
            end else begin
                cnt_100khz <= cnt_100khz + 1'b1;
            end

            // 1 kHz:满 6000 拍翻转
            if (cnt_1khz == (N_1KHZ - 1'b1)) begin
                cnt_1khz <= 13'd0;
                ref_1khz <= ~ref_1khz;
            end else begin
                cnt_1khz <= cnt_1khz + 1'b1;
            end
        end
    end

endmodule
