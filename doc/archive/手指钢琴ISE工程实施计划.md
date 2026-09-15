# 手指钢琴 ISE 工程 + GitHub 仓库 实施计划（v2）

> **HISTORICAL（第一阶段存档，2026-09-15 归档）**：本文是第一阶段实施计划的原样存档，**正文未做任何修改**。其中「尚未进行板卡烧录 / `program` 只跑过 PREVIEW ONLY / 尚未上板」等描述反映的是 2026-09-14 之前的状态，**已被后续真机写入取代**：`-Mode Jtag`（易失，`program -onlyFpga`）连续两次 PASS（`program-20260915-003257-7ef9c0de`、`program-20260915-003321-faf98f9b`），`-Mode Isf`（非易失，`program -p 1 -e -v`，显式擦除门禁）一次通过（`program-20260915-083244-bf54acda`，`Erase → Program → Verify` 全部成功）。**板卡功能仍未验证**——未做断电保持启动测试、未用示波器/频率计实测音高，`userDesignFunctional = NOT_TESTED`。当前状态一律以 `projects/finger_piano/README.md`、`doc/ISE工具链最终状态.md` 和 README.md 的「工具链冻结」章节为准，**不得再引用本文的烧录状态作为依据**。

- 状态：第一阶段软件工程已完成并验证，等待实际板级参数
- 目标器件：Xilinx Spartan-3AN `xc3s50an-4-tqg144`（`-4` 为暂定值，待按芯片丝印核对）
- 工具链：本机 PowerShell 7 编辑 → SSH/SFTP → Win7 `fpga-vm` 上的 ISE 14.7
- 本文件合并了评审文档《Agent 修改建议_手指钢琴ISE工程.md》的全部必须项与建议项

### 当前状态边界（务必区分“已验证”与“未做”）

已验证：RTL 综合（XST 0 errors / 0 warnings）、三个 testbench 的远端 ISim 六个用例（含极性两种取值、滤波旁路、12 MHz 频率算术）、静态合规检查、带真实引脚约束的实现与 bitstream 生成（run `20260914-204555-24cabc5e`，MAP/PAR/bitgen 0 errors / 0 warnings）、`TS_clk = PERIOD 83.33 ns` 0 timing errors（该结论来自本人阅读 `timing.twr`）。修订记录见 `projects/finger_piano/README.md` 第 13 节。

**尚未完成**：尚未进行板卡烧录（`program` 只跑过 PREVIEW ONLY）、尚未上板按键实测、尚未用示波器/频率计实测音高。任何“通过”结论都不包含以上三项。`summary.txt` 的时序结论仍为 `NEEDS_REVIEW`（UCF 未写 `OFFSET IN/OUT`，板级 I/O 时序未认证）。芯片速度等级仍为占位 `-4`，待按丝印核实。

> **状态更新说明（第六轮，2026-09-14）**：本文档 §0/§2/§4/§6/§12 中残留的 **2 MHz / `PERIOD = 500 ns` / `constraintsReviewed=false` / 全注释 UCF** 记载的是第一至第五轮的状态；**当前实际配置为 12 MHz（P57 有源晶振）、`PERIOD = 83.33 ns`、`constraintsReviewed=true`、UCF 已写入真实 LOC**，以 `projects/finger_piano/` 下的实际文件与 `projects/finger_piano/README.md` 第 7/13 节为准。

## 0. 已确认决策

