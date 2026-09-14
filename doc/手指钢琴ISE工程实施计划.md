# 手指钢琴 ISE 工程 + GitHub 仓库 实施计划（v2）

- 状态：已批准，正在实施
- 目标器件：Xilinx Spartan-3AN `xc3s50an-4-tqg144`（`-4` 为暂定值，待按芯片丝印核对）
- 工具链：本机 PowerShell 7 编辑 → SSH/SFTP → Win7 `fpga-vm` 上的 ISE 14.7
- 本文件合并了评审文档《Agent 修改建议_手指钢琴ISE工程.md》的全部必须项与建议项

## 0. 已确认决策

| 项 | 值 |
|---|---|
| 器件 | `xc3s50an-4-tqg144`（`-4` 暂定，README/project.json 标注 TODO 待按丝印核实） |
| `SYS_CLK_HZ` 占位 | `50_000_000`，唯一真值源 `src/finger_piano_cfg.vh` |
| 验证深度 | `build -Stage synth` 成功 + 远端 `fuse`/ISim 编译并运行三个 TB |
| GitHub | `PanGucheng/ISE_prj` 私有，仓库根 `D:\ISE_prj` |
| 交付工程约束 | `constraintsReviewed` 固定 `false`；UCF 无任何 `LOC`/`IOSTANDARD`/`TIMESPEC` |
| 复位方案 | 实现 `reset_sync.v`（异步拉低、同步释放），内部统一用 `rst_n_sync` |

### 相对初版的差异（增量，不改总体架构）

| # | 差异 | 来源 |
|---|---|---|
| 1 | `key_filter.v` 改用 `genvar i;` + `generate for (...)`，不用 `for (genvar i...)` | 必须项 2.1 |
| 2 | 删除顶层伪参数 `KEY_WIDTH`，端口固定 7 位，实例化写 `.WIDTH(7)` | 必须项 2.2 |
| 3 | 新增 `` `KEY_ACTIVE_HIGH ``，极性只在顶层归一化一次 | 必须项 2.3 |
| 4 | README 增加“2 MHz 课程时基 ↔ 本工程同步计数/clock-enable”对应说明，不产生 `clk_2m` | 必须项 2.4 |
| 5 | 顶层 TB 改为窗口式判据（`STABLE_CYCLES-1` 仍无效、`+SYNC_MARGIN` 已有效） | 必须项 2.5 |
| 6 | 小星星重复音符之间插入完整稳定释放段，验证 `1→0→1` | 必须项 2.6 |
| 7 | README/UCF 明确 debug 端口在 `constraintsReviewed=true` 前的 LOC 审核规则 | 必须项 2.7 |
| 8 | 新增 `src/reset_sync.v` | 建议项 3.1 |
| 9 | “214 MHz 上限”改述为 32 位常量表达式 `SYS_CLK_HZ*10` 溢出边界 | 建议项 3.2 |
| 10 | `FP_FILTER_CNT_WIDTH=24` 改述为“19 位已够、留裕量” | 建议项 3.3 |

## 1. 目录与交付物

先建目录骨架，再按 §11 顺序写文件：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 new -Project finger_piano
```

```
projects/finger_piano/
  project.json
  src/  finger_piano_cfg.vh  reset_sync.v  key_sync.v  key_filter.v
        note_encoder.v  tone_generator.v  finger_piano_top.v
  constraints/finger_piano.ucf        # 全 TODO 注释模板
  sim/  tb_note_encoder.v  tb_tone_generator.v  tb_finger_piano_top.v
  README.md  frequency_table.md
```

根 `README.md` 追加一行指向新工程。不改 `tools/ise-tools.ps1`、不改 `AGENTS.md`。

## 2. 配置真值源与 project.json

`src/finger_piano_cfg.vh`（含 include guard）——全项目唯一出现具体频率的地方：

