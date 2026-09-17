//=============================================================================
// od_test_top.v
// finger_piano_od_test -- P31/P32 开漏(open-drain)IO 板级诊断顶层。
//
// 目的:在 ADS1115 完全断开、P31/P32 由外部电阻上拉到 3.3 V 的条件下,
// 用示波器/频率计直接观察两条开漏线的拉低/释放行为:
//   P31 = 约 1 kHz 方波(每 6000 个 clk 翻转一次拉低状态)
//   P32 = 约 2 kHz 方波(每 3000 个 clk 翻转一次拉低状态)
//
// 结构约束:
//   - 全工程只有 clk(P57,12 MHz)一个时钟域;
//   - 不使用分频器输出当时钟,只用 posedge clk + counter(clock-enable 语义);
//   - 输出严格 0 / Z:
//         assign p31_test = p31_drive_low ? 1'b0 : 1'bz;
//         assign p32_test = p32_drive_low ? 1'b0 : 1'bz;
//     即只在拉低时驱动 0,释放时为高阻,绝不推挽驱动 1;高电平完全来自
//     板级外部上拉电阻(不是 FPGA 内部 PULLUP,也不写 UCF PULLUP);
//   - 无外部复位引脚(UCF 只允许 P57/P31/P32),计数器用上电初值,
//     配置完成后(GSR)两路输出先处于释放态,再开始分频。
//
// Fout = SYS_CLK_HZ / (2 * HALF),HALF 为"每 HALF 个 clk 翻转一次";
// 频率参数全部来自 od_test_cfg.vh(本工程唯一配置真值源)。
//=============================================================================

`include "od_test_cfg.vh"

module od_test_top #(
    parameter integer SYS_CLK_HZ = `OD_SYS_CLK_HZ,
    parameter integer P31_HZ     = `OD_P31_HZ,
    parameter integer P32_HZ     = `OD_P32_HZ
) (
    input  wire clk,        // P57, 12 MHz 有源晶振(唯一系统时钟)

    output wire p31_test,   // P31, 开漏:0 / Z(约 1 kHz)
    output wire p32_test    // P32, 开漏:0 / Z(约 2 kHz)
);

    //-------------------------------------------------------------------------
    // 半周期拍数:每 HALF 个 clk 翻转一次"拉低"状态
    //-------------------------------------------------------------------------
    localparam integer P31_HALF = SYS_CLK_HZ / (2 * P31_HZ);
    localparam integer P32_HALF = SYS_CLK_HZ / (2 * P32_HZ);

    //-------------------------------------------------------------------------
    // P31:上电初值 = 释放(Z),counter 从 0 开始
    //-------------------------------------------------------------------------
    reg [15:0] cnt31 = 16'd0;
    reg        low31 = 1'b0;

    always @(posedge clk) begin
        if (cnt31 == (P31_HALF - 1)) begin
            cnt31 <= 16'd0;
            low31 <= ~low31;
        end else begin
            cnt31 <= cnt31 + 16'd1;
        end
    end

    //-------------------------------------------------------------------------
    // P32:上电初值 = 释放(Z),counter 从 0 开始
    //-------------------------------------------------------------------------
    reg [15:0] cnt32 = 16'd0;
    reg        low32 = 1'b0;

    always @(posedge clk) begin
        if (cnt32 == (P32_HALF - 1)) begin
            cnt32 <= 16'd0;
            low32 <= ~low32;
        end else begin
            cnt32 <= cnt32 + 16'd1;
        end
    end

    //-------------------------------------------------------------------------
    // 开漏输出:只拉低,释放为高阻;绝不输出 1
    //-------------------------------------------------------------------------
    assign p31_test = low31 ? 1'b0 : 1'bz;
    assign p32_test = low32 ? 1'b0 : 1'bz;

endmodule