| 项 | 值 |
|---|---|
| 器件 | `xc3s50an-4-tqg144`（`-4` 暂定，README/project.json 标注 TODO 待按丝印核实） |
| `SYS_CLK_HZ` | **`12_000_000`**（板上 P57 接 12 MHz 有源晶振，2026-09-14 用户确认；此前的 2 MHz 记载作废），唯一真值源 `src/finger_piano_cfg.vh`；UCF 已写入 `TIMESPEC "TS_clk" = PERIOD "clk_group" 83.33 ns HIGH 50%` |
| 验证深度 | `build -Stage synth` + `build -Stage bitstream` 成功 + 远端 `fuse`/ISim 编译并运行 3 个 Testbench，共 **6 组仿真运行**（含 `KEY_ACTIVE_HIGH` = 1/0、`KEY_FILTER_ENABLE` = 0、12 MHz 频率算术） |
| GitHub | `PanGucheng/ISE_prj`，仓库根 `D:\ISE_prj`，**当前为 public（公开）** |
| 交付工程约束 | **`constraintsReviewed=true`**（2026-09-14 用户确认 P57 12 MHz、可用 I/O P1–P40、I/O 电压 3.3 V 后填写：clk P57、rst_n P3、key_in P4/P5/P6/P7/P8/P10/P11、audio_out P12、key_debug P13/P15/P16/P18/P19/P20/P21、note_debug P24/P25/P27，全部 `LVCMOS33`） |
| 复位方案 | 实现 `reset_sync.v`（异步拉低、同步释放），内部统一用 `rst_n_sync` |
| 同步链属性 | `reset_sync.v` / `key_sync.v` 的 CDC 两级触发器带 `(* ASYNC_REG = "TRUE" *)`（XST 0 警告确认兼容） |

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

**交付文件计数口径**：`projects/finger_piano/` 目录内共 **14 个 tracked 文件**（`project.json`、7 个 `src/`、3 个 `sim/`、1 个 `constraints/`、`README.md`、`frequency_table.md`）；加上本仓库 `doc/` 下的这份实施计划，**项目相关交付文件合计 15 个**。仓库根的 `README.md`、`AGENTS.md`、`ise.ps1`、`tools/`、`templates/`、`projects/xc3s50an_smoke/` 属于工具链与既有测试工程，不计入这 15 个（仓库 tracked 文件总数为 26）。

## 2. 配置真值源与 project.json

`src/finger_piano_cfg.vh`（含 include guard）——全项目唯一出现具体频率的地方：

```verilog
`ifndef FINGER_PIANO_CFG_VH
`define FINGER_PIANO_CFG_VH
`define SYS_CLK_HZ        12000000  // 板上 P57 有源晶振 12 MHz（2026-09-14 确认），UCF PERIOD = 83.33 ns
`define KEY_STABLE_MS     10        // 按键数字稳定滤波默认 10 ms
`define KEY_FILTER_ENABLE 1         // 0 = 关闭滤波（纯直通）
`define KEY_ACTIVE_HIGH   1         // 1 = 按下为高；0 = 按下为低
`define FP_FILTER_CNT_WIDTH 24      // 12MHz/10ms 仅需 17 位，24 位留裕量
`define FP_TONE_CNT_WIDTH   24      // 真正的频率上限来自 32 位常量表达式
`endif
```

`project.json`：`sources` = 6 个 RTL（`reset_sync.v, key_sync.v, key_filter.v, note_encoder.v, tone_generator.v, finger_piano_top.v`，顶层最后）；`includeDirs": ["src"]`；`includeFiles": ["src/finger_piano_cfg.vh"]`；`ucf": "constraints/finger_piano.ucf"`；`constraintsReviewed": false`；`optimization": "Speed"`，`optimizationLevel": 1`。

依据工具实现：`includeFiles` 只上传+哈希、不进 `sources.prj`；`includeDirs` 生成 XST `-vlgincdir {../inputs/src}`，与 `` `include "finger_piano_cfg.vh" `` 对应。

## 3. RTL 规格（全部 Verilog-2001；仅 `clk` 单时钟域）