```verilog
`ifndef FINGER_PIANO_CFG_VH
`define FINGER_PIANO_CFG_VH
`define SYS_CLK_HZ        50000000  // TODO: 必须改为板上实际有源晶振频率
`define KEY_STABLE_MS     10        // 按键数字稳定滤波默认 10 ms
`define KEY_FILTER_ENABLE 1         // 0 = 关闭滤波（纯直通）
`define KEY_ACTIVE_HIGH   1         // 1 = 按下为高；0 = 按下为低
`define FP_FILTER_CNT_WIDTH 24      // 50MHz/10ms 仅需 19 位，24 位留裕量
`define FP_TONE_CNT_WIDTH   24      // 真正的频率上限来自 32 位常量表达式
`endif
```

`project.json`：`sources` = 6 个 RTL（`reset_sync.v, key_sync.v, key_filter.v, note_encoder.v, tone_generator.v, finger_piano_top.v`，顶层最后）；`includeDirs": ["src"]`；`includeFiles": ["src/finger_piano_cfg.vh"]`；`ucf": "constraints/finger_piano.ucf"`；`constraintsReviewed": false`；`optimization": "Speed"`，`optimizationLevel": 1`。

依据工具实现：`includeFiles` 只上传+哈希、不进 `sources.prj`；`includeDirs` 生成 XST `-vlgincdir {../inputs/src}`，与 `` `include "finger_piano_cfg.vh" `` 对应。

## 3. RTL 规格（全部 Verilog-2001；仅 `clk` 单时钟域）

- **`reset_sync.v`**：`clk, rst_n → rst_n_sync`。`always @(posedge clk or negedge rst_n)` 内两级移位，复位全 0，输出低有效内部复位。异步拉低、同步释放。
- **`key_sync.v`** `#(parameter WIDTH = 7)`：`meta → sync_out` 两级触发器（用 `rst_n_sync`），消除亚稳态。
- **`key_filter.v`** `#(SYS_CLK_HZ, STABLE_MS, ENABLE, WIDTH = 7)`：`localparam integer STABLE_CYCLES = (SYS_CLK_HZ/1000)*STABLE_MS`（钳到 ≥1）；标准 Verilog-2001 generate：模块内先 `genvar i;`，再 `generate if (ENABLE != 0) begin : GEN_FILTER ... for (...) begin : GEN_KEY_FILTER`，循环体内各自声明 `reg [FP_FILTER_CNT_WIDTH-1:0] cnt; reg stable_q;`，`assign key_stable[i] = stable_q;`；输入与稳定值不同则计数，到 `STABLE_CYCLES-1` 更新并清零，相同则清零。`else` 分支 `assign key_stable = key_sync_in;`（关闭时零计数器、零资源）。
- **`note_encoder.v`**：纯组合、无 clk、无宏。`always @(*)` 的 `if/else if` 链按 **1>2>3>4>5>6>7**，末分支 `3'd0`；全条件覆盖 → 无锁存器。
- **`tone_generator.v`** `#(SYS_CLK_HZ)`：同步计数器 + terminal count，无门控时钟。频率表用 0.1 Hz 整数：2616/2937/3296/3492/3920/4400/4939；7 条内联 `localparam integer HP_x = (SYS_CLK_HZ*10 + F) / (2*F);`；组合 `case` 选 `half_target` 并钳 ≥1；复位/`note_code==0` → `audio_out=0`、计数清零；音符变化 → 相位重启；否则 terminal count 翻转 `audio_out`。
- **`finger_piano_top.v`**：参数仅 `SYS_CLK_HZ / KEY_STABLE_MS / KEY_FILTER_ENABLE / KEY_ACTIVE_HIGH`（无 `KEY_WIDTH`）；端口固定 `clk, rst_n, key_in[6:0], audio_out, key_debug[6:0], note_debug[2:0]`；`wire [6:0] key_normalized = KEY_ACTIVE_HIGH ? key_in : ~key_in;` 为全工程唯一极性归一化点；数据流 `reset_sync → key_sync → key_filter → note_encoder → tone_generator`。

## 4. UCF 模板

