# `tone_dac_demo` 独立工程实施计划

> **用途**：交给 Agent 直接执行  
> **仓库**：`PanGucheng/ISE_prj`  
> **基线**：当前 `main` 最新提交 `fb3f2abf064708957b48ef2249387faae78f0981`（2026-09-17）  
> **新工程目标**：3-bit 数字输入 `000~111` 同时产生对应音高的 **50% 方波** 和 **MCP4725 模拟正弦波**  
> **原则**：新开独立工程，不修改现有 `projects/finger_piano`、`projects/finger_piano_periph_test` 或其它已验证工程  
> **板级引脚原则**：凡最终工程已有同名功能，**严格复用最终 Stage-2 冻结引脚**；只有 `square_out` 是本独立验证工程额外增加的临时输出

---

## 0. Agent 开始前必须做的事

开始改代码前，按顺序阅读：

1. `/AGENTS.md`
2. `/projects/finger_piano/AGENTS.md`
3. `/projects/finger_piano/README.md`
4. `/projects/finger_piano/project.json`
5. `/projects/finger_piano/constraints/finger_piano.ucf`
6. 本计划

然后确认仓库当前 `main` 没有比本计划记录的基线更新的提交。

若 `main` 已经前进：

- 以**最新源码 / project.json / UCF** 为事实来源；
- 重新核对本计划列出的模块路径和引脚；
- 若最终 Stage-2 UCF 的冻结引脚发生变化，**停止实施并报告差异**，不得按旧表继续写 UCF。

不得依据历史 `doc/archive/` 猜当前状态。

---

# 1. 本工程要完成什么

新建：

```text
projects/tone_dac_demo/
```

实现：

```text
sensor_async[2:0]
      │
      ▼
最终工程同款输入前端
同步 + 码字滤波 + 编码
      │
      └──────── note_code[2:0] ────────┐
                                       │
                 ┌─────────────────────┴─────────────────────┐
                 │                                           │
                 ▼                                           ▼
          tone_generator                         dds_mcp4725_pipeline
                 │                                           │
                 ▼                                           ▼
           square_out                               P102/P103 I2C
                                                             │
                                                             ▼
                                                          MCP4725
                                                             │
                                                             ▼
                                                        模拟正弦波
```

固定编码：

```text
000 = 静音
001 = C4 = 261.62 Hz
010 = D4 = 293.67 Hz
011 = E4 = 329.63 Hz
100 = F4 = 349.23 Hz
101 = G4 = 391.99 Hz
110 = A4 = 440.00 Hz
111 = B4 = 493.88 Hz
```

要求同一个 `note_code` 同时驱动：

- 方波发生器；
- DDS → MCP4725 正弦波链路。

**禁止分别维护两份音符编码状态。**

---

# 2. 与最终工程的关系

本工程不是最终手指钢琴顶层的替代品，而是一个单独的课程验收/排障工程。

目的：

1. 先证明 3-bit 数字输入到音高映射正确；
2. 先证明方波基础功能正确；
3. 先证明同频 DDS 正弦能通过 MCP4725 输出；
4. 尽量沿用最终工程接线，减少之后切回 `finger_piano` 时重新插线；
5. 将传感器模拟前端、ADS1115 压力采样、音量、LM386 等问题与数字音频链隔离。

本工程**不包含**：

```text
ADS1115
pressure_processor
FSR 标定
pressure → volume
数字音量控制
LM386
扬声器
显示
自动演奏
```

---

# 3. 引脚分配——优先完全复用最终工程

当前最终 Stage-2 冻结引脚为：

| 新工程信号 | LOC | 方向 | 与最终工程关系 | 说明 |
|---|---:|---|---|---|
| `clk` | `P57` | input | **完全一致** | 12 MHz 唯一系统时钟 |
| `rst_n` | `P3` | input | **完全一致** | 低有效复位 |
| `sensor_async[0]` | `P28` | input | **完全一致** | 权重 1 |
| `sensor_async[1]` | `P29` | input | **完全一致** | 权重 2 |
| `sensor_async[2]` | `P30` | input | **完全一致** | 权重 4 |
| `dac_i2c_scl` | `P102` | inout | **完全一致** | MCP4725 独立 I²C SCL |
| `dac_i2c_sda` | `P103` | inout | **完全一致** | MCP4725 独立 I²C SDA |
| `square_out` | `P110` | output | **临时占用** | 最终工程这里是 `note_debug[0]` |

全部采用：

```text
IOSTANDARD = LVCMOS33
```

