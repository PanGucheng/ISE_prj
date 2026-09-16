# finger_piano Agent 工作规则

本文件是 `projects/finger_piano` 的**项目宪法**，只回答三件事：

1. 这个项目最终要做什么（真实硬件不是 7 个传感器）；
2. 五份计划按什么顺序做；
3. 哪些线绝对不能踩。

仓库级工具链与烧录规则见根 `/AGENTS.md`；架构地图与计划索引见 `/doc/README.md`；具体实现细节一律看各阶段计划文档，**不要**把计划内容复制进本文件。

---

## 开始任何任务前必须阅读

按顺序读完再动手：

1. `/AGENTS.md` —— 仓库级：ISE 工具、构建、仿真、烧录、安全边界
2. `/doc/README.md` —— 项目架构地图、P1~P5 依赖关系、事实来源优先级
3. `/projects/finger_piano/README.md` —— 当前真实状态、历史验证记录、还没做的板级测试
4. `/projects/finger_piano/project.json` —— 器件、源文件顺序、仿真用例、门禁开关（**必读，不要凭记忆假设字段值**）
5. 用户指定的当前计划文档（`doc/` 下 P1~P5 之一）

**不要只读一份计划就直接改代码。** 计划描述目标，不代表功能已经存在。

---

## 信息优先级（冲突时以此为准）

```
1. 当前源码 / project.json / UCF
        ↓
2. projects/finger_piano/README.md 中有实测或工具证据的当前状态
        ↓
3. doc/ISE工具链最终状态.md
        ↓
4. doc/README.md
        ↓
5. 当前开发计划文档（doc/P1~P5）
        ↓
6. doc/archive/ 历史文档
```

- **计划文档可以比当前源码更“先进”**，因为它描述的是待实现目标；**不得根据计划内容声称功能已经存在或已经通过验证**。
- `doc/archive/` 只用于历史追溯，**不得作为当前事实来源**；其中的烧录/时钟/引脚结论已被后续实测取代。

---

## 项目最终目标

真实硬件**不是 7 个压力传感器**。

```
3 × FSR
├─ TL084/RC → LM393 ×3 → 3-bit sensor code → note_code
└─ TL084/RC → ADS1115 → pressure data

note_code → DDS → MCP4725 → reconstruction filter → LM386 → speaker
```

编码固定：

```
000 = mute
001 = C4
010 = D4
011 = E4
100 = F4
101 = G4
110 = A4
111 = B4
```

## Legacy baseline

当前已经综合、仿真、实现并烧录验证过的：

```
key_in[6:0]
→ key_sync
→ key_filter
→ note_encoder
→ tone_generator
→ audio_out
```

是 **legacy baseline**。除非当前任务明确是「最终 3-bit 顶层迁移」，否则**不得删除或改写**这条路径。

**7-key RTL ≠ 最终真实硬件。**

## 当前扩展计划顺序

| 阶段 | 计划文档 |
|---|---|
| P1 | `doc/ADS1115与MCP4725可选外设开发计划.md` |
| P2 | `doc/3bit传感器编码输入基础设施开发计划.md` |
| P3 | `doc/DDS正弦音频发生器开发计划.md` |
| P4 | `doc/DDS到MCP4725数字音频链路集成计划.md` |
| P5 | `doc/ADS1115压力数据处理与标定基础设施开发计划.md` |

依赖关系：P1 只依赖 ISE 工具链；P2 依赖现有同步/滤波基础设施，与 P1 独立；P3 依赖 P1 的统一配置宏；P4 依赖 P1 + P3；P5 依赖 P1。

遵守各计划自己写的前置依赖，**不要把本来独立的阶段合并成一次大重构**。当前实施进度见 `/doc/README.md` 的「当前实施状态」表。

## 工具规则

修改 RTL / Testbench 后的主验收入口：

```powershell
pwsh -File .\ise.ps1 verify -Project finger_piano
```

单项调试：

```powershell
pwsh -File .\ise.ps1 sim -Project finger_piano -Test <name>
```

- 优先使用已有工具，**不自己拼新的 ISE / fuse / SSH 流程**。
- 工具链已经冻结：`doctor / new / check / build / fetch / sim / verify / report / probe / probe-diag / program / board-check`。
- **不得为了课程功能继续扩展烧录工具或新增命令。**
- `verify` 的 implement 门禁只看当前 `project.json` 的 `verification.expectImplementationBlocked`，**每次工作前重新读该字段**。

## 硬约束

