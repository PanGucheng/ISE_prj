//=============================================================================
// tone_generator.v
// 单音方波发生器：用同步计数器 + terminal count 产生 50% 占空比矩形波。
//
//   note_code = 0      静音：audio_out 保持 0，半周期计数器清零
//   note_code = 1..7   C4..B4，输出对应频率的方波
//
// 频率实现：半周期计数 N = round(SYS_CLK_HZ * 10 / (2 * f_dHz))
//   f_dHz 为标称频率的 0.1 Hz 整数（261.62 Hz -> 2616），用整数表示以
//   避免 XST 对 real 常量的支持限制。详见 frequency_table.md。
//
// 设计约束：
//   - 只有一个时钟域 clk；没有门控时钟，也没有用分频器输出当时钟，
//     半周期到达 terminal count 时才翻转输出（clock-enable 语义）；
//   - 音符变化时相位重启（计数清零、输出清零），使演奏与仿真行为可预测；
//   - 全工程唯一的频率真值来源是 finger_piano_cfg.vh 的 `SYS_CLK_HZ，
//     本模块只通过参数接收，不硬编码任何具体频率。
//
// 数值边界：半周期计数值必须小于 2**FP_TONE_CNT_WIDTH，且 SYS_CLK_HZ*10
//   不得溢出 32 位有符号整数（约 214 MHz）。详见 frequency_table.md 第 5 节。
//=============================================================================

`include "finger_piano_cfg.vh"

module tone_generator #(
    parameter integer SYS_CLK_HZ = `SYS_CLK_HZ
) (
    input  wire       clk,
    input  wire       rst_n_sync,   // 内部同步复位（低有效，来自 reset_sync）
    input  wire [2:0] note_code,    // 音符编码，0 = 静音
    output reg        audio_out     // 方波输出
);

    //-------------------------------------------------------------------------
    // 七个音符的半周期计数值（就近取整）：(SYS_CLK_HZ*10 + f_dHz) / (2*f_dHz)
    //-------------------------------------------------------------------------
    localparam integer HP_C4 = (SYS_CLK_HZ * 10 + 2616) / (2 * 2616);  // 261.62 Hz
    localparam integer HP_D4 = (SYS_CLK_HZ * 10 + 2937) / (2 * 2937);  // 293.67 Hz
    localparam integer HP_E4 = (SYS_CLK_HZ * 10 + 3296) / (2 * 3296);  // 329.63 Hz
    localparam integer HP_F4 = (SYS_CLK_HZ * 10 + 3492) / (2 * 3492);  // 349.23 Hz
    localparam integer HP_G4 = (SYS_CLK_HZ * 10 + 3920) / (2 * 3920);  // 391.99 Hz
    localparam integer HP_A4 = (SYS_CLK_HZ * 10 + 4400) / (2 * 4400);  // 440.00 Hz
    localparam integer HP_B4 = (SYS_CLK_HZ * 10 + 4939) / (2 * 4939);  // 493.88 Hz

    reg [`FP_TONE_CNT_WIDTH-1:0] half_cnt;     // 半周期计数
    reg [2:0]                   note_q;       // 上一拍的音符，用于检测变化
    reg [`FP_TONE_CNT_WIDTH-1:0] half_target;  // 当前音符的半周期目标值

    // 当前音符的半周期目标值（组合）。0 表示静音。
    // 至少钳位到 1：当 SYS_CLK_HZ 异常低时避免出现 0 或非法状态。
    always @(*) begin
        case (note_code)
            3'd1:    half_target = HP_C4;
            3'd2:    half_target = HP_D4;
            3'd3:    half_target = HP_E4;
            3'd4:    half_target = HP_F4;
            3'd5:    half_target = HP_G4;
            3'd6:    half_target = HP_A4;
            3'd7:    half_target = HP_B4;
            default: half_target = {`FP_TONE_CNT_WIDTH{1'b0}};
        endcase

        if (half_target == {`FP_TONE_CNT_WIDTH{1'b0}}) begin
            half_target = {{(`FP_TONE_CNT_WIDTH-1){1'b0}}, 1'b1};
        end
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            half_cnt  <= {`FP_TONE_CNT_WIDTH{1'b0}};
            note_q    <= 3'd0;
            audio_out <= 1'b0;
        end else begin
            note_q <= note_code;

            if (note_code == 3'd0) begin
                // 无按键：静音
                half_cnt  <= {`FP_TONE_CNT_WIDTH{1'b0}};
                audio_out <= 1'b0;
            end else if (note_code != note_q) begin
                // 音符变化：相位重启，从新音符的完整半周期重新开始
                half_cnt  <= {`FP_TONE_CNT_WIDTH{1'b0}};
                audio_out <= 1'b0;
            end else if (half_cnt >= (half_target - 1'b1)) begin
                // terminal count：翻转输出，开始下一个半周期
                half_cnt  <= {`FP_TONE_CNT_WIDTH{1'b0}};
                audio_out <= ~audio_out;
            end else begin
                half_cnt <= half_cnt + 1'b1;
            end
        end
    end

endmodule