系统时钟约束：

```text
12 MHz
PERIOD = 83.33 ns
```

## 3.1 `square_out=P110` 的特殊说明

最终工程：

```text
P110 = note_debug[0]
P111 = note_debug[1]
P113 = note_debug[2]
```

最终工程没有独立的数字方波输出，所以独立验收工程必须临时占用一个已有调试脚。

本计划固定：

```text
square_out = P110
```

理由：

- P110 已经在现有仓库中做过推挽输出测试；
- P110 在最终工程只承担 debug，不是 ADC/DAC 主功能引脚；
- 不占用最终工程的 ADS1115 `P31/P32`；
- 不改变 MCP4725 `P102/P103`；
- 切回最终工程时，只需恢复 P110 为 `note_debug[0]`。

**禁止 Agent 擅自把 `square_out` 改到 P31/P32/P102/P103。**

## 3.2 P31/P32 保留

本独立工程不实例化 ADS1115，但：

```text
P31/P32 必须保持空闲
```

因为最终工程固定为：

```text
P31 = adc_i2c_scl
P32 = adc_i2c_sda
```

不要为了“找一个方便的测试脚”占用它们。

## 3.3 I²C 上拉

MCP4725 总线继续使用外部：

```text
4.7 kΩ → 3.3 V
```

UCF 中：

- 不写内部 `PULLUP` 代替外部上拉；
- SCL/SDA 保持开漏 `0/Z` 语义；
- 不给 I²C SCL 建时钟约束；
- 不把 SCL 当作 HDL 时钟。

---

# 4. 顶层接口

新建：

```text
projects/tone_dac_demo/src/tone_dac_demo_top.v
```

顶层接口固定为：

```verilog
module tone_dac_demo_top (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] sensor_async,

    output wire       square_out,

    inout  wire       dac_i2c_scl,
    inout  wire       dac_i2c_sda
);
```

除非仿真确有必要，第一版不要增加额外物理 debug pin。

内部可以有：

```text
sensor_code_stable
note_code
dac_busy
dac_error
dac_overrun
dds_code_debug
dds_valid_debug
dac_ready_debug
```

但默认只用于仿真，不向 package pin 引出。

---

# 5. 输入链：直接复用最终工程语义

为了让这个独立工程和最终工程的 3-bit 输入表现尽可能一致，**不要重新写一个简单的 `assign note_code=sensor_async`**。

从当前 `finger_piano` 快照复制并复用：

```text
src/key_sync.v
src/input/sensor_code_filter.v
src/input/sensor_code_decoder.v
src/input/sensor_code_frontend.v
```

数据流保持：

```text
sensor_async
   ↓
极性归一化
   ↓
2FF synchronizer
   ↓
whole-vector atomic filter
   ↓
sensor_code_decoder
   ↓
note_code
```

参数保持最终工程当前默认：

```text
SYS_CLK_HZ          = 12_000_000
SENSOR_ACTIVE_HIGH  = 1
FILTER_ENABLE       = 1
STABLE_MS           = 10 ms
```

这样三位输入在未来直接接回 3 个 LM393 时，行为与最终工程一致。

不得：

- 去掉两级同步；
- 对三个 bit 分别做独立滤波；
- 把 `sensor_async` 当时钟；
- 为了仿真快而修改硬件默认 10 ms 语义。

测试中可使用 parameter/generic 缩短仿真，但硬件默认值不得变。

---

# 6. 复位链

复制并复用：

```text
projects/finger_piano/src/reset_sync.v
```

顶层只实例化一次：

```text
rst_n
  ↓
reset_sync
  ↓
rst_n_sync
```

然后：

```text
sensor_code_frontend
tone_generator
dds_mcp4725_pipeline
```

全部使用同一个 `rst_n_sync`。

不得在子模块再次实例化第二个 reset synchronizer。

---

# 7. 方波链

复制当前已验证的：

```text
projects/finger_piano/src/tone_generator.v
```

连接：

```text
note_code
   ↓
tone_generator
   ↓
square_out=P110
```

不得重新实现一份分频表。

要求：

```text
note_code = 0 → square_out = 0
note_code = 1..7 → 对应 C4..B4
占空比约 50%
音符切换时相位重启
```

频率验收目标：

```text
误差 < 1%
```

即使课程基础要求更宽松，也沿用现有工程已经达到的精度口径。

---

# 8. DDS + MCP4725 正弦链

优先直接复用当前已有集成模块：

