//=============================================================================
// dds_sine_generator.v
// DDS 正弦样点发生器(P3 计划 Commit C/D)—— standalone,不接顶层。
//
// 数据链:
//   note_code[2:0] -> phase increment(组合 case)
//   -> 24-bit 相位累加器(仅 sample_tick 时前进,24 bit 自然溢出取模,
//      禁止 % 运算)
//   -> phase_acc[23:16] -> sine_lut_12bit -> dac_code_r(寄存后输出)
//
// 采样节拍(P3 计划 §9/§10/§23):
//   SAMPLE_DIV = SYS_CLK_HZ / SAMPLE_RATE_HZ(12 MHz / 8 kHz = 1500 精确
//   整除);sample_cnt 每拍 +1,计满产生 1 clk 宽的 sample_tick/dac_code_valid。
//   **不生成 clk_8k 等第二时钟**;所有时序逻辑都在 posedge clk 域。
//   音符切换只复位相位,不重启分频器、不改变 valid 节拍;静音(note=0)
//   仍按 8 kS/s 输出 12'h800(后续 MCP4725 流水线保持固定节拍,§24)。
//
// 音符切换行为(§22):note_code 变化的当拍,phase_acc 清零、phase_inc 换
// 新值、dac_code_r 直接给中点 12'h800;此后第一个采样节拍输出 sine(0°)
// = 2048,再按新 increment 前进 —— 每个新音符都从中点/零交叉起步,行为
// 可预测(与 tone_generator 的相位重启语义一致)。
//
// 无 ready 输入(§26/§27):DDS 是固定时间轴的样点源,样点间隔不得因下游
// busy 而伸缩(否则等效时间轴拉伸 = 频率/相位调制);能否接受样点由
// MCP4725 controller 的 pending/overrun 负责(P4 计划验证 0 drop)。
//
// ENABLE = 0(§25):整块逻辑不生成,dac_code 恒 12'h800、valid 恒 0,
// 无任何周期性内部事务。该宏只是 standalone/future-integration 配置,
// **不是**"改成 1 就启用硬件"(顶层本阶段无实例化)。
//=============================================================================

`include "finger_piano_cfg.vh"

module dds_sine_generator #(
    parameter integer SYS_CLK_HZ     = `SYS_CLK_HZ,
    parameter integer SAMPLE_RATE_HZ = `CFG_DAC_SAMPLE_RATE,
    parameter integer ENABLE         = `CFG_ENABLE_DDS
) (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire [2:0]  note_code,       // 0 = 静音,1~7 = C4~B4
    output wire [11:0] dac_code,        // 12 bit unsigned 正弦样点
    output wire        dac_code_valid   // 8 kS/s 样点有效,1 clk 宽
);

    //-------------------------------------------------------------------------
    // 采样分频(本阶段要求 SYS_CLK_HZ % SAMPLE_RATE_HZ == 0 的精确整除)
    //-------------------------------------------------------------------------
    localparam integer SAMPLE_DIV =
        (SYS_CLK_HZ / SAMPLE_RATE_HZ < 2) ? 2 : (SYS_CLK_HZ / SAMPLE_RATE_HZ);

    //-------------------------------------------------------------------------
    // ENABLE = 0:静音直连分支,无任何计数器/时钟逻辑
    //-------------------------------------------------------------------------
    generate
        if (ENABLE == 0) begin : GEN_OFF

            assign dac_code       = 12'h800;
            assign dac_code_valid = 1'b0;

        end else begin : GEN_DDS

    //-------------------------------------------------------------------------
    // note -> phase increment(冻结表,见 dds_frequency_table.md;
    // 8 kS/s + 24 bit 专用,改采样率必须重新生成)
    //-------------------------------------------------------------------------
    reg [23:0] inc_for_note;
    always @(*) begin
        case (note_code)
            3'd1:    inc_for_note = 24'h085F31;   // C4 261.62 Hz
            3'd2:    inc_for_note = 24'h0965BF;   // D4 293.67 Hz
            3'd3:    inc_for_note = 24'h0A8C54;   // E4 329.63 Hz
            3'd4:    inc_for_note = 24'h0B2CE4;   // F4 349.23 Hz
            3'd5:    inc_for_note = 24'h0C8B2F;   // G4 391.99 Hz
            3'd6:    inc_for_note = 24'h0E147B;   // A4 440.00 Hz
            3'd7:    inc_for_note = 24'h0FCDDD;   // B4 493.88 Hz
            default: inc_for_note = 24'h000000;   // 静音:相位不动
        endcase
    end

    //-------------------------------------------------------------------------
    // 内部状态(§19)
    //-------------------------------------------------------------------------
    reg  [15:0] sample_cnt;
    reg  [23:0] phase_acc;
    reg  [23:0] phase_inc;
    reg  [2:0]  note_q;
    reg  [11:0] dac_code_r;
    reg         r_valid;
    wire        sample_tick = (sample_cnt == SAMPLE_DIV - 1);

    wire [11:0] lut_code;
    sine_lut_12bit u_lut (
        .phase_addr (phase_acc[23:16]),
        .sine_code  (lut_code)
    );

    //-------------------------------------------------------------------------
    // 主时序(唯一时钟 clk)
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            sample_cnt     <= 16'd0;
            phase_acc      <= 24'd0;
            phase_inc      <= 24'd0;
            note_q         <= 3'd0;
            dac_code_r     <= 12'h800;   // 静音中点
            r_valid        <= 1'b0;
        end else begin
            // 采样节拍:独立于音符切换,严格恒定(§23)
            r_valid        <= sample_tick;
            if (sample_tick) begin
                sample_cnt <= 16'd0;
            end else begin
                sample_cnt <= sample_cnt + 16'd1;
            end

            if (note_code != note_q) begin
                // 音符切换:相位归零、换 increment、当拍给中点;
                // 不动 sample_cnt(节拍不变)
                note_q     <= note_code;
                phase_inc  <= inc_for_note;
                phase_acc  <= 24'd0;
                dac_code_r <= 12'h800;
            end else if (sample_tick) begin
                // 正常采样:先取当前相位样点,相位再前进
                dac_code_r <= lut_code;
                phase_acc  <= phase_acc + phase_inc;   // 24-bit 自然溢出
            end
        end
    end

    assign dac_code       = dac_code_r;
    assign dac_code_valid = r_valid;

        end
    endgenerate

endmodule
