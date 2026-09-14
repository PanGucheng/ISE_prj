//=============================================================================
// finger_piano_cfg.vh
// 手指钢琴工程 —— 全局配置真值源（single source of truth）
//
// 本文件是整个工程中唯一允许出现具体系统时钟频率的地方。
// 任何依赖时钟的逻辑都必须通过 parameter SYS_CLK_HZ（以本文件的宏为默认值）
// 获得频率，禁止在其它模块里硬编码频率。
//
// 修改频率只需改这一处，然后：
//   1) 按 frequency_table.md 第 4 节重算半周期计数表；
//   2) 更新 constraints/finger_piano.ucf 中 TIMESPEC PERIOD 的注释值。
//=============================================================================

`ifndef FINGER_PIANO_CFG_VH
`define FINGER_PIANO_CFG_VH

// 外部有源晶振频率（Hz）。TODO: 必须以板上实际晶振频率替换本占位值！
// 允许范围：远大于 2*493.88 Hz，且 SYS_CLK_HZ*10 不得溢出 32 位有符号整数
//           （即 <= 约 214 MHz）。
`define SYS_CLK_HZ        50000000

// 按键数字稳定滤波时间（ms）。默认 10 ms。
// 生效容量条件（注意 /1000，ms 与 Hz 差千倍）：
//   (SYS_CLK_HZ / 1000) * KEY_STABLE_MS <= 2**`FP_FILTER_CNT_WIDTH
`define KEY_STABLE_MS     10

// 按键数字稳定滤波开关：1 = 开启；0 = 关闭（纯直通，综合为 assign，零计数器）。
`define KEY_FILTER_ENABLE 1

// 外部 7 路输入有效极性：1 = 按下为高电平；0 = 按下为低电平。
// 极性归一化只在 finger_piano_top.v 中做一次。
`define KEY_ACTIVE_HIGH   1

// 滤波计数器位宽。RTL 计算 STABLE_CYCLES = (SYS_CLK_HZ / 1000) * STABLE_MS；
// 50 MHz / 10 ms 时为 500000，19 位已足够（2^19 = 524288），24 位为更高系统
// 时钟和更长滤波时间预留裕量。容量条件：
//   (SYS_CLK_HZ / 1000) * KEY_STABLE_MS <= 2**`FP_FILTER_CNT_WIDTH
// 24 位、50 MHz 下 KEY_STABLE_MS 上限约 335 ms（2^24 / 50000 = 335.5）。
`define FP_FILTER_CNT_WIDTH 24

// 音频半周期计数器位宽。50 MHz 下最高音 B4 只需 50618（16 位），24 位充足。
`define FP_TONE_CNT_WIDTH   24

`endif // FINGER_PIANO_CFG_VH