```text
src/audio/sine_lut_12bit.v
src/audio/dds_sine_generator.v
src/audio/dds_mcp4725_pipeline.v
src/periph/i2c_master.v
src/periph/mcp4725_ctrl.v
```

连接：

```text
note_code
   ↓
dds_mcp4725_pipeline
   ↓
dac_i2c_scl / dac_i2c_sda
   ↓
MCP4725
   ↓
VOUT
```

保持当前已冻结数字参数：

```text
DDS sample rate = 8 kS/s
phase accumulator = 24 bit
DAC width = 12 bit
DAC center = 2048
MCP4725 address = 7'h60
MCP4725 I2C target = 333333 Hz
Fast Write only
EEPROM write forbidden
```

静音：

```text
note_code = 0
DAC sample = 2048
```

不得把 DAC 静音改成 0。

---

# 9. 配置文件策略

为避免修改成熟模块的 `include`，新工程中复制当前：

```text
projects/finger_piano/src/finger_piano_cfg.vh
```

到：

```text
projects/tone_dac_demo/src/finger_piano_cfg.vh
```

第一版**保持内容和关键宏值不变**。

不做“顺手清理”或重命名为 `tone_dac_demo_cfg.vh`，因为这会迫使修改所有已验证模块的 include。

新工程只是使用其中：

```text
SYS_CLK_HZ
KEY_STABLE_MS
KEY_FILTER_ENABLE
KEY_ACTIVE_HIGH
FP_FILTER_CNT_WIDTH
FP_TONE_CNT_WIDTH
CFG_MCP4725_ADDR
CFG_DAC_I2C_SPEED
CFG_DAC_SAMPLE_RATE
```

未使用宏保留没有关系。

---

# 10. 建议目录

建立：

```text
projects/tone_dac_demo/
├─ project.json
├─ README.md
│
├─ src/
│  ├─ finger_piano_cfg.vh
│  ├─ reset_sync.v
│  ├─ key_sync.v
│  ├─ tone_generator.v
│  ├─ tone_dac_demo_top.v
│  │
│  ├─ input/
│  │  ├─ sensor_code_decoder.v
│  │  ├─ sensor_code_filter.v
│  │  └─ sensor_code_frontend.v
│  │
│  ├─ audio/
│  │  ├─ sine_lut_12bit.v
│  │  ├─ dds_sine_generator.v
│  │  └─ dds_mcp4725_pipeline.v
│  │
│  └─ periph/
│     ├─ i2c_master.v
│     └─ mcp4725_ctrl.v
│
├─ constraints/
│  └─ tone_dac_demo.ucf
│
└─ sim/
   ├─ models/
   │  └─ mcp4725_model.v
   ├─ tb_sensor_code_frontend.v
   ├─ tb_tone_generator.v
   ├─ tb_dds_mcp4725_pipeline.v
   └─ tb_tone_dac_demo_top.v
```

优先从当前 `finger_piano` **复制快照**。

禁止：

- symbolic link；
- 工程外相对路径；
- 新工程直接引用 `../finger_piano/src/...`；
- 修改原工程以“共享源码”。

---

# 11. `project.json`

器件沿用当前工程：

```text
xc3s50an-4-tqg144
```

注意：

- `-4` 仍按当前仓库事实使用，不在本任务里擅自改速度等级；
- top 固定为 `tone_dac_demo_top`；
- includeDirs = `["src"]`；
- includeFiles 显式列出 `src/finger_piano_cfg.vh`；
- UCF 指向 `constraints/tone_dac_demo.ucf`；
- testbench 不进入 synthesis `sources`；
- 所有路径用 ASCII 相对路径，无空格。

完成 UCF 人工比对后：

```text
constraintsReviewed = true
```

但这只能在 Agent 已逐项确认本计划引脚与最终 `finger_piano.ucf` 一致之后设置。

如果发现任意引脚与当前最终 UCF 不一致：

```text
STOP
```

不得为了 build 通过强行设为 true。

---

# 12. 新工程 UCF

`constraints/tone_dac_demo.ucf` 必须只包含本工程实际顶层端口。

目标内容语义：

```text
clk             P57
rst_n           P3

sensor_async[0] P28
sensor_async[1] P29
sensor_async[2] P30

dac_i2c_scl     P102
dac_i2c_sda     P103

square_out      P110

TS_clk          83.33 ns
```

不要加入：

```text
P31
P32
P111
P113
```

因为这些端口不在本独立工程顶层中。

UCF 注释必须明确：

