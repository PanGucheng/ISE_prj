//=============================================================================
// finger_piano_system.v
// stage-2 逻辑系统边界(P6 计划 Commit B)——**不是** FPGA package top。
//
// 只做 wiring + status aggregation(P6 §29):把 P1~P5 已验证的独立模块
// 连接成完整数字系统,**不复制、不重写任何已有逻辑**:
//
//   sensor_async[2:0] -> sensor_code_frontend(P2)  -> sensor_code_stable/note_code
//   note_code         -> dds_mcp4725_pipeline(P4)  -> dac_i2c_scl/sda + dac 状态
//   adc_i2c_scl/sda   -> ads1115_ctrl(P1)          -> raw CH0/1/2 + valid
//                     -> pressure_processor(P5)    -> pressure_ch0/1/2 + valid
//
// 冻结边界(P6 §1/§12/§13/§14):
//   - 压力链与音符链**解耦**:pressure_* 不进入 note/DDS 通路,压力如何
//     映射音量/音高属于后续 P7,本模块不存在任何这类逻辑;
//   - ADC 与 DAC 仍是两条独立 I²C 物理总线,不加 arbiter / 共享调度;
//   - 无 key_in[6:0]、无 legacy audio_out、无 7-key 兼容 mux;
//   - 无系统总控 FSM:ADC/DAC/sensor frontend 各自的状态机独立运行,
//     顶层不调度它们;
//   - error 只汇总 adc_error / dac_error / dac_overrun 三个 1-bit 信号,
//     不做 global error code(ADC/DAC 错误域语义不同,§30)。
//
// Reset(P6 §7):输入直接使用外层 reset_sync 产生的 rst_n_sync,
// 本模块**不得**再次实例化 reset_sync(复位只在外层产生一次)。
//
// ENABLE_ADC / ENABLE_DAC(§28):分别控制两条 I²C 链是否生成;两者独立,
// 任意组合合法。默认 1/1 = 集成启用语义(区别于 P1 cfg 宏的全关默认)。
// sensor 前端不受这两个参数影响。
//
// 综合归属(P6 收尾):P6B(2026-09-16)已完成 final top 迁移——正式顶层是
// finger_piano_stage2_top,本模块经其被实例化并参与综合;12 脚冻结分配见
// constraints/finger_piano.ucf。当前顶层没有压力数据的硬件消费方,因此
// ADS1115 压力链及相关 debug 出口会被 XST 合法 trim(已审阅白名单,
// 见 project.json 的 verification.synthesisWarningAllowlist 与工程 README)。
//=============================================================================

`include "finger_piano_cfg.vh"

module finger_piano_system #(
    parameter integer SYS_CLK_HZ           = `SYS_CLK_HZ,
    parameter integer SENSOR_ACTIVE_HIGH   = 1,
    parameter integer SENSOR_FILTER_ENABLE = 1,
    parameter integer ENABLE_ADC           = 1,
    parameter integer ENABLE_DAC           = 1
) (
    input  wire        clk,
    input  wire        rst_n_sync,

    input  wire [2:0]  sensor_async,

    inout  wire        adc_i2c_scl,
    inout  wire        adc_i2c_sda,

    inout  wire        dac_i2c_scl,
    inout  wire        dac_i2c_sda,

    output wire [2:0]  sensor_code_stable,
    output wire [2:0]  note_code,

    output wire [14:0] pressure_ch0,
    output wire [14:0] pressure_ch1,
    output wire [14:0] pressure_ch2,
    output wire        pressure_valid,

    output wire        adc_error,
    output wire        dac_error,
    output wire        dac_overrun
);

    //-------------------------------------------------------------------------
    // 音符输入链(P2 frontend:极性归一化 -> 2FF 同步 -> 原子滤波 -> 解码)
    //-------------------------------------------------------------------------
    sensor_code_frontend #(
        .SYS_CLK_HZ    (SYS_CLK_HZ),
        .FILTER_ENABLE (SENSOR_FILTER_ENABLE),
        .ACTIVE_HIGH   (SENSOR_ACTIVE_HIGH)
    ) u_sensor_frontend (
        .clk               (clk),
        .rst_n_sync        (rst_n_sync),
        .sensor_async      (sensor_async),
        .sensor_code_stable(sensor_code_stable),
        .note_code         (note_code)
    );

    //-------------------------------------------------------------------------
    // ADC / 压力链(P1 controller -> P5 processor;两模块间纯 wire 直连)
    //-------------------------------------------------------------------------
    wire [15:0] adc_ch0_raw;
    wire [15:0] adc_ch1_raw;
    wire [15:0] adc_ch2_raw;
    wire        adc_sample_valid;

    generate
        if (ENABLE_ADC == 0) begin : GEN_ADC_OFF

            // ENABLE=0 的 controller 停在复位态:总线无驱动(上拉为高),
            // 全部输出恒 0(由其 GEN_OFF 分支保证)。
            ads1115_ctrl #(
                .ENABLE (0)
            ) u_ads1115 (
                .clk              (clk),
                .rst_n_sync       (rst_n_sync),
                .adc_i2c_scl      (adc_i2c_scl),
                .adc_i2c_sda      (adc_i2c_sda),
                .adc_ch0_raw      (adc_ch0_raw),
                .adc_ch1_raw      (adc_ch1_raw),
                .adc_ch2_raw      (adc_ch2_raw),
                .adc_sample_valid (adc_sample_valid),
                .adc_busy         (),
                .adc_error        (adc_error),
                .error_code       ()
            );

        end else begin : GEN_ADC_ON

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
                .adc_busy         (),
                .adc_error        (adc_error),
                .error_code       ()
            );

        end
    endgenerate

    pressure_processor u_pressure (
        .clk              (clk),
        .rst_n_sync       (rst_n_sync),
        .adc_ch0_raw      (adc_ch0_raw),
        .adc_ch1_raw      (adc_ch1_raw),
        .adc_ch2_raw      (adc_ch2_raw),
        .adc_sample_valid (adc_sample_valid),
        .pressure_ch0     (pressure_ch0),
        .pressure_ch1     (pressure_ch1),
        .pressure_ch2     (pressure_ch2),
        .pressure_valid   (pressure_valid)
    );

    //-------------------------------------------------------------------------
    // DDS / DAC 链(P4 pipeline:DDS 8 kS/s -> MCP4725 controller)
    //-------------------------------------------------------------------------
    generate
        if (ENABLE_DAC == 0) begin : GEN_DAC_OFF

            dds_mcp4725_pipeline #(
                .ENABLE (0)
            ) u_dac_pipeline (
                .clk             (clk),
                .rst_n_sync      (rst_n_sync),
                .note_code       (note_code),
                .dac_i2c_scl     (dac_i2c_scl),
                .dac_i2c_sda     (dac_i2c_sda),
                .dac_busy        (),
                .dac_error       (dac_error),
                .dac_overrun     (dac_overrun),
                .dds_code_debug  (),
                .dds_valid_debug (),
                .dac_ready_debug ()
            );

        end else begin : GEN_DAC_ON

            dds_mcp4725_pipeline #(
                .ENABLE (1)
            ) u_dac_pipeline (
                .clk             (clk),
                .rst_n_sync      (rst_n_sync),
                .note_code       (note_code),
                .dac_i2c_scl     (dac_i2c_scl),
                .dac_i2c_sda     (dac_i2c_sda),
                .dac_busy        (),
                .dac_error       (dac_error),
                .dac_overrun     (dac_overrun),
                .dds_code_debug  (),
                .dds_valid_debug (),
                .dac_ready_debug ()
            );

        end
    endgenerate

endmodule