- FPGA：`xc3s50an-4-tqg144`（速度等级 `-4` 仍是占位，待按丝印确认后才能改）
- 系统时钟：**12 MHz / P57**（有源晶振，唯一时钟源）
- Verilog-2001（不用 `logic` / `always_ff` / `always_comb` / `$clog2` 等）
- 单一 `clk` 时钟域，派生节拍用 **clock-enable**
- **不得**把 `audio_out` / I2C SCL / `sample_tick` 当作时钟
- 频率等时钟相关字面量只允许出现在 `src/finger_piano_cfg.vh`（TB 仿真参数除外）
- XST **0 errors / 0 warnings**（`failOnSynthesisWarnings=true`）。**unexpected synthesis warnings 必须为 0**；本工程唯一的例外是 `project.json` 的 `verification.synthesisWarningAllowlist` 中逐条审阅过的 Stage-2 trim 告警（当前为 12 脚顶层没有硬件消费方的 ADS1115 压力链/DDS debug 出口，共 166 条，见 README §12.5/§13）。计数漂移、新路径/类别一律 FAIL；**不得**加 `KEEP`/`DONT_TOUCH`/假消费者，也不得关闭 `failOnSynthesisWarnings`。
- 每个 testbench 必须打印明确的 `PASS` / `FAIL` pattern；**退出码 0 不算通过**

## 板级安全规则

- **不得猜 FPGA LOC**，不得写未确认的 IOSTANDARD / 引脚 / 时钟。
- 用户 2026-09-15 确认的**可用引脚池（38 脚）只表示这些脚可以用，不代表已经分配到具体功能**；候选分配（`sensor_async[2:0]`、两套 I²C）仍待用户逐脚确认。池、池与现状的差集、候选分配见 `doc/README.md` §12.1。
- 新增外设 GPIO 未经用户确认前：不进入顶层、不写 UCF LOC、不允许「MAP 自动分配了就当作完成」。
- `constraintsReviewed` 只代表人工确认过约束，**不得为了让工具产出 bitstream 而自动置 true**。
- 无人值守开发阶段**不得执行**：
  - `program -Mode Jtag`
  - `program -Mode Isf`
- 只有用户明确要求硬件写入时才允许执行 `program`，且必须带 `-ConfirmHardwareWrite`。

## ADC / DAC 原则

ADS1115 与 MCP4725 使用**两套独立 I²C 总线**，可复用同一份 `i2c_master.v`，但必须是两个独立实例。

- ADS1115：`AIN0/AIN1/AIN2`、single-shot、860 SPS、PGA ±4.096 V、raw 16-bit two's-complement
- MCP4725：12 bit、**只允许 Fast Write**、DDS 路径**禁止写 EEPROM**、默认 I²C 名义 333333 Hz（板上设计目标 18+18 = 36 拍）、音频 8 kS/s
- 协议依据只能是仓库内的 `doc/ads1115.pdf` 与 `doc/MCP4725.pdf`，不照抄网络示例

## 压力数据原则

没有真实 FSR 实测数据之前**不得猜测**：

- zero offset
- full scale
- light / normal / strong threshold
- 牛顿压力
- gain normalization

未测量的数据统一标记 `NOT_CALIBRATED` / `TODO`，等用户上板测量后填写。

## 状态口径

必须区分：`PLANNED` / `IMPLEMENTED` / `SIMULATED` / `INTEGRATED` / `NOT_INTEGRATED` / `NOT_CALIBRATED` / `NOT_BOARD_TESTED` / `PASS` / `NOT_TESTED`。

- `simulation PASS` **≠** `board PASS`
- `programmingVerified = VERIFIED` **≠** `userDesignFunctional = PASS`
- 工具永不打印 `BOARD PASS`；`userDesignFunctional` 固定为 `NOT_TESTED`

## 开发节奏

每一小阶段：

```
实现 → 单项 simulation → PASS → 独立 commit + push → 下一小阶段
```

整份计划完成：跑完整 `verify`（`.\ise.ps1 verify -Project finger_piano`）。

### 每完成一个阶段：自行提交并推送

**不需要逐次征询用户**——阶段做完就自己提交、自己推送：

1. **判定通过才提交**：对应 simulation 必须出现 `PASS`（整份计划收尾时完整 `verify` 全绿）。**任何时候都不得把失败的测试或未验证的状态推上去。**
2. **一个阶段一个 commit**，不要把多个阶段或无关重构夹进同一个 commit。
3. commit message 用 `type: summary` 风格（如 `dds: add sine LUT and its testbench`），正文写清 run ID、关键日志证据与仍未做的事。
4. 提交后立即 `git push origin main`（仓库只有 `main` 一条分支）。
5. 推送前检查：`git status` 无残留临时文件、无 `projects/*/artifacts/`、无 `tools/.work/`、无自己生成的构建产物。
6. 推送后同步更新 `projects/finger_piano/README.md` 的本轮记录与 `/doc/README.md` 的「当前实施状态」表。
7. **例外**：`program -Mode Jtag` / `-Mode Isf` 是硬件写入，**永远**要用户明确要求并带 `-ConfirmHardwareWrite`；本条规则只覆盖源码、测试与文档的提交推送。

出现 FAIL 时：**先修复**，不得禁用测试、放宽 PASS 条件、删除旧回归或继续叠加新功能。
