//=============================================================================
// finger_piano_stage2_top.v
// Stage-2 物理顶层(P6B 计划 §7~§13)—— wrapper only。
//
// 只做两件事:
//   1) 外部异步 rst_n -> 现有 reset_sync -> rst_n_sync,再送入
//      finger_piano_system(复位同步器**只在这里实例化一次**);
//   2) 把 note_code 直连到 note_debug,便于首次上板快速确认
//      LM393 -> 同步/滤波 -> 解码 -> note_code 是否正确。
//
//   rst_n ---> reset_sync ---> rst_n_sync ---+
//                                            v
//   sensor_async[2:0] -------------> finger_piano_system
//   adc_i2c_scl/sda  <------------>  (P1 三通道 ADS1115)
//   dac_i2c_scl/sda  <------------>  (P3/P4 DDS -> MCP4725)
//                                            |
//                                        note_code
//                                            v
//                                       note_debug[2:0]
//
// 冻结边界(P6B §9/§12/§13):
//   - 本层不重新实现任何子系统(无同步器、无滤波器、无解码器、无 DDS、
//     无 ADS/MCP controller、无压力处理),全部逻辑都在 finger_piano_system
//     内部已存在的模块里;
//   - 不再提供 legacy 的 audio_out / key_in[6:0] / key_debug[6:0]
//     (真实音频路径是 note_code -> DDS -> MCP4725 -> 模拟侧);
//   - 不加入 legacy/stage2 兼容 mux;
//   - 两条 I2C 总线仍完全独立,没有 arbiter / 共享调度;
//   - 全工程仍只有 clk 一个时钟域(12 MHz / P57);I2C SCL 不是 FPGA 时钟。
//
// 引脚冻结(P6B §1,用户 2026-09-16 确认,VCCO 全部 3.3 V,LVCMOS33):
//   clk=P57  rst_n=P3  sensor_async[0..2]=P28/P29/P30
//   adc_i2c_scl/sda=P31/P32  dac_i2c_scl/sda=P102/P103
//   note_debug[0..2]=P110/P111/P113
//=============================================================================

`include "finger_piano_cfg.vh"

module finger_piano_stage2_top (
    input  wire       clk,           // 唯一系统时钟(12 MHz 有源晶振)
    input  wire       rst_n,         // 外部异步低有效复位

    input  wire [2:0] sensor_async,  // LM393 3-bit 编码(000=静音,001~111=C4~B4)

    inout  wire       adc_i2c_scl,   // ADS1115 独立 I2C 总线
    inout  wire       adc_i2c_sda,

    inout  wire       dac_i2c_scl,   // MCP4725 独立 I2C 总线
    inout  wire       dac_i2c_sda,

    output wire [2:0] note_debug     // 当前音符编码,0=无音符
);

    //-------------------------------------------------------------------------
    // 复位同步:异步拉低、同步释放(全工程唯一实例)
    //-------------------------------------------------------------------------
    wire rst_n_sync;

    reset_sync u_reset_sync (
        .clk        (clk),
        .rst_n      (rst_n),
        .rst_n_sync (rst_n_sync)
    );

    //-------------------------------------------------------------------------
    // 系统数字核心(P1~P6A:输入前端 / ADC 压力链 / DDS→DAC 音频链)
    // 压力数据与错误汇总本阶段不引到顶层(P6B §7:第一版不增加其他端口)。
    //-------------------------------------------------------------------------
    wire [2:0] note_code;

    finger_piano_system #(
        .SYS_CLK_HZ           (`SYS_CLK_HZ),
        .SENSOR_ACTIVE_HIGH   (1),
        .SENSOR_FILTER_ENABLE (1),
        .ENABLE_ADC           (1),
        .ENABLE_DAC           (1)
    ) u_sys (
        .clk               (clk),
        .rst_n_sync        (rst_n_sync),
        .sensor_async      (sensor_async),
        .adc_i2c_scl       (adc_i2c_scl),
        .adc_i2c_sda       (adc_i2c_sda),
        .dac_i2c_scl       (dac_i2c_scl),
        .dac_i2c_sda       (dac_i2c_sda),
        .sensor_code_stable(),
        .note_code         (note_code),
        .pressure_ch0      (),
        .pressure_ch1      (),
        .pressure_ch2      (),
        .pressure_valid    (),
        .adc_error         (),
        .dac_error         (),
        .dac_overrun       ()
    );

    //-------------------------------------------------------------------------
    // 调试直通(P6B §11):不增加额外寄存器或编码
    //-------------------------------------------------------------------------
    assign note_debug = note_code;

endmodule
