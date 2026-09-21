//=============================================================================
// pressure_channel_corrector.v
// 单通道压力数据校正(P5 计划 Commit B)。
//
// 处理顺序(计划 §10 冻结):
//
//   ADS1115 signed raw (16-bit two's complement)
//     -> 负码?(单端对地测量中负码只代表零附近的偏移/噪声)
//          是 -> 0(**不取绝对值**:-100 不能变成 +100 的"压力")
//          否 -> raw[14:0]
//     -> 减 ZERO_OFFSET
//     -> 下溢饱和为 0(禁止 15 位无符号减法绕回)
//
//   P = max(0, max(0, raw) - ZERO_OFFSET)
//
// 输出 15 bit unsigned:单端正输入的正常有效码范围是 0x0000~0x7FFF,
// 幅值 15 bit 即可,后续业务层不必再携带符号位(§11)。
//
// ZERO_OFFSET 默认 0(UNMEASURED DEFAULT,不是 CALIBRATED);真实零点
// 必须等用户上板实测后填写(§12),**禁止**由 Agent 猜测。
// 纯组合逻辑。
//=============================================================================

module pressure_channel_corrector #(
    parameter [14:0] ZERO_OFFSET = 15'd0
) (
    input  wire [15:0] raw_code,        // ADS1115 原始 16-bit two's complement
    output wire [14:0] corrected_code   // 非负校正压力幅值
);

    // 符号处理(§23):负码一律钳 0,取绝对值是错误的
    wire [14:0] positive = raw_code[15] ? 15'd0 : raw_code[14:0];

    // 零点校正 + 下溢饱和(比较后相减,不会绕回)
    assign corrected_code =
        (positive > ZERO_OFFSET) ? (positive - ZERO_OFFSET) : 15'd0;

endmodule
