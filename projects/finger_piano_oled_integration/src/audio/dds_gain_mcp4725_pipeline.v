//=============================================================================
// dds_gain_mcp4725_pipeline.v
// DDS -> 数字音量 -> MCP4725 standalone 流水线(P8 计划 Commit C,§12)。
//
//   note_code[2:0]  ->  dds_sine_generator  -- dac_code[11:0] --> audio_gain_12bit
//   volume_level[2:0]                              (纯组合增益)    |
//                                                            mcp4725_ctrl
//                                                            dac_i2c_scl/sda
//
// 冻结边界(P8 §11/§13~§17):
//   - 不复制、不修改 DDS 核心:8 kS/s cadence、24-bit 相位、七音 increment
//     全部来自 dds_sine_generator,音量变化**不得**触碰相位累加器或采样
//     分频器(§14);
//   - 不修改 MCP4725 协议:Fast Write only、pending+overrun、开漏 0/Z
//     (§16);EEPROM 写在结构上不可能;
//   - volume_level 是本流水线的显式输入(P8 §17),**禁止**把 pressure
//     数据接到这里——pressure→volume 映射属后续计划;
//   - gain 纯组合且位于 DDS 输出与 controller 采样沿之间,不改变样点
//     时间轴:每个 dac_code_valid 拍的样点经组合增益后当拍送达
//     mcp4725_ctrl,无 FIFO、无第二采样计数器、无 ready 反馈进入 DDS;
//   - 不替换已验证的 dds_mcp4725_pipeline.v(P4 baseline 保留,§12);
//     本模块尚未接入 finger_piano_stage2_top(P8 §18,STANDALONE)。
//
// ENABLE = 0:DDS 不产生 valid、controller 不启动、总线释放、
// dac_busy/dac_error/dac_overrun 恒 0(与 P4 wrapper 同语义)。
//=============================================================================

`include "finger_piano_cfg.vh"

module dds_gain_mcp4725_pipeline #(
    parameter integer SYS_CLK_HZ     = `SYS_CLK_HZ,
    parameter integer SAMPLE_RATE_HZ = `CFG_DAC_SAMPLE_RATE,
    parameter integer DAC_I2C_HZ     = `CFG_DAC_I2C_SPEED,
    parameter [6:0]   MCP4725_ADDR   = `CFG_MCP4725_ADDR,
    parameter integer ENABLE         = 0
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [2:0] note_code,
    input  wire [2:0] volume_level,

    inout  wire       dac_i2c_scl,
    inout  wire       dac_i2c_sda,

    output wire       dac_busy,
    output wire       dac_error,
    output wire       dac_overrun,

    // 调试观察口(gain 后的最终 DAC 码流,仿真/调试用)
    output wire [11:0] gain_code_debug,
    output wire        dds_valid_debug,
    output wire        dac_ready_debug
);

    generate
        if (ENABLE == 0) begin : GEN_OFF

            assign dac_busy        = 1'b0;
            assign dac_error       = 1'b0;
            assign dac_overrun     = 1'b0;
            assign gain_code_debug = 12'h800;
            assign dds_valid_debug = 1'b0;
            assign dac_ready_debug = 1'b0;

        end else begin : GEN_PIPE

            wire [11:0] dds_code;
            wire        dds_valid;
            wire [11:0] gain_code;

            //-----------------------------------------------------------------
            // 固定 8 kS/s 样点源(时间轴独立,音量不影响 cadence/相位)
            //-----------------------------------------------------------------
            dds_sine_generator #(
                .SYS_CLK_HZ     (SYS_CLK_HZ),
                .SAMPLE_RATE_HZ (SAMPLE_RATE_HZ),
                .ENABLE         (1)
            ) u_dds (
                .clk            (clk),
                .rst_n_sync     (rst_n_sync),
                .note_code      (note_code),
                .dac_code       (dds_code),
                .dac_code_valid (dds_valid)
            );

            //-----------------------------------------------------------------
            // 数字音量:纯组合,围绕 2048 缩放(P8 §2~§8)
            //-----------------------------------------------------------------
            audio_gain_12bit u_gain (
                .sample_in    (dds_code),
                .volume_level (volume_level),
                .sample_out   (gain_code)
            );

            //-----------------------------------------------------------------
            // MCP4725 controller(独立总线,pending+overrun 在其内部)
            //-----------------------------------------------------------------
            mcp4725_ctrl #(
                .ENABLE     (1),
                .I2C_ADDR   (MCP4725_ADDR),
                .SYS_CLK_HZ (SYS_CLK_HZ),
                .I2C_HZ     (DAC_I2C_HZ)
            ) u_dac (
                .clk            (clk),
                .rst_n_sync     (rst_n_sync),
                .dac_code       (gain_code),
                .dac_code_valid (dds_valid),
                .dac_code_ready (dac_ready_debug),
                .dac_busy       (dac_busy),
                .dac_error      (dac_error),
                .dac_overrun    (dac_overrun),
                .error_code     (),
                .dac_i2c_scl    (dac_i2c_scl),
                .dac_i2c_sda    (dac_i2c_sda)
            );

            assign gain_code_debug = gain_code;
            assign dds_valid_debug = dds_valid;

        end
    endgenerate

endmodule