- **`reset_sync.v`**：`clk, rst_n → rst_n_sync`。`always @(posedge clk or negedge rst_n)` 内两级移位，复位全 0，输出低有效内部复位。异步拉低、同步释放。两级寄存器带 `(* ASYNC_REG = "TRUE" *)`（纯属性，不改变逻辑与端口，已确认 XST 0 警告）。
- **`key_sync.v`** `#(parameter WIDTH = 7)`：`meta → sync_out` 两级触发器（用 `rst_n_sync`），消除亚稳态。`meta` 带 `(* ASYNC_REG = "TRUE" *)`。
- **`key_filter.v`** `#(SYS_CLK_HZ, STABLE_MS, ENABLE, WIDTH = 7)`：`localparam integer STABLE_CYCLES = (SYS_CLK_HZ/1000)*STABLE_MS`（钳到 ≥1）；标准 Verilog-2001 generate：模块内先 `genvar i;`，再 `generate if (ENABLE != 0) begin : GEN_FILTER ... for (...) begin : GEN_KEY_FILTER`，循环体内各自声明 `reg [FP_FILTER_CNT_WIDTH-1:0] cnt; reg stable_q;`，`assign key_stable[i] = stable_q;`；输入与稳定值不同则计数，到 `STABLE_CYCLES-1` 更新并清零，相同则清零。`else` 分支 `assign key_stable = key_sync_in;`（关闭时零计数器、零资源）。
- **`note_encoder.v`**：纯组合、无 clk、无宏。`always @(*)` 的 `if/else if` 链按 **1>2>3>4>5>6>7**，末分支 `3'd0`；全条件覆盖 → 无锁存器。
- **`tone_generator.v`** `#(SYS_CLK_HZ)`：同步计数器 + terminal count，无门控时钟。频率表用 0.1 Hz 整数：2616/2937/3296/3492/3920/4400/4939；7 条内联 `localparam integer HP_x = (SYS_CLK_HZ*10 + F) / (2*F);`；组合 `case` 选 `half_target` 并钳 ≥1；复位/`note_code==0` → `audio_out=0`、计数清零；音符变化 → 相位重启；否则 terminal count 翻转 `audio_out`。
- **`finger_piano_top.v`**：参数仅 `SYS_CLK_HZ / KEY_STABLE_MS / KEY_FILTER_ENABLE / KEY_ACTIVE_HIGH`（无 `KEY_WIDTH`）；端口固定 `clk, rst_n, key_in[6:0], audio_out, key_debug[6:0], note_debug[2:0]`；`wire [6:0] key_normalized = KEY_ACTIVE_HIGH ? key_in : ~key_in;` 为全工程唯一极性归一化点；数据流 `reset_sync → key_sync → key_filter → note_encoder → tone_generator`。

## 4. UCF（模板 → 已填真实约束）

**第一轮**：全文件仅注释（ngdbuild 可解析、零虚构约束）。TODO 覆盖 `clk`、`rst_n`、`key_in<0..6>`、`audio_out`、`key_debug<0..6>`、`note_debug<0..2>`，附被注释的 `LOC`/`IOSTANDARD` 示例、`TNM_NET` 与 `TIMESPEC PERIOD`（`X = 1000/SYS_CLK_HZ(MHz)`，须与 `.vh` 一致）、可选 `OFFSET`。文件头写明：引脚与 bank 电压必须来自实际 TQ144 最小系统板原理图；debug 端口要么填 LOC、要么从最终顶层删除。

**第六轮实际状态**：板卡信息已由用户确认（P57 = 12 MHz 有源晶振、可用 I/O = P1–P40、I/O 电压 3.3 V），因此 UCF 已写入真实约束并把 `constraintsReviewed` 置 `true`：

| 信号 | 引脚 | | 信号 | 引脚 |
|---|---|---|---|---|
| `clk` | P57 | | `key_debug<0..6>` | P13/P15/P16/P18/P19/P20/P21 |
| `rst_n` | P3 | | `note_debug<0..2>` | P24/P25/P27 |
| `key_in<0..6>` | P4/P5/P6/P7/P8/P10/P11 | | 保留（不得占用） | P1=TMS、P2=TDI |
| `audio_out` | P12 | | 时钟约束 | `TS_clk = PERIOD "clk_group" 83.33 ns HIGH 50%` |

全部 I/O 为 `LVCMOS33`；另避开 P9/P17/P26/P34=GND、P14/P23=VCCO_3、P40=VCCO_2、P22=VCCINT、P36=VCCAUX、P33/P35=IPAD（仅输入）。仍未写 `OFFSET IN/OUT`（缺板级 I/O 时序数据），因此板级 I/O 时序未认证。

## 5. Testbench 规格（Verilog-2001，`sim/`）