全文件仅注释（ngdbuild 可解析、零虚构约束）。TODO 覆盖 `clk`、`rst_n`、`key_in<0..6>`、`audio_out`、`key_debug<0..6>`、`note_debug<0..2>`，附被注释的 `LOC`/`IOSTANDARD` 示例、`TNM_NET` 与 `TIMESPEC PERIOD`（`X = 1000/SYS_CLK_HZ(MHz)`，须与 `.vh` 一致）、可选 `OFFSET`。文件头写明：引脚与 bank 电压必须来自实际 TQ144 最小系统板原理图；debug 端口要么填 LOC、要么从最终顶层删除。

## 5. Testbench 规格（Verilog-2001，`sim/`）

- **`tb_note_encoder.v`**：`0000000→0`、7 个单键→1..7、全按→1、`2+3`→2、`6+7`→6、`3+5+7`→3；输出 `TB_NOTE_ENCODER: PASS/FAIL`。
- **`tb_tone_generator.v`**：`TB_SYS_CLK_HZ = 1_000_000`；测相邻 `audio_out` 边沿间周期数 `N`，`f = TB_SYS_CLK_HZ/(2N)` 与实数标称比，`|误差| < 1%`；验证静音与相位重启。
- **`tb_finger_piano_top.v`**：`TB_SYS_CLK_HZ = 1_000_000`、`TB_STABLE_MS = 1`、`TB_KEY_ACTIVE_HIGH = 1`（可用 `--generic_top` 覆盖）；窗口式滤波判据（999 周期仍无效、1008 周期已有效，`SYNC_MARGIN = 8`）；毛刺 300 周期被拒绝；小星星 `1 1 5 5 6 6 5  4 4 3 3 2 2 1`，每音约 20 ms 等效、音符间 ≥2 ms 等效释放并断言重复音符之间 `1→0→1`。

## 6. 文档规格

- **`README.md`**：概述与器件 TODO；端口表；目录结构；模块关系图；4 个宏的配置方法；**2 MHz 课程时基对应说明**（只允许 `ce_2m` 单周期使能，绝不生成 `clk_2m`，本阶段不实现）；UCF 填写清单；`constraintsReviewed=true` 前置检查清单；ISE 综合/实现步骤；仿真步骤；计数器位宽与 214 MHz 边界表述；验证记录；阶段二扩展点。
- **`frequency_table.md`**：公式与 50 MHz 表（见下），以及改频后重算方法。

| 音符 | 标称 (Hz) | dHz | 半周期计数 N | 理论输出 (Hz) | 误差 |
|---|---|---|---|---|---|
| 1 C4 | 261.62 | 2616 | 95566 | 261.5993 | −0.0079% |
| 2 D4 | 293.67 | 2937 | 85121 | 293.6996 | +0.0101% |
| 3 E4 | 329.63 | 3296 | 75850 | 329.5979 | −0.0097% |
| 4 F4 | 349.23 | 3492 | 71592 | 349.2010 | −0.0083% |
| 5 G4 | 391.99 | 3920 | 63776 | 391.9970 | −0.0018% |
| 6 A4 | 440.00 | 4400 | 56818 | 440.0014 | +0.0003% |
| 7 B4 | 493.88 | 4939 | 50618 | 493.8955 | −0.0031% |

## 7. 构建与验证（按序，失败即停、如实报告）

1. `check -Project finger_piano -Stage synth` → PASS。
2. `build -Project finger_piano -Stage synth` → 退出码 0；读 `synthesis.srp` 与日志：0 ERROR、无 latch、无多驱动；确认 `design.ngc`；记录 run id。
3. `check -Project finger_piano -Stage implement` → **必须按设计失败**。
4. 静态合规检查：`genvar` 只允许独立声明；顶层无 `KEY_WIDTH`；极性逻辑只在顶层；时序边沿只允许 `posedge clk` 与 `negedge rst_n`/`negedge rst_n_sync`；无 `clk_2m`；`50000000` 只在 `cfg.vh`；无 SystemVerilog 特性。
5. 远端仿真：每 TB 一个 prj，`fuse -prj sim_<tb>.prj -top <tb> -i src -o <tb>.exe`，退出码与 `>` 之间留空格；运行 exe，120 s 超时，判据为日志出现 `PASS`；极性用例加跑 `--generic_top "TB_KEY_ACTIVE_HIGH=0"`；若无法批处理运行则如实报告“仅完成 fuse 编译验证”。
6. 结果写入 README；`summary.txt` 时序结论保持 NEEDS_REVIEW。

