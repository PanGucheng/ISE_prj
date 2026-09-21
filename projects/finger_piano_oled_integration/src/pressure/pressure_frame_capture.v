//=============================================================================
// pressure_frame_capture.v
// ADS1115 三通道轮询扫描帧原子锁存(P5 计划 Commit A)。
//
// ADS1115 只有一个 ADC 核心,经内部 MUX 依次转换 AIN0/AIN1/AIN2,因此
// adc_ch0/1/2_raw 不是同一物理瞬间的采样;本模块把"同一轮扫描结束后"
// 的三个 raw 在**同一个 clk 沿**原子锁存成一组相干扫描帧(coherent
// scan frame),后续逻辑永远不会看到 new-CH0/old-CH1/old-CH2 的半更新
// 状态(P5 计划 §7)。
//
// 注意措辞:这是"三通道轮询扫描帧",**不是**三路同步采样(§3)。
//
// 行为(§6/§8):
//   adc_sample_valid = 0 -> frame 保持旧值,frame_valid = 0;
//   adc_sample_valid = 1 -> 同一沿锁存三路 raw,frame_valid 拉高 1 clk;
//   复位后全 0;不产生假的 frame_valid。
//=============================================================================

module pressure_frame_capture (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire [15:0] adc_ch0_raw,
    input  wire [15:0] adc_ch1_raw,
    input  wire [15:0] adc_ch2_raw,
    input  wire        adc_sample_valid,   // ADS1115 一轮扫描完成,1 clk
    output reg  [15:0] frame_ch0_raw,
    output reg  [15:0] frame_ch1_raw,
    output reg  [15:0] frame_ch2_raw,
    output reg         frame_valid          // 1 clk,与新帧同沿对齐
);

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            frame_ch0_raw <= 16'h0000;
            frame_ch1_raw <= 16'h0000;
            frame_ch2_raw <= 16'h0000;
            frame_valid   <= 1'b0;
        end else if (adc_sample_valid) begin
            frame_ch0_raw <= adc_ch0_raw;   // 三路同一沿原子更新
            frame_ch1_raw <= adc_ch1_raw;
            frame_ch2_raw <= adc_ch2_raw;
            frame_valid   <= 1'b1;
        end else begin
            frame_valid <= 1'b0;
        end
    end

endmodule
