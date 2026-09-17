//=============================================================================
// od_test_top.v
// finger_piano_od_test -- P31/P32 开漏(open-drain)IO 板级诊断顶层。
//
// 目的:在 ADS1115 完全断开、P31/P32 各自用 4.7 kΩ 上拉到 3.3 V 的条件下,
// 用一个**运行时变化**的慢速相位让两路开漏输出互补,每个状态保持 1 秒:
//
//       phase = 0 : P31 = Z   , P32 = LOW   (0 s ~ 1 s)
//       phase = 1 : P31 = LOW , P32 = Z     (1 s ~ 2 s)
//
// 这样单个 bitstream 内两条线都能被分别观察:
//       Z   + 外部 4.7 kΩ 上拉 -> 板上约 3.3 V(FPGA 不驱动)
//       LOW                     -> 板上约 0 V(FPGA 拉低)
// 并且两个三态缓冲都是真实运行时信号驱动的,综合器**不能**把任何一路
// 当作常量 Z 优化掉(不是永久常量实现)。
//
// 结构约束:
//   - 全工程只有 clk(P57,12 MHz)一个时钟域,只有 posedge clk;
//   - 异步低有效复位 rst_n(P3),全工程唯一复位;
//   - 相位由 clock-enable 语义的计数器产生,不使用任何分频时钟;
//   - 输出严格 0 / Z(顶层 inout):
//         assign p31_test = p31_drive_low ? 1'b0 : 1'bz;
//         assign p32_test = p32_drive_low ? 1'b0 : 1'bz;
//     绝不推挽驱动 1;高电平完全来自板级外部上拉;
//   - UCF 不写 PULLUP/PULLDOWN,不使用 KEEP/DONT_TOUCH。
//=============================================================================

`include "od_test_cfg.vh"

module od_test_top #(
    parameter integer SYS_CLK_HZ     = `OD_SYS_CLK_HZ,
    parameter integer PHASE_HALF_CYC = `OD_PHASE_HALF_CYC   // 每多少个 clk 互换相位
) (
    input  wire clk,        // P57, 12 MHz 有源晶振(唯一系统时钟)
    input  wire rst_n,      // P3, 低有效外部复位

    inout  wire p31_test,   // P31, 开漏:0 / Z
    inout  wire p32_test    // P32, 开漏:0 / Z
);

    //-------------------------------------------------------------------------
    // 慢速相位:每 PHASE_HALF_CYC 个 clk 互换一次
    //   12 MHz 下 PHASE_HALF_CYC = 12,000,000 -> 每个状态 1 秒,周期 2 秒
    //   计数器位宽 24 bit 足够容纳 12,000,000(< 2^24)。
    //-------------------------------------------------------------------------
    reg [23:0] phase_cnt = 24'd0;
    reg        phase     = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_cnt <= 24'd0;
            phase     <= 1'b0;
        end else if (phase_cnt == (PHASE_HALF_CYC - 1)) begin
            phase_cnt <= 24'd0;
            phase     <= ~phase;
        end else begin
            phase_cnt <= phase_cnt + 24'd1;
        end
    end

    //-------------------------------------------------------------------------
    // 互补开漏驱动:phase=0 -> P31 Z / P32 LOW;phase=1 -> P31 LOW / P32 Z
    //-------------------------------------------------------------------------
    wire p31_drive_low = phase;
    wire p32_drive_low = ~phase;

    assign p31_test = p31_drive_low ? 1'b0 : 1'bz;
    assign p32_test = p32_drive_low ? 1'b0 : 1'bz;

endmodule