- **`tb_note_encoder.v`**：`0000000→0`、7 个单键→1..7、全按→1、`2+3`→2、`6+7`→6、`3+5+7`→3；输出 `TB_NOTE_ENCODER: PASS/FAIL`。
- **`tb_tone_generator.v`**：`TB_SYS_CLK_HZ = 1_000_000`；测相邻 `audio_out` 边沿间周期数 `N`，`f = TB_SYS_CLK_HZ/(2N)` 与实数标称比，`|误差| < 1%`；验证静音与相位重启。
- **`tb_finger_piano_top.v`**：`TB_SYS_CLK_HZ = 1_000_000`、`TB_STABLE_MS = 1`、`TB_KEY_ACTIVE_HIGH = 1`、`TB_KEY_FILTER_ENABLE = 1`（三者均可用 `--generic_top` 覆盖）；窗口式滤波判据（999 周期仍无效、1008 周期已有效，`SYNC_MARGIN = 8`）；毛刺 300 周期被拒绝；小星星 `1 1 5 5 6 6 5  4 4 3 3 2 2 1`，每音约 20 ms 等效、音符间 ≥2 ms 等效释放并断言重复音符之间 `1→0→1`。当 `TB_KEY_FILTER_ENABLE = 0`（滤波旁路）时只跑最小用例：复位状态 → 按一个键 → 经两级同步后 `note_debug` 正确 → 松键恢复 0，且都要求在 `SYNC_MARGIN` 个周期内完成（以此证明旁路路径没有 10 ms 稳定延迟）。

## 6. 文档规格

- **`README.md`**：概述与器件 TODO；端口表；目录结构；模块关系图；4 个宏的配置方法；**课程资料“2 MHz 时基分频”与本工程单时钟实现的对应说明**（只允许 `ce_2m` 单周期使能，绝不生成 `clk_2m`，本阶段不实现；本工程实际时钟为 12 MHz，连分频都不需要）；引脚分配表；`constraintsReviewed=true` 前置检查清单（已满足）；ISE 综合/实现步骤；仿真步骤；计数器位宽与 214 MHz 边界表述；验证记录；阶段二扩展点。
- **`frequency_table.md`**：公式与 **12 MHz** 表（见下），以及改频后重算方法。

| 音符 | 标称 (Hz) | dHz | 半周期计数 N | 理论输出 (Hz) | 误差 |
|---|---|---|---|---|---|
| 1 C4 | 261.62 | 2616 | 22936 | 261.5975 | −0.0086% |
| 2 D4 | 293.67 | 2937 | 20429 | 293.7001 | +0.0103% |
| 3 E4 | 329.63 | 3296 | 18204 | 329.5979 | −0.0097% |
| 4 F4 | 349.23 | 3492 | 17182 | 349.2027 | −0.0078% |
| 5 G4 | 391.99 | 3920 | 15306 | 392.0031 | +0.0034% |
| 6 A4 | 440.00 | 4400 | 13636 | 440.0117 | +0.0027% |
| 7 B4 | 493.88 | 4939 | 12148 | 493.9085 | +0.0058% |

（12 MHz / `SYS_CLK_HZ = 12_000_000`；`N = (12000000*10 + dHz) / (2*dHz)` 向零截断。全部 `|误差| ≤ 0.0103% < 1%`，与 `projects/finger_piano/frequency_table.md` 第 2 节及 `tone_generator.v` 的 `localparam` 逐位一致。历史值：2 MHz 为 3823/3405/3034/2864/2551/2273/2025，50 MHz 为 95566/85121/75850/71592/63776/56818/50618。）

## 7. 构建与验证（按序，失败即停、如实报告）

1. `check -Project finger_piano -Stage synth` → PASS。
2. `build -Project finger_piano -Stage synth` → 退出码 0；读 `synthesis.srp` 与日志：0 ERROR、无 latch、无多驱动；确认 `design.ngc`；记录 run id。
3. `check -Project finger_piano -Stage implement` → **必须按设计失败**。
4. 静态合规检查：`genvar` 只允许独立声明；顶层无 `KEY_WIDTH`；极性逻辑只在顶层；时序边沿只允许 `posedge clk` 与 `negedge rst_n`/`negedge rst_n_sync`；无 `clk_2m`；具体时钟频率字面量只在 `cfg.vh`；无 SystemVerilog 特性。
5. 远端仿真：每 TB 一个 prj，`fuse -prj sim_<tb>.prj -top <tb> -i src -o <tb>.exe`，退出码与 `>` 之间留空格；运行 exe，120 s 超时，判据为日志出现 `PASS`；极性用例加跑 `--generic_top "TB_KEY_ACTIVE_HIGH=0"`；若无法批处理运行则如实报告“仅完成 fuse 编译验证”。
6. 结果写入 README；`summary.txt` 时序结论保持 NEEDS_REVIEW。

