//=============================================================================
// audio_gain_12bit.v
// DDS 数字音量控制(P8 计划 Commit A)—— 12-bit unsigned 采样围绕 DAC
// 中点 2048 的 3-bit 数字增益。
//
//   sample_out = 2048 + delta × volume_level / 8,  delta = sample_in - 2048
//
// 冻结语义(P8 §3~§8):
//   - volume_level = 0..7:0 = 数字静音(输出恒 2048,不是 DAC 0);7 =
//     第一版最大数字音量(7/8)。不声称扬声器最大音量,不定义压力分级;
//   - 增益只作用于 delta,禁止 sample_in × gain(否则 DAC 直流中心随音量
//     移动);
//   - 无通用乘法器(§6):按 shift/add 表实现,负数右移全部为算术右移
//     ($signed >>>,floor 语义);TB 参考模型使用同一 floor 规则;
//   - 纯组合逻辑,无第二时钟域、无握手(§1/§2);
//   - 不饱和逻辑:12-bit 全范围输入下 |delta| ≤ 2048,任意 level 的
//     |scaled| ≤ |delta|(level 7 = delta - delta/8 同样收缩),故
//     2048 + scaled ∈ [0, 4095] 数学上不可越界——TB 对 4096 × 8 全部
//     32768 组合穷举证明无 wrap(§7/§26);刻意不加不可达的饱和分支,
//     避免 XST trim 出新 warning 漂移已冻结的 allowlist(§19)。
//
// 本模块位于 DDS 之后、MCP4725 controller 之前(P8 §11/§12);不修改
// DDS 核心,不读取压力数据(P8 §17)。
//=============================================================================

module audio_gain_12bit (
    input  wire [11:0] sample_in,     // 12-bit unsigned,2048 = DAC 中点
    input  wire [2:0]  volume_level,  // 0..7,增益 = level/8
    output wire [11:0] sample_out
);

    //-------------------------------------------------------------------------
    // 有符号差:13-bit signed 显式扩位(P8 §5,不依赖隐式扩展)
    //-------------------------------------------------------------------------
    wire signed [12:0] delta = $signed({1'b0, sample_in}) - 13'sd2048;

    // 算术右移(floor):负数向 -inf 截断,与 TB 参考模型一致。
    // 移位结果 ∈ [-1024,1023],12-bit signed 无损容纳(§19 卫生:
    // 不留恒 0/冗余符号位,避免 Xst:646 trim warning)。
    wire signed [11:0] delta_half = delta >>> 1;
    wire signed [11:0] delta_quar = delta >>> 2;
    wire signed [11:0] delta_eigh = delta >>> 3;

    reg  signed [11:0] scaled;

    //-------------------------------------------------------------------------
    // shift/add 增益表(P8 §6):0、δ/8、δ/4、δ/4+δ/8、δ/2、δ/2+δ/8、
    // δ/2+δ/4、δ-δ/8。12-bit signed([-2048,2047])足以容纳全部中间和
    // (最大 |δ-δ/8| = 1792),case 全分支完整赋值,无锁存器。
    //-------------------------------------------------------------------------
    always @(*) begin
        case (volume_level)
            3'd0:    scaled = 12'sd0;
            3'd1:    scaled = delta_eigh;
            3'd2:    scaled = delta_quar;
            3'd3:    scaled = delta_quar + delta_eigh;
            3'd4:    scaled = delta_half;
            3'd5:    scaled = delta_half + delta_eigh;
            3'd6:    scaled = delta_half + delta_quar;
            default: scaled = delta - delta_eigh;
        endcase
    end

    //-------------------------------------------------------------------------
    // 中心回加:数学范围 [0, 4095](见文件头),直接截断到 12-bit 输出
    // 即为全值——不引入宽位中间信号,避免恒 0 高位被 XST trim 出
    // "assigned but never used" warning(allowlist 卫生)。
    //-------------------------------------------------------------------------
    assign sample_out = 14'sd2048 + scaled;

endmodule
