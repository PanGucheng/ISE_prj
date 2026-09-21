//=============================================================================
// sensor_code_frontend.v
// 3-bit 传感器输入完整前端(P2 计划 Commit C)——将来可直接接顶层。
//
// 数据流(P2 计划 §5/§13):
//
//   sensor_async[2:0](3 个 LM393 比较器输出,异步)
//     -> 极性归一化(全链路唯一一次,ACTIVE_HIGH 参数)
//     -> key_sync #(.WIDTH(3)) 两级同步(解决亚稳态)
//     -> sensor_code_filter 整体码字原子滤波(解决多 bit 变化一致性)
//     -> sensor_code_decoder 编码表解码
//   => sensor_code_stable[2:0] + note_code[2:0]
//
// 2FF 同步与 vector 滤波是两个不同问题(§16):同步解决 metastability,
// 滤波解决三个比较器不同时翻转产生的短暂中间码;两者都必须存在,且顺序
// 固定为**先同步、后滤波**(不允许先滤波异步输入)。
//
// 复用现有 key_sync.v(WIDTH=3),不复制同步器(§13)。
// 极性默认 ACTIVE_HIGH=1(模拟约定:未按=0,按下=1),参数化可改;
// 归一化只发生在这里一次,后续模块只处理"按下=1"。
//
// 全工程仍只有 clk 一个时钟域;传感器输入不得当作时钟。
// 本模块现阶段不接入 finger_piano_top(输入引脚未经用户确认)。
//=============================================================================

`include "finger_piano_cfg.vh"

module sensor_code_frontend #(
    parameter integer SYS_CLK_HZ    = `SYS_CLK_HZ,
    parameter integer STABLE_MS     = `KEY_STABLE_MS,
    parameter integer FILTER_ENABLE = `KEY_FILTER_ENABLE,
    parameter integer ACTIVE_HIGH   = `KEY_ACTIVE_HIGH
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [2:0] sensor_async,        // 异步 LM393 输出
    output wire [2:0] sensor_code_stable,  // 稳定后的 3-bit 编码
    output wire [2:0] note_code            // 0 = 静音,1~7 = 唱名
);

    // 极性归一化:全链路唯一一次反相点(与 finger_piano_top 的 key 归一化
    // 语义一致;归一化后统一"按下 = 1")
    wire [2:0] sensor_normalized =
        ACTIVE_HIGH ? sensor_async : ~sensor_async;

    wire [2:0] code_sync;

    // 复用现有两级同步器(ASYNC_REG 属性继承自 key_sync)
    key_sync #(
        .WIDTH (3)
    ) u_sync (
        .clk         (clk),
        .rst_n_sync  (rst_n_sync),
        .async_in    (sensor_normalized),
        .sync_out    (code_sync)
    );

    // 整体码字原子滤波(本计划核心)
    sensor_code_filter #(
        .SYS_CLK_HZ (SYS_CLK_HZ),
        .STABLE_MS  (STABLE_MS),
        .ENABLE     (FILTER_ENABLE)
    ) u_filter (
        .clk         (clk),
        .rst_n_sync  (rst_n_sync),
        .code_sync   (code_sync),
        .code_stable (sensor_code_stable)
    );

    // 编码表语义边界
    sensor_code_decoder u_decoder (
        .sensor_code (sensor_code_stable),
        .note_code   (note_code)
    );

endmodule