## 8. Git 与 GitHub

1. `git init -b main` → 提交既有工作区。
2. 新工程完成并通过验证后提交第二个 commit。
3. 推送前检查 `git ls-files` 无密钥/密码文件。
4. `gh repo create ISE_prj --private --source=. --remote=origin --push`（创建时用私有；仓库随后由用户手动改为 **public**）。
5. 验证仓库可见性（当前 **public**）、默认分支 main、远端 HEAD 与本地一致、`git status` 干净。

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
[x] ISE 工程可创建、可打开；Device = xc3s50an-4-tqg144（-4 待丝印核对）
[x] RTL 为 Verilog-2001；不存在 `for (genvar ...)`；顶层无伪参数 KEY_WIDTH
[x] KEY_ACTIVE_HIGH 已参数化，极性只在顶层归一化一次
[x] key_sync 两级同步；key_filter 可开可关，关闭时综合为直通路径（旁路模式已仿真验证）
[x] note_encoder 优先级 1 > 2 > … > 7 正确
[x] tone_generator 七音理论误差 < 1%；无键 audio_out=0；音符切换相位重启
[x] 只有唯一 clk 时钟域；无门控时钟、无 clk_2m
[x] reset_sync 实现异步拉低/同步释放，内部统一用 rst_n_sync
[x] 三个 TB 均可编译；顶层 TB 用窗口式判据并覆盖同步器延迟
[x] 小星星重复音符之间存在真实释放（key_stable 经历 1→0→1）
[x] 综合退出码 0，无 ERROR、无 latch
[x] UCF 无虚构 LOC/IOSTANDARD：全部约束来自用户确认的板卡信息（P57 12 MHz、P1–P40 可用、3.3 V）；`constraintsReviewed=true` 由用户确认驱动
[x] implement 门禁放开后 `check -Stage implement` PASS，且实现/bitstream 真实跑通（run 20260914-204555-24cabc5e）
[x] README 写明课程资料 2 MHz 时基要求与本工程单时钟实现的对应关系（实际时钟 12 MHz）
[x] README/UCF 写明 debug 顶层端口的最终约束策略
[x] 仓库已推送（当前 public），git status 干净，远端 HEAD 与本地一致
[x] frequency_table.md 的 PowerShell 重算脚本显式 Floor，12 MHz 下七个 N（22936/20429/18204/17182/15306/13636/12148）与 RTL 完全一致
[x] 滤波计数器容量公式含 /1000，12 MHz/10 ms = 120000 周期（17 位够）、24 位裕量、上限约 1398 ms 均核对
[x] KEY_FILTER_ENABLE=0 旁路最小验证 PASS
[x] `TS_clk = PERIOD 83.33 ns` 0 timing errors、最差 slack 70.697 ns（结论来自实际阅读 timing.twr）

尚未完成：
[ ] 板卡烧录（`program` 至今只跑过 PREVIEW ONLY；当前 fpga-vm 内下载线不可见 → CABLE_NOT_FOUND）
[ ] 上板按键实测与音高实测（示波器/频率计）
[ ] 芯片速度等级按丝印核实（当前占位 -4）
[ ] 若需要板级 I/O 时序认证，须补 UCF 的 OFFSET IN/OUT（需板卡器件手册数据）
```

## 13. 假设

按键经外部调理后为 0/1 数字电平，极性由 `KEY_ACTIVE_HIGH` 选择（默认按下=1）；`rst_n` 低有效、外部有上拉/RC；`audio_out` 50% 占空比方波直驱 LM386，无 PWM 音量；外部有源晶振直接进全局时钟引脚，不用 DCM/PLL。
