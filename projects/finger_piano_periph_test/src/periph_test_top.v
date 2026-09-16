//=============================================================================
// periph_test_top.v
// P9 ADS1115 / MCP4725 板级诊断顶层(P9 计划 §7~§18)。
//
// 职责只有:reset + ADS1115 controller + MCP4725 诊断源/controller +
// 三个状态脚。**不**实例化 sensor frontend、pressure processor、七音 DDS、
// 显示、UART(诊断工程越小越好,§7)。
//
//   rst_n -> reset_sync -> rst_n_sync --+--> ads1115_ctrl  (P31/P32)
//                                       +--> dac_diag_source -> mcp4725_ctrl
//                                                            (P102/P103)
//   dbg_alive (P110):~1 Hz heartbeat 方波(HEARTBEAT_HALF_CYC 拍翻转),
//                     只证明 FPGA configured / clock running / reset
//                     released,**不代表** ADC/DAC PASS(§8);
//   dbg_adc   (P111):每个完整 ADS1115 三通道帧翻转一次(§9,板上易观察,
//                     不输出单拍 adc_sample_valid);
//   dbg_error (P113):sticky error = adc_error | dac_error | dac_overrun,
//                     一旦置位保持到下一次 reset(§10)。
//
// 两条 I2C 物理独立(P9 §5);开漏 0/Z(P9 §6);全工程只有 clk 一个
// 时钟域;HEARTBEAT_HALF_CYC 是板上 1 Hz 方波的真实常量(6,000,000 拍
// 翻转),仿真可用参数覆盖以加速(TB 传递)。
//
// DAC_TEST_MODE(P9 §13):0=0x800 / 1=0x400 / 2=0xC00 / 3=1 kHz 波形,
// compile-time 参数,不加 mode pin;正式 finger_piano 工程零影响。
//=============================================================================

`include "finger_piano_cfg.vh"

module periph_test_top #(
    parameter integer HEARTBEAT_HALF_CYC = 6000000,   // 1 Hz 方波 @ 12 MHz
    parameter integer DAC_TEST_MODE      = 0
) (
    input  wire       clk,           // P57,12 MHz,唯一时钟
    input  wire       rst_n,         // P3,外部异步低有效复位

    inout  wire       adc_i2c_scl,   // P31/P32,ADS1115 独立总线
    inout  wire       adc_i2c_sda,

    inout  wire       dac_i2c_scl,   // P102/P103,MCP4725 独立总线
    inout  wire       dac_i2c_sda,

    output reg        dbg_alive,     // P110 heartbeat
    output reg        dbg_adc,       // P111 ADC frame toggle
    output reg        dbg_error      // P113 sticky error
);

    //-------------------------------------------------------------------------
    // 复位同步(全工程唯一 reset_sync 实例)
    //-------------------------------------------------------------------------
    wire rst_n_sync;

    reset_sync u_reset_sync (
        .clk        (clk),
        .rst_n      (rst_n),
        .rst_n_sync (rst_n_sync)
    );

    //-------------------------------------------------------------------------
    // ADS1115 三通道轮询(P9 §11:0x48 / PGA +-4.096 V / 860 SPS /
    // single-shot / OS polling,与正式工程同一 driver,行为零修改)
    //-------------------------------------------------------------------------
    wire [15:0] adc_ch0_raw;
    wire [15:0] adc_ch1_raw;
    wire [15:0] adc_ch2_raw;
    wire        adc_sample_valid;
    wire        adc_busy;
    wire        adc_error;
    wire [2:0]  adc_error_code;

    ads1115_ctrl #(
        .ENABLE (1)
    ) u_ads1115 (
        .clk              (clk),
        .rst_n_sync       (rst_n_sync),
        .adc_i2c_scl      (adc_i2c_scl),
        .adc_i2c_sda      (adc_i2c_sda),
        .adc_ch0_raw      (adc_ch0_raw),
        .adc_ch1_raw      (adc_ch1_raw),
        .adc_ch2_raw      (adc_ch2_raw),
        .adc_sample_valid (adc_sample_valid),
        .adc_busy         (adc_busy),
        .adc_error        (adc_error),
        .error_code       (adc_error_code)
    );

    //-------------------------------------------------------------------------
    // DAC 诊断源 + MCP4725 controller(Fast Write only,不开 EEPROM,§17)
    //-------------------------------------------------------------------------
    wire [11:0] dac_code;
    wire        dac_code_valid;
    wire        dac_busy;
    wire        dac_error;
    wire        dac_overrun;

    dac_diag_source #(
        .SYS_CLK_HZ     (`SYS_CLK_HZ),
        .SAMPLE_RATE_HZ (`CFG_DAC_SAMPLE_RATE),
        .TEST_MODE      (DAC_TEST_MODE)
    ) u_diag_src (
        .clk            (clk),
        .rst_n_sync     (rst_n_sync),
        .dac_code       (dac_code),
        .dac_code_valid (dac_code_valid)
    );

    mcp4725_ctrl #(
        .ENABLE (1)
    ) u_mcp4725 (
        .clk            (clk),
        .rst_n_sync     (rst_n_sync),
        .dac_code       (dac_code),
        .dac_code_valid (dac_code_valid),
        .dac_code_ready (),
        .dac_busy       (dac_busy),
        .dac_error      (dac_error),
        .dac_overrun    (dac_overrun),
        .error_code     (),
        .dac_i2c_scl    (dac_i2c_scl),
        .dac_i2c_sda    (dac_i2c_sda)
    );

    //-------------------------------------------------------------------------
    // 状态脚(P9 §8~§10)
    //-------------------------------------------------------------------------
    reg [22:0] heartbeat_cnt;   // 2^23 > 6e6

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            heartbeat_cnt <= 23'd0;
            dbg_alive     <= 1'b0;
        end else if (heartbeat_cnt == HEARTBEAT_HALF_CYC - 1) begin
            heartbeat_cnt <= 23'd0;
            dbg_alive     <= ~dbg_alive;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 23'd1;
        end
    end

    reg dbg_adc_toggle;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            dbg_adc_toggle <= 1'b0;
        end else if (adc_sample_valid) begin
            dbg_adc_toggle <= ~dbg_adc_toggle;
        end
    end
    assign dbg_adc = dbg_adc_toggle;

    reg dbg_error_sticky;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            dbg_error_sticky <= 1'b0;
        end else if (adc_error || dac_error || dac_overrun) begin
            dbg_error_sticky <= 1'b1;
        end
    end
    assign dbg_error = dbg_error_sticky;

endmodule