```text
P110 在 tone_dac_demo 中临时作为 square_out；
最终 finger_piano Stage-2 中恢复为 note_debug[0]。
```

---

# 13. 仿真计划

## Stage A — 输入前端回归

复制/适配现有：

```text
tb_sensor_code_frontend.v
```

验证：

```text
000 → 0
001 → 1
010 → 2
011 → 3
100 → 4
101 → 5
110 → 6
111 → 7
```

并保留：

- 2FF 同步；
- 整体码字滤波；
- 多 bit 改变时不能提交瞬时中间码；
- 复位后稳定输出 `000`。

PASS pattern：

```text
TB_SENSOR_CODE_FRONTEND: PASS
```

---

## Stage B — 方波单元回归

复制当前：

```text
tb_tone_generator.v
```

必须在真实配置：

```text
SYS_CLK_HZ = 12 MHz
```

下至少验证：

| note | target |
|---:|---:|
| 1 | 261.62 Hz |
| 2 | 293.67 Hz |
| 3 | 329.63 Hz |
| 4 | 349.23 Hz |
| 5 | 391.99 Hz |
| 6 | 440.00 Hz |
| 7 | 493.88 Hz |

要求：

```text
frequency error < 1%
high/low half-period consistent
note=0 output low
note change restarts phase
```

PASS pattern：

```text
TB_TONE_GENERATOR: PASS
```

---

## Stage C — DDS→MCP4725 回归

复制当前：

```text
tb_dds_mcp4725_pipeline.v
sim/models/mcp4725_model.v
```

至少覆盖：

```text
mute
C4
D4
A4
B4
```

必须验证：

```text
sample cadence = 8 kS/s
MCP4725 Fast Write only
EEPROM writes = 0
dac_error = 0
dac_overrun = 0
sample mismatch = 0
```

PASS pattern：

```text
TB_DDS_MCP4725_PIPELINE: PASS
```

---

## Stage D — 新顶层联合仿真

新建：

```text
sim/tb_tone_dac_demo_top.v
```

这是本工程最重要的验收 TB。

对 `001~111` 逐个测试。

每个 note 都要同时证明：

```text
sensor_async
    ↓
note_code 正确

square_out
    ↓
对应频率

MCP4725 捕获 DDS 样点
    ↓
对应同一个 note 的正弦频率
```

必须避免只验证“两个模块分别能工作”。

要明确检查：

```text
同一个输入码 → 方波和 DDS 使用同一个 note_code
```

推荐至少记录：

```text
note
square measured frequency
DDS expected frequency
square frequency error
DDS phase increment
MCP4725 sample count
dac_error
dac_overrun
```

静音测试：

```text
sensor_async = 000
square_out = 0
MCP4725 持续接收/保持中点语义
DAC code = 2048
```

PASS pattern：

```text
TB_TONE_DAC_DEMO_TOP: PASS
```

---

# 14. 开发阶段与提交节奏

严格按以下阶段执行。

## A — Scaffold

创建：

```text
projects/tone_dac_demo/
project.json
README.md
constraints/tone_dac_demo.ucf
基础目录
```

复制所需已验证模块，但先不做功能重写。

检查：

```powershell
pwsh -File .\ise.ps1 check -Project tone_dac_demo -Stage synth
```

通过后 commit + push。

建议 commit：

```text
tone_dac_demo: add standalone project scaffold
```

---

## B — Input + Square Path

完成：

```text
reset_sync
sensor_code_frontend
tone_generator
tone_dac_demo_top 的方波部分
```

运行：

```powershell
pwsh -File .\ise.ps1 sim -Project tone_dac_demo -Test sensor_code_frontend
pwsh -File .\ise.ps1 sim -Project tone_dac_demo -Test tone_generator_12m
```

全部出现 PASS 后 commit + push。

建议 commit：

```text
tone_dac_demo: add 3-bit input and square-wave path
```

---

## C — DDS + MCP4725 Path

加入：

```text
sine_lut_12bit
dds_sine_generator
i2c_master
mcp4725_ctrl
dds_mcp4725_pipeline
mcp4725_model
```

运行独立 pipeline simulation。

要求：

```text
PASS
overrun=0
error=0
EEPROM=0
```

通过后 commit + push。

建议 commit：

```text
tone_dac_demo: add DDS MCP4725 sine path
```

---

## D — Top Integration

新建/完善：

```text
tb_tone_dac_demo_top.v
```

逐个验证：

```text
000~111
```

以及方波/DDS 对同一 note 的一致性。