## 8. Git 与 GitHub

1. `git init -b main` → 提交既有工作区。
2. 新工程完成并通过验证后提交第二个 commit。
3. 推送前检查 `git ls-files` 无密钥/密码文件。
4. `gh repo create ISE_prj --private --source=. --remote=origin --push`。
5. 验证 `visibility=private`、默认分支 main、远端 HEAD 与本地一致、`git status` 干净。

## 9. 边界情况与失败模式

晶振未知 → 时序常量全部由 `SYS_CLK_HZ` 推导，UCF PERIOD 保持注释；引脚未知 → 不写 LOC/IOSTANDARD，implement 被 `constraintsReviewed=false` 拦住；`KEY_FILTER_ENABLE=0` → 纯直通；`KEY_ACTIVE_HIGH` 两种取值均须可用；`SYS_CLK_HZ` 过低 → 半周期钳到 1，过高（> ~214 MHz）→ 32 位常量表达式溢出；XST 找不到头文件 → 回退为字面默认值并声明顶层参数为唯一权威入口；连接中断 → 不自动重跑，先查远端 `run.status`，必要时 `fetch`。

## 10. 第一阶段明确不做

ADC、DDS、显示屏、数码管、PWM 音量、和弦、UART、自动演奏器、DCM/PLL、任何 `clk_2m` 时钟域（`ce_2m` 本阶段也不实现）。

## 11. 执行顺序

1. 写 `README.md` 与 `frequency_table.md`
2. 写 `src/finger_piano_cfg.vh`
3. 写 `src/key_filter.v`
4. 写 `src/finger_piano_top.v`、`reset_sync.v`、`key_sync.v`、`note_encoder.v`、`tone_generator.v`
5. 写三个 TB
6. 写 `constraints/finger_piano.ucf`
7. 覆盖 `project.json`
8. 跑 §7 全部检查
9. Git 初始化、两次提交、`gh repo create` 推送并验证

## 12. 验收清单

```
[ ] ISE 工程可创建、可打开；Device = xc3s50an-4-tqg144（-4 待丝印核对）
[ ] RTL 为 Verilog-2001；不存在 `for (genvar ...)`；顶层无伪参数 KEY_WIDTH
[ ] KEY_ACTIVE_HIGH 已参数化，极性只在顶层归一化一次
[ ] key_sync 两级同步；key_filter 可开可关，关闭时综合为直通路径
[ ] note_encoder 优先级 1 > 2 > … > 7 正确
[ ] tone_generator 七音理论误差 < 1%；无键 audio_out=0；音符切换相位重启
[ ] 只有唯一 clk 时钟域；无门控时钟、无 clk_2m
[ ] reset_sync 实现异步拉低/同步释放，内部统一用 rst_n_sync
[ ] 三个 TB 均可编译；顶层 TB 用窗口式判据并覆盖同步器延迟
[ ] 小星星重复音符之间存在真实释放（key_stable 经历 1→0→1）
[ ] 综合退出码 0，无 ERROR、无 latch
[ ] UCF 无任何虚构 LOC/IOSTANDARD/TIMESPEC；constraintsReviewed 仍为 false
[ ] check -Stage implement 按设计被阻止
[ ] README 写明 2 MHz 课程要求与本工程单时钟实现的对应关系
[ ] README/UCF 写明 debug 顶层端口的最终约束策略
[ ] 私有仓库已推送，git status 干净，远端 HEAD 与本地一致
```

## 13. 假设

按键经外部调理后为 0/1 数字电平，极性由 `KEY_ACTIVE_HIGH` 选择（默认按下=1）；`rst_n` 低有效、外部有上拉/RC；`audio_out` 50% 占空比方波直驱 LM386，无 PWM 音量；外部有源晶振直接进全局时钟引脚，不用 DCM/PLL。
