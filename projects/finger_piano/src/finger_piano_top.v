//=============================================================================
// finger_piano_top.v
// 手指钢琴顶层：7 路数字输入的单音电子琴。
//
//   key_in[6:0]  唱名 1..7 的按键输入（压力传感器调理 + 电平判决后的 0/1）
//   audio_out    方波输出，接 LM386
//   key_debug    调试：极性归一化 + 同步 + 滤波之后的按键状态
//   note_debug   调试：当前音符编码，0 = 无音符
//
// 数据流（单时钟域，只有 clk）：
//   rst_n  -> reset_sync -> rst_n_sync
//   key_in -> 极性归一化 -> key_sync -> key_filter -> note_encoder -> tone_generator
//
// 说明：
//   - 本工程固定 7 路输入，端口固定为 [6:0]，不引入“表面可配置、实际不可配置”
//     的按键位宽伪参数；子模块的 WIDTH 由本层显式传 7；
//   - 输入极性（KEY_ACTIVE_HIGH）只在本层归一化一次，后续链路统一使用
//     key_normalized，禁止在子模块中再次反相；
//   - 所有时钟频率相关参数都从 finger_piano_cfg.vh 取默认值，并由本层参数
//     显式向下覆盖，全工程没有第二处硬编码频率。
//=============================================================================

`include "finger_piano_cfg.vh"

module finger_piano_top #(
    parameter integer SYS_CLK_HZ        = `SYS_CLK_HZ,
    parameter integer KEY_STABLE_MS     = `KEY_STABLE_MS,
    parameter integer KEY_FILTER_ENABLE = `KEY_FILTER_ENABLE,
    parameter integer KEY_ACTIVE_HIGH   = `KEY_ACTIVE_HIGH
) (
    input  wire       clk,          // 外部有源晶振，唯一系统时钟
    input  wire       rst_n,        // 外部低有效复位
    input  wire [6:0] key_in,       // 7 路按键输入
    output wire       audio_out,    // 方波音频输出
    output wire [6:0] key_debug,    // 调试：滤波后的按键状态
    output wire [2:0] note_debug    // 调试：当前音符编码
);

    //-------------------------------------------------------------------------
    // 极性归一化：全工程唯一一处反相。
    // KEY_ACTIVE_HIGH 是常量参数，综合时会被折叠，不产生额外硬件。
    //-------------------------------------------------------------------------
    wire [6:0] key_normalized = KEY_ACTIVE_HIGH ? key_in : ~key_in;

    //-------------------------------------------------------------------------
    // 内部连线
    //-------------------------------------------------------------------------
    wire       rst_n_sync;      // 同步释放后的内部复位（低有效）
    wire [6:0] key_sync_w;      // 两级同步后的按键
    wire [6:0] key_stable_w;    // 稳定滤波后的按键
    wire [2:0] note_code_w;     // 音符编码

    //-------------------------------------------------------------------------
    // 复位同步：异步拉低、同步释放
    //-------------------------------------------------------------------------
    reset_sync u_reset_sync (
        .clk        (clk),
        .rst_n      (rst_n),
        .rst_n_sync (rst_n_sync)
    );

    //-------------------------------------------------------------------------
    // 两级触发器同步（外部异步输入 -> clk 域）
    //-------------------------------------------------------------------------
    key_sync #(
        .WIDTH (7)
    ) u_key_sync (
        .clk        (clk),
        .rst_n_sync (rst_n_sync),
        .async_in   (key_normalized),
        .sync_out   (key_sync_w)
    );

    //-------------------------------------------------------------------------
    // 数字稳定滤波（默认 10 ms，可通过 KEY_FILTER_ENABLE 关闭）
    //-------------------------------------------------------------------------
    key_filter #(
        .SYS_CLK_HZ (SYS_CLK_HZ),
        .STABLE_MS  (KEY_STABLE_MS),
        .ENABLE     (KEY_FILTER_ENABLE),
        .WIDTH      (7)
    ) u_key_filter (
        .clk         (clk),
        .rst_n_sync  (rst_n_sync),
        .key_sync_in (key_sync_w),
        .key_stable  (key_stable_w)
    );

    //-------------------------------------------------------------------------
    // 优先级编码：多键同时按下时 1 > 2 > 3 > 4 > 5 > 6 > 7
    //-------------------------------------------------------------------------
    note_encoder u_note_encoder (
        .key_stable (key_stable_w),
        .note_code  (note_code_w)
    );

    //-------------------------------------------------------------------------
    // 方波生成：同步计数器 + terminal count，无门控时钟
    //-------------------------------------------------------------------------
    tone_generator #(
        .SYS_CLK_HZ (SYS_CLK_HZ)
    ) u_tone_generator (
        .clk        (clk),
        .rst_n_sync (rst_n_sync),
        .note_code  (note_code_w),
        .audio_out  (audio_out)
    );

    //-------------------------------------------------------------------------
    // 调试输出
    //-------------------------------------------------------------------------
    assign key_debug  = key_stable_w;
    assign note_debug = note_code_w;

endmodule