通过后 commit + push。

建议 commit：

```text
tone_dac_demo: verify dual waveform integration
```

---

## E — Full Verify

运行：

```powershell
pwsh -File .\ise.ps1 verify -Project tone_dac_demo
```

要求至少：

```text
configuration PASS
static checks PASS
all simulations PASS
synthesis errors = 0
unexpected synthesis warnings = 0
latches = 0
implementation gate PASS
overall PASS
```

若新工程没有“无消费方层级”，优先要求：

```text
synthesis warnings = 0
```

不要照搬 `finger_piano` Stage-2 的 166-warning allowlist。

**严禁复制最终工程 warning allowlist 来掩盖新工程问题。**

通过后 commit + push。

---

## F — Bitstream

运行：

```powershell
pwsh -File .\ise.ps1 build -Project tone_dac_demo -Stage bitstream
```

检查：

```text
MAP errors = 0
PAR errors = 0
all bonded IOBs LOCATED
DRC errors = 0
timing constraints met
design.bit exists
```

必须实际读取：

```text
timing.twr
```

确认 `TS_clk = 83.33 ns` 满足后才能写“Timing PASS”。

记录 run ID。

通过后 commit + push README 状态。

---

# 15. 上板测试计划

**默认到这里停止。Agent 不得自行 program。**

只有用户明确要求后，才进入硬件写入。

优先：

```text
Mode Jtag
```

做易失配置。

不得在没有用户明确要求的情况下：

```text
program -Mode Jtag
program -Mode Isf
```

---

## Board Test 1 — 方波

设置：

```text
sensor_async = 001
```

示波器：

```text
P110 = square_out
```

预期：

```text
约 261.62 Hz
约 50% duty
```

然后测 2~7。

---

## Board Test 2 — MCP4725 I²C

测：

```text
P102 = SCL
P103 = SDA
```

确认：

```text
I2C activity exists
open-drain high level由外部上拉形成
无明显总线卡低
```

---

## Board Test 3 — DAC 静音中点

输入：

```text
000
```

观察 MCP4725 VOUT。

数字目标：

```text
D = 2048
VOUT ≈ VDD / 2
```

若 MCP4725 VDD=3.3 V，理论约：

```text
1.65 V
```

板上测量值只能按实测记录，不因理论值直接写 PASS。

---

## Board Test 4 — 正弦频率

输入：

```text
001
```

MCP4725 VOUT：

```text
≈ 261.62 Hz
```

依次测试 1~7。

8 kS/s 下高音会有可见阶梯，不因阶梯本身判 FAIL。

---

## Board Test 5 — 双通道展示

推荐最终展示：

```text
CH1 → P110 square_out
CH2 → MCP4725 VOUT
```

例：

```text
001:
CH1 ≈261.62 Hz square
CH2 ≈261.62 Hz sine

110:
CH1 ≈440 Hz square
CH2 ≈440 Hz sine
```

核心验收点：

```text
同一 3-bit 输入
→ 两路波形同时改变
→ 两路基频一致
→ 波形类型分别为方波 / 正弦波
```

---

# 16. README 必须记录

`projects/tone_dac_demo/README.md` 至少写：

1. 工程目的；
2. 基线 commit；
3. 复制自 `finger_piano` 的模块列表；
4. 3-bit 编码表；
5. 引脚表；
6. 明确 `P110` 是临时 `square_out`，最终工程为 `note_debug[0]`；
7. 仿真 run IDs；
8. verify run ID；
9. bitstream run ID；
10. timing 结论及证据；
11. `BOARD TEST = NOT_TESTED`，直到真正测量；
12. 若后续上板，逐项记录测得频率；
13. 不得把 `programmingVerified` 写成 `BOARD PASS`。

---

# 17. 禁止事项

Agent 不得：

```text
修改 projects/finger_piano 的 RTL
修改 projects/finger_piano 的 project.json
修改 projects/finger_piano 的最终 UCF
修改 periph_test
删除 legacy baseline

猜新引脚
占用 P31/P32 做方波
改变 P102/P103 DAC 总线
交换 P28/P29/P30 位序
把 sensor_async 当时钟

重新设计已有 DDS
重新设计已有 MCP4725 controller
修改 8 kS/s cadence
修改 phase increment 表
把 DAC 静音改为 0
允许 MCP4725 EEPROM write

创建第二时钟域
把 square_out 当时钟
把 I2C SCL 当时钟

使用 KEEP/DONT_TOUCH 掩盖 warning
关闭 failOnSynthesisWarnings
照搬 Stage-2 166-warning allowlist

为了 build 通过自动猜 LOC
为了 build 通过未经核对设置 constraintsReviewed=true

自动执行 JTAG program
自动执行 ISF program
```

