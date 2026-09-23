//=============================================================================
// pressure_processor.v
// 三路压力数据处理包装层(P5 计划 Commit C)。
//
// 结构(§16,实现取 §18 方案 A):
//
//   adc_ch0/1/2_raw + adc_sample_valid
//     -> pressure_frame_capture(原子帧锁存)
//     -> 3 x pressure_channel_corrector(组合:符号钳位 + 零点校正)
//     => pressure_ch0/1/2(15 bit unsigned)+ pressure_valid
//
// pressure_valid 与新数据**同沿对齐**(§17):帧寄存器更新的同一拍,
// 组合校正器的输出已经是新帧的校正结果,valid 直接取 frame_valid,
// 不存在"valid 先高、数据下一拍才更新"的接口。
//
// 职责边界(冻结):
//   - 不读取 sensor_code/note_code:LM393 音符路径与 ADS1115 压力路径
//     解耦(§19/§20);
//   - 不输出 pressure_level 阈值分级(§21)、不做 max/mean/min 融合、
//     不做音量/音高映射 —— 这些属于后续控制策略;
//   - 不做电压换算、牛顿换算、0~4095 归一化(§36/§37/§15);
//   - 不消费 adc_error:driver 出错时没有新 sample_valid,本模块自然
//     保持上一帧(§27),也不加 stale timeout(§28)。
//   - 不设 ENABLE:纯数据处理模块是否实例化由上层决定(§40)。
//
// 三个 ZERO 参数默认取 cfg 宏(全 0,UNMEASURED DEFAULT,§12/§41)。
//=============================================================================

`include "finger_piano_cfg.vh"

module pressure_processor #(
    parameter [14:0]  CH0_ZERO = `CFG_PRESSURE_CH0_ZERO,
    parameter [14:0]  CH1_ZERO = `CFG_PRESSURE_CH1_ZERO,
    parameter [14:0]  CH2_ZERO = `CFG_PRESSURE_CH2_ZERO,
    parameter integer INVERT   = 0
) (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire [15:0] adc_ch0_raw,
    input  wire [15:0] adc_ch1_raw,
    input  wire [15:0] adc_ch2_raw,
    input  wire        adc_sample_valid,
    output wire [14:0] pressure_ch0,
    output wire [14:0] pressure_ch1,
    output wire [14:0] pressure_ch2,
    output wire        pressure_valid
);

    wire [15:0] frame_ch0_raw;
    wire [15:0] frame_ch1_raw;
    wire [15:0] frame_ch2_raw;
    wire        frame_valid;

    pressure_frame_capture u_capture (
        .clk              (clk),
        .rst_n_sync       (rst_n_sync),
        .adc_ch0_raw      (adc_ch0_raw),
        .adc_ch1_raw      (adc_ch1_raw),
        .adc_ch2_raw      (adc_ch2_raw),
        .adc_sample_valid (adc_sample_valid),
        .frame_ch0_raw    (frame_ch0_raw),
        .frame_ch1_raw    (frame_ch1_raw),
        .frame_ch2_raw    (frame_ch2_raw),
        .frame_valid      (frame_valid)
    );

    pressure_channel_corrector #(
        .ZERO_OFFSET (CH0_ZERO),
        .INVERT      (INVERT)
    ) u_corr0 (
        .raw_code       (frame_ch0_raw),
        .corrected_code (pressure_ch0)
    );

    pressure_channel_corrector #(
        .ZERO_OFFSET (CH1_ZERO),
        .INVERT      (INVERT)
    ) u_corr1 (
        .raw_code       (frame_ch1_raw),
        .corrected_code (pressure_ch1)
    );

    pressure_channel_corrector #(
        .ZERO_OFFSET (CH2_ZERO),
        .INVERT      (INVERT)
    ) u_corr2 (
        .raw_code       (frame_ch2_raw),
        .corrected_code (pressure_ch2)
    );

    assign pressure_valid = frame_valid;

endmodule
