//=============================================================================
// od_test_top.v
// finger_piano_od_test -- P31/P32/P110 推挽方波板级诊断顶层。
//
// 目的:用一个 12 MHz 系统时钟产生**同相位、同频率**的 1 kHz、50% 占空比
// **推挽**方波,同时从 P31、P32、P110 三个脚输出,便于:
//   - 用示波器/频率计同时核对三个脚的输出频率与相位;
//   - 确认三个脚都能正常推挽驱动高/低(高电平由 FPGA 自己驱动)。
//
//   Fout = SYS_CLK_HZ / (2 * HALF),12 MHz / 1 kHz -> HALF = 6000 clk。
//
// 结构约束:
//   - 全工程只有 clk(P57,12 MHz)一个时钟域,只有 posedge clk;
//   - 异步低有效复位 rst_n(P3),全工程唯一复位;
//   - 分频用 clock-enable 语义的计数器,不使用任何派生时钟;
//   - 三个输出都是普通推挽输出(0/1),不建时钟域、不写进任何时钟沿;
//   - UCF 不写 PULLUP/PULLDOWN,不使用 KEEP/DONT_TOUCH。
//=============================================================================

`include "od_test_cfg.vh"

module od_test_top #(
    parameter integer SYS_CLK_HZ = `OD_SYS_CLK_HZ,
    parameter integer TONE_HZ    = `OD_TONE_HZ       // 目标方波频率
) (
    input  wire clk,        // P57, 12 MHz 有源晶振(唯一系统时钟)
    input  wire rst_n,      // P3, 低有效外部复位

    output wire p31_test,   // P31, 推挽 1 kHz 方波
    output wire p32_test,   // P32, 推挽 1 kHz 方波(与 P31 同相)
    output wire p110_test   // P110, 推挽 1 kHz 方波(与 P31 同相)
);

    //-------------------------------------------------------------------------
    // 半周期拍数:每 HALF 个 clk 翻转一次,输出 50% 占空比
    //   12 MHz / 1 kHz -> HALF = 6000(13 bit 计数器足够,6000 < 8192)
    //-------------------------------------------------------------------------
    localparam integer HALF = SYS_CLK_HZ / (2 * TONE_HZ);

    reg [12:0] cnt  = 13'd0;
    reg        wave = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= 13'd0;
            wave <= 1'b0;
        end else if (cnt == (HALF - 1)) begin
            cnt  <= 13'd0;
            wave <= ~wave;
        end else begin
            cnt <= cnt + 13'd1;
        end
    end

    //-------------------------------------------------------------------------
    // 三个脚同相位、同波形(推挽 0/1)
    //-------------------------------------------------------------------------
    assign p31_test  = wave;
    assign p32_test  = wave;
    assign p110_test = wave;

endmodule