---

# 18. STOP 条件

出现以下任意情况，立即停止当前阶段并报告：

```text
最终 finger_piano UCF 与本计划引脚不一致

复制模块后行为与原工程回归不一致
sensor input TB FAIL
tone generator TB FAIL
DDS pipeline TB FAIL
top integration TB FAIL

DDS sample cadence 不再是 8 kS/s
dac_overrun != 0
dac_error != 0
发现 EEPROM write

新出现 latch
新增 unexpected XST warning
MAP/PAR error
unlocated I/O
DRC error
timing constraint fail

必须修改最终工程才能继续
必须改已冻结 MCP4725 协议才能继续
必须改变最终引脚才能继续

需要硬件 program 才能继续
```

对最后一项：

```text
STOP 并等待用户明确授权
```

---

# 19. 最终软件验收清单

```text
[ ] 独立 projects/tone_dac_demo 已建立
[ ] 原 finger_piano 未被修改
[ ] 原 periph_test 未被修改

[ ] clk=P57
[ ] rst_n=P3
[ ] sensor_async[0]=P28
[ ] sensor_async[1]=P29
[ ] sensor_async[2]=P30
[ ] dac_i2c_scl=P102
[ ] dac_i2c_sda=P103
[ ] square_out=P110（临时）
[ ] P31/P32 未占用
[ ] TS_clk=83.33ns

[ ] 000=静音
[ ] 001=C4
[ ] 010=D4
[ ] 011=E4
[ ] 100=F4
[ ] 101=G4
[ ] 110=A4
[ ] 111=B4

[ ] sensor_code_frontend 复用
[ ] reset_sync 复用
[ ] tone_generator 复用
[ ] sine_lut_12bit 复用
[ ] dds_sine_generator 复用
[ ] dds_mcp4725_pipeline 复用
[ ] i2c_master 复用
[ ] mcp4725_ctrl 复用

[ ] 方波七音误差 <1%
[ ] 方波约 50% duty
[ ] 静音方波=0

[ ] DDS=8kS/s
[ ] DDS静音=2048
[ ] MCP4725 Fast Write only
[ ] EEPROM write=0
[ ] dac_error=0
[ ] dac_overrun=0

[ ] 顶层 TB 同时验证方波和DDS
[ ] 同一 note_code 驱动两条链
[ ] 全部 simulation PASS

[ ] verify Overall PASS
[ ] synthesis error=0
[ ] unexpected warnings=0
[ ] latch=0

[ ] bitstream generated
[ ] all I/O LOCATED
[ ] DRC=0
[ ] MAP/PAR=0
[ ] timing.twr 人工阅读
[ ] TS_clk met

[ ] README 已记录 run IDs
[ ] BOARD TEST 仍标记 NOT_TESTED（若尚未上板）
[ ] 未执行任何未经用户授权的 program
```

---

# 20. Agent 最终汇报格式

完成软件阶段后，只按事实汇报：

```text
工程:
基线 commit:
最终 commit:

新增/复制文件:
修改旧工程: YES/NO

引脚:
clk:
rst_n:
sensor_async:
dac_i2c:
square_out:

Simulation:
- sensor frontend:
- tone generator:
- DDS MCP4725:
- top integration:

Verify:
run id:
overall:
synthesis errors:
synthesis warnings:
unexpected warnings:
latches:

Bitstream:
run id:
MAP:
PAR:
DRC:
IO LOCATED:
timing:
bit file:

Hardware:
program executed: YES/NO
board functional: PASS / FAIL / NOT_TESTED

Remaining:
```

在没有真实上板测量前：

```text
board functional = NOT_TESTED
```

不得写成 PASS。

---

# 21. 一句话执行目标

> 在不修改现有 `finger_piano` 的前提下，新建 `tone_dac_demo`；最大限度复用最终 Stage-2 的端口名、3-bit 输入链和冻结引脚，使用同一个 `note_code` 并行驱动已验证的 `tone_generator` 与 `DDS→MCP4725` 链，实现 `000~111 → 静音/C4~B4 → P110 方波 + MCP4725 同频正弦波`。软件阶段完成全部仿真、综合、实现、时序和 bitstream 验证后停止，任何 JTAG/ISF 写入必须等待用户明确授权。
