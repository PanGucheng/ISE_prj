//=============================================================================
// dds_mcp4725_pipeline.v
// DDS -> MCP4725 数字音频链路集成层(P4 计划 Commit A)。
//
// **只做结构化连接**,内部直接实例化两个已有模块:
//
//   note_code[2:0]
//     ->  dds_sine_generator  -- dac_code[11:0] ---->  mcp4725_ctrl
//                             -- dac_code_valid ->      |
//                                                 dac_i2c_scl/sda
//                                                   (MCP4725 行为模型在 TB 侧)
//
// 冻结的架构红线(P4 计划 §7/§8/§11):
//   - 不生成第二套 DDS / 第二个 sample counter;
//   - 不对 dac_code 重采样、不加 FIFO、不加音量乘法器;
//   - DDS 固定 8 kS/s 时间轴,**没有 ready 反馈进入 DDS**——样点间隔不得
//     因 I2C busy 而伸缩(否则 = 时间轴拉伸 = 频率/相位调制);
//     MCP4725 controller 用自己的 pending/overrun 报告能否跟上(§9),
//     正常配置下 valid && !ready 永远不出现(由 TB 强制验证);
//   - I2C 时序参数仍由 mcp4725_ctrl -> i2c_master 负责,pipeline 只下传
//     SYS_CLK_HZ / DAC_I2C_HZ / MCP4725_ADDR(§34),不重复时序算法。
//
// ENABLE = 0(§32):DDS 不产生 valid、controller 不启动、SDA/SCL 释放、
// dac_busy/dac_error/dac_overrun 恒 0。该参数同样是 integration-ready
// 配置,pipeline 尚未进入顶层,**不是**系统级"启用 DAC"开关。
//
// 本阶段不实例化进 finger_piano_top(§42)。
//=============================================================================

`include "finger_piano_cfg.vh"

module dds_mcp4725_pipeline #(
    parameter integer SYS_CLK_HZ     = `SYS_CLK_HZ,
    parameter integer SAMPLE_RATE_HZ = `CFG_DAC_SAMPLE_RATE,
    parameter integer DAC_I2C_HZ     = `CFG_DAC_I2C_SPEED,
    parameter [6:0]   MCP4725_ADDR   = `CFG_MCP4725_ADDR,
    parameter integer ENABLE         = 0
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [2:0] note_code,

    inout  wire       dac_i2c_scl,
    inout  wire       dac_i2c_sda,

    output wire       dac_busy,
    output wire       dac_error,
    output wire       dac_overrun,

    // 调试观察口(仿真/后续调试用,§45;不做状态机调试口)
    output wire [11:0] dds_code_debug,
    output wire        dds_valid_debug,
    output wire        dac_ready_debug
);

    generate
        if (ENABLE == 0) begin : GEN_OFF

            assign dac_busy        = 1'b0;
            assign dac_error       = 1'b0;
            assign dac_overrun     = 1'b0;
            assign dds_code_debug  = 12'h800;
            assign dds_valid_debug = 1'b0;
            assign dac_ready_debug = 1'b0;

        end else begin : GEN_PIPE

            wire [11:0] dds_code;
            wire        dds_valid;

            //-----------------------------------------------------------------
            // 固定 8 kS/s 样点源(时间轴独立,无 ready 反馈)
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
                .dac_code       (dds_code),
                .dac_code_valid (dds_valid),
                .dac_code_ready (dac_ready_debug),
                .dac_busy       (dac_busy),
                .dac_error      (dac_error),
                .dac_overrun    (dac_overrun),
                .error_code     (),
                .dac_i2c_scl    (dac_i2c_scl),
                .dac_i2c_sda    (dac_i2c_sda)
            );

            assign dds_code_debug  = dds_code;
            assign dds_valid_debug = dds_valid;

        end
    endgenerate

endmodule
