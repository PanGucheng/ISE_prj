//=============================================================================
// tone_dac_demo_top.v
// tone_dac_demo 独立验证工程物理顶层。
//
// 3-bit 异步输入 sensor_async[2:0] 经 2FF 同步 + 码字原子滤波 + 解码
// 产生唯一 note_code[2:0]，并行送入：
//   1. tone_generator -> square_out (P110 推挽方波，临时占用 note_debug[0])
//   2. dds_mcp4725_pipeline -> dac_i2c_scl / dac_i2c_sda (P102/P103，MCP4725 模拟正弦波)
//
// 引脚分配严格复用最终 Stage-2 冻结约束。
// ADS1115 引脚 P31/P32 保持空闲未分配。
// 全工程单时钟域 clk (P57, 12 MHz)。
//=============================================================================

`timescale 1ns / 1ps
`include "finger_piano_cfg.vh"

module tone_dac_demo_top (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] sensor_async,

    output wire       square_out,

    inout  wire       dac_i2c_scl,
    inout  wire       dac_i2c_sda
);

    //-------------------------------------------------------------------------
    // 1. 复位同步器（全工程唯一实例）
    //-------------------------------------------------------------------------
    wire rst_n_sync;

    reset_sync u_reset_sync (
        .clk        (clk),
        .rst_n      (rst_n),
        .rst_n_sync (rst_n_sync)
    );

    wire [2:0] note_code;

    sensor_code_frontend #(
        .SYS_CLK_HZ    (`SYS_CLK_HZ),
        .STABLE_MS     (`KEY_STABLE_MS),
        .FILTER_ENABLE (`KEY_FILTER_ENABLE),
        .ACTIVE_HIGH   (`KEY_ACTIVE_HIGH)
    ) u_frontend (
        .clk                (clk),
        .rst_n_sync         (rst_n_sync),
        .sensor_async       (sensor_async),
        .sensor_code_stable (),
        .note_code          (note_code)
    );

    //-------------------------------------------------------------------------
    // 3. 方波音频发生器（复用已验证 tone_generator）
    //-------------------------------------------------------------------------
    tone_generator #(
        .SYS_CLK_HZ (`SYS_CLK_HZ)
    ) u_tone_gen (
        .clk        (clk),
        .rst_n_sync (rst_n_sync),
        .note_code  (note_code),
        .audio_out  (square_out)
    );

    //-------------------------------------------------------------------------
    // 4. DDS -> MCP4725 正弦波链路（复用已验证 pipeline）
    //-------------------------------------------------------------------------
    dds_mcp4725_pipeline #(
        .SYS_CLK_HZ     (`SYS_CLK_HZ),
        .SAMPLE_RATE_HZ (`CFG_DAC_SAMPLE_RATE),
        .DAC_I2C_HZ     (`CFG_DAC_I2C_SPEED),
        .MCP4725_ADDR   (`CFG_MCP4725_ADDR),
        .ENABLE         (1)
    ) u_dac_pipeline (
        .clk             (clk),
        .rst_n_sync      (rst_n_sync),
        .note_code       (note_code),
        .dac_i2c_scl     (dac_i2c_scl),
        .dac_i2c_sda     (dac_i2c_sda),
        .dac_busy        (),
        .dac_error       (),
        .dac_overrun     (),
        .dds_code_debug  (),
        .dds_valid_debug (),
        .dac_ready_debug ()
    );

endmodule
