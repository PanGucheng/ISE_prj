
---

# finger_piano P6B 最终顶层与 UCF 迁移实施计划

> **Status**: READY TO IMPLEMENT
> **Scope**: Stage-2 physical top + UCF cutover + implementation verification
> **Depends on**: P6A COMPLETE
> **Pin assignment**: USER CONFIRMED / FROZEN
> **VCCO**: 3.3 V CONFIRMED
> **IOSTANDARD**: LVCMOS33
> **Hardware programming**: FORBIDDEN
> **Board test**: NOT INCLUDED
> **Acceptance**: stage2-top simulation + full `verify` + implementation + timing review

---

## 0. 执行前提

P6A 已完成：

```text
P1 ADC/DAC
P2 3-bit sensor input
P3 DDS
P4 DDS → MCP4725
P5 pressure processing
P6A system core
```

并已形成：

```text
src/system/finger_piano_system.v
```

当前正式工程顶层仍是：

```text
finger_piano_top
```

即 legacy 7-key 方波电子琴。

P6B 的任务是：

```text
保留 legacy top
       ↓
新增 stage2 top
       ↓
接入 finger_piano_system
       ↓
使用已确认真实 GPIO
       ↓
切换 project top
       ↓
重整 UCF
       ↓
重新 verify / implement
```

本计划不得修改 P1～P6A 已验证的核心逻辑，除非发现真实集成缺陷。

---

# 1. 最终 Stage-2 引脚冻结表

以下引脚现正式冻结。

| Stage-2 信号        |      LOC | Bank | XC3S50AN 管脚名      | 手册类型 | IOSTANDARD |
| ----------------- | -------: | ---: | ----------------- | ---- | ---------- |
| `clk`             |  **P57** |    2 | `IO_L09P_2/GCLK0` | GCLK | LVCMOS33   |
| `rst_n`           |   **P3** |    3 | `IO_L02P_3`       | I/O  | LVCMOS33   |
| `sensor_async[0]` |  **P28** |    3 | `IO_L11P_3`       | I/O  | LVCMOS33   |
| `sensor_async[1]` |  **P29** |    3 | `IO_L10N_3`       | I/O  | LVCMOS33   |
| `sensor_async[2]` |  **P30** |    3 | `IO_L11N_3`       | I/O  | LVCMOS33   |
| `adc_i2c_scl`     |  **P31** |    3 | `IO_L12P_3`       | I/O  | LVCMOS33   |
| `adc_i2c_sda`     |  **P32** |    3 | `IO_L12N_3`       | I/O  | LVCMOS33   |
| `dac_i2c_scl`     | **P102** |    1 | `IO_L10P_1`       | I/O  | LVCMOS33   |
| `dac_i2c_sda`     | **P103** |    1 | `IO_L11P_1`       | I/O  | LVCMOS33   |
| `note_debug[0]`   | **P110** |    0 | `IO_L01P_0`       | I/O  | LVCMOS33   |
| `note_debug[1]`   | **P111** |    0 | `IO_L01N_0`       | I/O  | LVCMOS33   |
| `note_debug[2]`   | **P113** |    0 | `IO_L02N_0`       | I/O  | LVCMOS33   |

该分配避免把主功能放到 JTAG、电源、GND、input-only、配置复用 DUAL、RHCLK 或额外 GCLK 管脚上。

---

# 2. 管脚功能分区冻结

最终形成：

```text
Bank 2
└── P57
    └── 12 MHz system clock

Bank 3
├── P3
│   └── reset
│
├── P28
├── P29
├── P30
│   └── LM393 sensor code [2:0]
│
├── P31
└── P32
    └── ADS1115 independent I2C bus

Bank 1
├── P102
└── P103
    └── MCP4725 independent I2C bus

Bank 0
├── P110
├── P111
└── P113
    └── note_debug[2:0]
```

所有相关 Bank：

```text
VCCO = 3.3 V
```

已由用户确认。

---

# 3. 为什么弃用原 DAC 候选 P76/P77

原候选：

```text
P76
P77
```

手册中分别是：

```text
P76 = IO_L01P_1/HDC
P77 = IO_L02N_1/LDC0
```

并标记：

```text
Type = DUAL
```

它们在配置阶段具有额外配置功能。

虽然配置完成后可以作为用户 I/O，但本工程有足够的纯用户 I/O，因此正式 Stage-2 不使用 P76/P77。

改为：

```text
P102 = IO_L10P_1
P103 = IO_L11P_1
```

二者均为：

```text
Type = I/O
```

这项决定冻结，不再退回 P76/P77。

---

# 4. 传感器 bit 顺序冻结

必须保持：

```text
LM393 CH0
→ P28
→ sensor_async[0]
→ binary weight 1

LM393 CH1
→ P29
→ sensor_async[1]
→ binary weight 2

LM393 CH2
→ P30
→ sensor_async[2]
→ binary weight 4
```

因此项目编码继续：

| `sensor_async[2:0]` | Note |
| ------------------- | ---- |
| `000`               | mute |
| `001`               | C4   |
| `010`               | D4   |
| `011`               | E4   |
| `100`               | F4   |
| `101`               | G4   |
| `110`               | A4   |
| `111`               | B4   |

Agent 不得交换：

```text
bit0
bit1
bit2
```

的物理含义。

---

# 5. I²C 物理接口冻结

## ADS1115

```text
ADS1115 SCL
→ P31
→ adc_i2c_scl

ADS1115 SDA
→ P32
→ adc_i2c_sda
```

## MCP4725

```text
MCP4725 SCL
→ P102
→ dac_i2c_scl

MCP4725 SDA
→ P103
→ dac_i2c_sda
```

两条物理总线继续完全独立。

禁止：

```text
shared SDA
shared SCL
I2C arbiter
bus mux
```

---

# 6. I²C 电气规则

两条总线全部使用：

```text
3.3 V
```

外部上拉。

目标接线：

```text
ADC_SCL ── 4.7kΩ ── 3.3V
ADC_SDA ── 4.7kΩ ── 3.3V

DAC_SCL ── 4.7kΩ ── 3.3V
DAC_SDA ── 4.7kΩ ── 3.3V
```

如果模块已经自带 3.3V 上拉：

> 不重复机械地再加 4.7kΩ，先检查模块原理图或实测。

UCF 不添加：

```text
PULLUP
```

作为真实 I²C 上拉替代。

现有 RTL 的开漏行为继续保持：

```text
drive 0
or
Z
```

不得主动驱动逻辑 1。

---

# 7. 新增正式 Stage-2 顶层

新增：

```text
projects/finger_piano/src/finger_piano_stage2_top.v
```

建议接口固定为：

```verilog
module finger_piano_stage2_top (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [2:0] sensor_async,

    inout  wire       adc_i2c_scl,
    inout  wire       adc_i2c_sda,

    inout  wire       dac_i2c_scl,
    inout  wire       dac_i2c_sda,

    output wire [2:0] note_debug
);
```

第一版不要继续增加其他顶层端口。

---

# 8. Stage-2 top 的职责

`finger_piano_stage2_top.v` 只能负责：

```text
external rst_n
      ↓
reset_sync
      ↓
rst_n_sync
      ↓
finger_piano_system
```

以及：

```text
note_code
→ note_debug
```

因此内部结构：

```text
                +------------+
rst_n --------> | reset_sync |
                +-----+------+
                      |
                 rst_n_sync
                      |
                      v
             +---------------------+
sensor ----> | finger_piano_system |
ADC I2C <--->|                     |
DAC I2C <--->|                     |
             +----------+----------+
                        |
                    note_code
                        |
                        v
                  note_debug
```

---

# 9. Stage-2 top 不得重复实现任何子系统

禁止在 Stage-2 top 中再次写：

```text
sensor synchronizer
sensor filter
sensor decoder

DDS
sine LUT

ADS controller
MCP controller

pressure processor
```

这些全部已经存在。

Stage-2 top 应当保持：

> wrapper only

---

# 10. Reset 处理

只实例化现有：

```text
reset_sync.v
```

生成：

```text
rst_n_sync
```

然后把同一个：

```text
rst_n_sync
```

送入：

```text
finger_piano_system
```

不得在：

```text
finger_piano_system
```

内部再增加一层 reset synchronizer。

---

# 11. `note_debug`

Stage-2 保留：

```text
note_debug[2:0]
```

原因：

第一次上板时可以快速确认：

```text
LM393
↓
sensor synchronization/filter
↓
decoder
↓
note_code
```

是否正确。

连接：

```verilog
assign note_debug = note_code;
```

不要增加额外寄存器或编码。

---

# 12. Stage-2 不再提供 legacy `audio_out`

新的提高功能音频路径是：

```text
note_code
↓
DDS
↓
MCP4725
↓
analog VOUT
↓
reconstruction LPF
↓
LM386
```

因此：

```text
finger_piano_stage2_top
```

不需要：

```text
audio_out
```

端口。

原 FPGA 方波：

```text
tone_generator → audio_out
```

只留在：

```text
finger_piano_top
```

legacy baseline 中。

---

# 13. Stage-2 不再提供 legacy 7-key 接口

Stage-2 top 不得包含：

```text
key_in[6:0]
key_debug[6:0]
```

真实输入现在是：

```text
sensor_async[2:0]
```

不要添加 legacy/stage2 mux。

---

# 14. Legacy top 必须继续保留

现有：

```text
src/finger_piano_top.v
```

不能删除。

现有：

```text
note_encoder.v
tone_generator.v
key_filter.v
```

也不能因为 Stage-2 切换而删除。

它们作为：

```text
legacy baseline
```

继续保留。

---

# 15. 新增 Stage-2 顶层 TB

新增：

```text
sim/tb_finger_piano_stage2_top.v
```

复用：

```text
sim/models/ads1115_model.v
sim/models/mcp4725_model.v
```

不再重新建立第三套行为模型。

---

# 16. Top TB 的目的

P6A 已经验证：

```text
finger_piano_system
```

本 TB 不需要重复全部 8000+ sample longrun。

它主要验证：

```text
physical-top wrapper wiring
+
reset wrapper
+
external inout wiring
+
note_debug
```

---

# 17. Stage-2 top TB 必测内容

至少：

### Reset

```text
rst_n = 0
```

要求：

```text
note_debug = 000
I2C buses released
```

---

### Sensor input

运行：

```text
000
001
011
111
000
```

每次满足真实滤波门限后：

```text
note_debug
```

必须对应：

```text
0
1
3
7
0
```

---

### DAC

至少确认：

```text
note 1
note 7
mute
```

均能产生 MCP4725 Fast Write。

---

### ADC

ADS 模型产生一轮：

```text
1000
2000
3000
```

确认系统内部能够继续完成 pressure frame。

不要求新增顶层 pressure debug pins。

---

### 双总线同时工作

检查：

```text
ADC transaction > 0
DAC transaction > 0
```

无：

```text
adc_error
dac_error
dac_overrun
```

---

# 18. TB 中 I²C 必须使用逻辑 pullup

ISim 中：

```verilog
pullup(adc_i2c_scl);
pullup(adc_i2c_sda);

pullup(dac_i2c_scl);
pullup(dac_i2c_sda);
```

这里只模拟开漏逻辑高。

不得声称：

> ISim `pullup` 模拟了真实 4.7kΩ RC 上升时间。

---

# 19. Stage-2 simulation entry

建议在 `project.json` 新增：

```text
stage2_top
```

例如：

```json
{
  "name": "stage2_top",
  "top": "tb_finger_piano_stage2_top",
  "sources": [
    "sim/tb_finger_piano_stage2_top.v",
    "sim/models/ads1115_model.v",
    "sim/models/mcp4725_model.v"
  ],
  "timeoutSeconds": 1500,
  "passPattern": "TB_FINGER_PIANO_STAGE2_TOP: PASS",
  "failPattern": "TB_FINGER_PIANO_STAGE2_TOP: FAIL"
}
```

实际 JSON 风格应保持与当前工程一致。

---

# 20. 第一阶段先不要切正式 top

推荐先完成：

```text
finger_piano_stage2_top.v
+
tb_finger_piano_stage2_top.v
```

然后运行单项仿真。

此时：

```json
"top": "finger_piano_top"
```

继续不动。

先证明 wrapper 正确。

---

# 21. 单项仿真门禁

必须：

```powershell
pwsh -File .\ise.ps1 sim -Project finger_piano -Test stage2_top
```

结果必须：

```text
TB_FINGER_PIANO_STAGE2_TOP: PASS
```

失败时：

> 不得开始 UCF cutover。

---

# 22. 新 UCF 重整原则

Stage-2 top TB 通过后，再修改：

```text
constraints/finger_piano.ucf
```

不要在旧 UCF 后面简单追加。

应按功能重新整理：

```text
SYSTEM CLOCK

RESET

3-BIT SENSOR INPUT

ADS1115 I2C

MCP4725 I2C

NOTE DEBUG

TIMING
```

---

# 23. 最终 UCF 内容

功能约束应至少等价于：

```ucf
# ============================================================
# System clock
# ============================================================

NET "clk" LOC = "P57";
NET "clk" IOSTANDARD = LVCMOS33;

NET "clk" TNM_NET = "clk_group";
TIMESPEC "TS_clk" = PERIOD "clk_group" 83.33 ns HIGH 50%;


# ============================================================
# Reset
# ============================================================

NET "rst_n" LOC = "P3";
NET "rst_n" IOSTANDARD = LVCMOS33;


# ============================================================
# LM393 3-bit sensor code
# ============================================================

NET "sensor_async<0>" LOC = "P28";
NET "sensor_async<0>" IOSTANDARD = LVCMOS33;

NET "sensor_async<1>" LOC = "P29";
NET "sensor_async<1>" IOSTANDARD = LVCMOS33;

NET "sensor_async<2>" LOC = "P30";
NET "sensor_async<2>" IOSTANDARD = LVCMOS33;


# ============================================================
# ADS1115 independent I2C bus
# ============================================================

NET "adc_i2c_scl" LOC = "P31";
NET "adc_i2c_scl" IOSTANDARD = LVCMOS33;

NET "adc_i2c_sda" LOC = "P32";
NET "adc_i2c_sda" IOSTANDARD = LVCMOS33;


# ============================================================
# MCP4725 independent I2C bus
# ============================================================

NET "dac_i2c_scl" LOC = "P102";
NET "dac_i2c_scl" IOSTANDARD = LVCMOS33;

NET "dac_i2c_sda" LOC = "P103";
NET "dac_i2c_sda" IOSTANDARD = LVCMOS33;


# ============================================================
# Note debug
# ============================================================

NET "note_debug<0>" LOC = "P110";
NET "note_debug<0>" IOSTANDARD = LVCMOS33;

NET "note_debug<1>" LOC = "P111";
NET "note_debug<1>" IOSTANDARD = LVCMOS33;

NET "note_debug<2>" LOC = "P113";
NET "note_debug<2>" IOSTANDARD = LVCMOS33;
```

保持当前工程 UCF 语法风格。

---

# 24. 必须删除的 legacy UCF NET

切 Stage-2 top 后，以下已经不再是 top port：

```text
key_in<0..6>
key_debug<0..6>
audio_out
```

所以它们的：

```text
LOC
IOSTANDARD
```

必须从当前活动 UCF 中删除。

否则会出现：

```text
constraint refers to nonexistent net
```

或者留下错误的历史约束。

---

# 25. 必须保留的 legacy 信息

虽然活动 UCF 删除旧 NET，但不能把历史信息彻底丢掉。

现有 legacy pin map 应保留在：

```text
projects/finger_piano/README.md
```

或 Git history。

不要为了 Stage-2 抹去 legacy baseline 记录。

---

# 26. 更新 UCF 头部注释

删除过时的：

```text
可用 I/O 范围 P1..P40
```

改为：

```text
Stage-2 physical pin assignment frozen 2026-09-16.
VCCO = 3.3V confirmed by user.
Pin legality checked against XC3S50AN-TQG144 DS557 pinout.
```

并列出最终表。

---

# 27. 切换正式 project top

只有：

```text
stage2_top simulation PASS
+
UCF complete
```

之后才能修改：

```json
"top": "finger_piano_top"
```

为：

```json
"top": "finger_piano_stage2_top"
```

并把：

```text
src/finger_piano_stage2_top.v
```

加入 `sources`。

---

# 28. `constraintsReviewed`

因为新 UCF 的全部实际接口现已：

```text
pin confirmed
Bank confirmed
VCCO confirmed 3.3V
IOSTANDARD confirmed
```

所以在 UCF 完成并人工核对无误后：

```json
"constraintsReviewed": true
```

可以继续保持 true。

不要先写约束、后补“确认”。

---

# 29. Stage-2 首次完整 verify

切 top 后执行：

```powershell
pwsh -File .\ise.ps1 verify -Project finger_piano
```

要求：

```text
Overall PASS
```

所有原：

```text
legacy
P1
P2
P3
P4
P5
P6A
```

simulation 必须继续 PASS。

加上：

```text
stage2_top
```

的新 simulation 也必须 PASS。

---

# 30. Legacy 仿真不能删除

即使正式 top 已切换为 Stage-2：

```text
note_encoder
tone_generator
top_default
top_active_low
top_filter_bypass
```

等 legacy TB 仍应保留。

目的：

> legacy baseline 继续作为回归参考。

不要因为 top cutover 就删除它们。

---

# 31. 资源变化是正常的

P6A 时：

```text
232 FF / 20 I/O
```

保持不变是因为 system core 被 trim。

P6B 切换 Stage-2 后：

```text
FF
LUT
IO
```

一定会变化。

这是正确现象。

不得把：

```text
必须仍然 232 FF / 20 I/O
```

作为验收条件。

---

# 32. Stage-2 I/O 数量预期

当前正式 top：

```text
clk               1
rst_n             1
sensor_async       3
ADC I2C            2
DAC I2C            2
note_debug         3
---------------------
total             12
```

因此 I/O 数量理论上应接近：

```text
12
```

以 XST 实际报告为准。

如果最终不是 12：

> Agent 必须解释原因。

---

# 33. 综合要求

切换以后必须：

```text
XST errors   = 0
XST warnings = 0
latches      = 0
```

任何 warning：

> 先修复，不继续 implement。

---

# 34. Implementation

完整 verify PASS 后：

```powershell
pwsh -File .\ise.ps1 build -Project finger_piano -Stage implement
```

要求：

```text
MAP PASS
PAR PASS
```

不能仅成功生成文件就视为通过。

---

# 35. Timing 验收

必须人工读取：

```text
timing.twr
```

重点确认：

```text
TS_clk = PERIOD 83.33 ns
```

满足。

要求：

```text
timing errors = 0
```

记录：

```text
worst slack
```

到 README。

不要仅引用旧 legacy slack。

---

# 36. I²C 不增加 TIMESPEC

当前 I²C 是：

```text
12 MHz synchronous state machine
→ open-drain GPIO
```

其协议节拍由 RTL clock-enable/state timing 产生。

本阶段不需要给：

```text
adc_i2c_scl
dac_i2c_scl
```

创建新的 FPGA clock domain 或 TIMESPEC。

它们不是内部时钟。

---

# 37. 不允许把 SCL 声明成时钟

禁止：

```text
NET adc_i2c_scl TNM_NET ...
NET dac_i2c_scl TNM_NET ...
```

禁止：

```text
always @(posedge adc_i2c_scl)
```

整个 FPGA 仍只有：

```text
clk = P57 = 12 MHz
```

一个系统时钟域。

---

# 38. 板级安全边界

即便：

```text
verify PASS
implement PASS
bitstream generated
```

仍然：

```text
DO NOT PROGRAM
```

本计划禁止 Agent 自动执行：

```powershell
program -Mode Jtag
program -Mode Isf
```

第一次 Stage-2 下载必须等待用户明确命令。

---

# 39. 本计划完成后的状态

只能写：

```text
P1~P5                INTEGRATED
P6A SYSTEM CORE      INTEGRATED
STAGE2 TOP           IMPLEMENTED
STAGE2 TOP SIM       PASS
UCF                   CONFIRMED
IMPLEMENTATION        PASS
TIMING                PASS

BOARD                  NOT_TESTED
FSR CALIBRATION        NOT_CALIBRATED
MCP4725 ANALOG OUTPUT  NOT_TESTED
LM386                  NOT_TESTED
SPEAKER                NOT_TESTED
```

不能写：

```text
BOARD PASS
AUDIO PASS
FSR PASS
```

---

# 40. README 更新

完成后更新：

```text
projects/finger_piano/README.md
```

新增：

```text
Stage-2 top
```

状态。

至少记录：

* 新 top 文件；
* 最终 12 个 I/O；
* 最终 LOC；
* VCCO=3.3 V；
* full verify run id；
* simulations 数量；
* synthesis FF/LUT/IO；
* implementation status；
* timing status；
* 未烧录；
* NOT_BOARD_TESTED。

---

# 41. `doc/README.md` 更新

把：

```text
P6 stage-2 system integration
```

由：

```text
P6A complete / P6B blocked
```

更新为：

```text
P6 COMPLETE
STAGE2 TOP = IMPLEMENTED / SIMULATED / IMPLEMENTED
BOARD = NOT_TESTED
```

前提是本计划所有验收通过。

---

# 42. P6 主计划更新

更新：

```text
doc/P6最终顶层迁移与系统级数字集成计划.md
```

顶部：

```text
P6A COMPLETE
P6B COMPLETE
```

同时记录：

```text
final pin assignment
verify run
implementation result
timing result
```

---

# 43. 不要修改压力校准状态

P6B 只是接入 ADS1115。

因此：

```text
pressure_calibration.md
```

仍保持：

```text
NOT_CALIBRATED
```

以下继续 TODO：

```text
released
light
normal
strong
ZERO_OFFSET
```

---

# 44. 不要增加压力→音量逻辑

即使压力链现在进入正式 top，也不要顺手增加：

```text
pressure → DDS amplitude
```

或：

```text
pressure → pitch
```

P6B 完成目标只是：

> 所有 P1～P6A 已验证数字基础设施正式进入 FPGA 顶层。

压力音乐映射属于后续独立计划。

---

# 45. 不要修改 DDS 固定幅值

继续保持：

```text
center = 2048
amplitude = 1792
8 kS/s
```

P6B 不改 DDS 算法。

---

# 46. 不要修改 ADS / DAC 参数

继续使用现有已验证配置：

```text
ADS1115:
3 channels
single-shot
OS polling
860 SPS
PGA ±4.096V

MCP4725:
Fast Write only
8 kS/s input stream
no EEPROM audio write
```

P6B 只负责物理接入。

---

# 47. 推荐提交拆分

## Commit P6B-A — Stage-2 top

新增：

```text
src/finger_piano_stage2_top.v
```

不切 project top。

不改 UCF。

---

## Commit P6B-B — Stage-2 top TB

新增：

```text
sim/tb_finger_piano_stage2_top.v
```

加入 simulation entry。

执行：

```text
stage2_top PASS
```

---

## Commit P6B-C — UCF migration

重整：

```text
constraints/finger_piano.ucf
```

使用冻结 pin map。

删除 legacy 无效 NET。

此 commit 不烧录。

---

## Commit P6B-D — Project top cutover

修改：

```text
project.json
```

设置：

```text
top = finger_piano_stage2_top
```

加入新 top source。

---

## Commit P6B-E — Full verification

执行：

```text
full verify
```

所有回归 PASS 后独立记录结果。

---

## Commit P6B-F — Implementation

执行：

```text
build -Stage implement
```

检查：

```text
XST
MAP
PAR
timing.twr
```

记录新资源基线。

---

## Commit P6B-G — Documentation closeout

更新：

```text
README.md
doc/README.md
P6 plan
```

标记：

```text
P6 COMPLETE
NOT_BOARD_TESTED
```

---

# 48. Agent 停止条件

以下任一情况发生都必须停止继续叠加：

```text
stage2_top simulation FAIL
full verify FAIL
XST warning
MAP/PAR error
timing error
unexpected unconstrained I/O
unexpected auto-assigned LOC
I/O count无法解释
legacy regression FAIL
```

必须先修复。

---

# 49. 严禁行为

Agent 本计划中不得：

```text
猜新的 LOC
修改冻结 pin map
使用 P76/P77 代替 P102/P103
添加内部 I2C PULLUP 替代外部电阻
把 I2C SCL 当作 FPGA 时钟
删除 legacy top
删除 legacy tests
修改 DDS 频率算法
修改压力算法
伪造 FSR 校准值
执行 JTAG program
执行 ISF program
声称板卡已通过
```

---

# 50. 最终验收清单

```text
[ ] finger_piano_stage2_top.v 已创建
[ ] legacy finger_piano_top.v 仍存在

[ ] clk = P57
[ ] rst_n = P3

[ ] sensor_async[0] = P28
[ ] sensor_async[1] = P29
[ ] sensor_async[2] = P30

[ ] ADC_SCL = P31
[ ] ADC_SDA = P32

[ ] DAC_SCL = P102
[ ] DAC_SDA = P103

[ ] note_debug[0] = P110
[ ] note_debug[1] = P111
[ ] note_debug[2] = P113

[ ] 所有用户I/O = LVCMOS33
[ ] VCCO = 3.3V 已记录
[ ] 未使用 P76/P77
[ ] 未使用额外 GCLK/RHCLK 作普通主功能IO

[ ] I2C仍为open-drain 0/Z
[ ] UCF未添加内部PULLUP
[ ] 两条I2C仍完全独立

[ ] stage2 top TB PASS
[ ] sensor 000~111映射正确
[ ] note_debug正确
[ ] ADC model工作
[ ] DAC model工作
[ ] 双I2C同时工作
[ ] reset行为正确

[ ] project top切换为finger_piano_stage2_top
[ ] legacy无效UCF NET已删除
[ ] 新UCF无未确认LOC
[ ] 无自动分配I/O

[ ] full verify PASS
[ ] 所有legacy测试继续PASS
[ ] P1~P6A测试继续PASS
[ ] stage2新增测试PASS

[ ] XST 0 errors
[ ] XST 0 warnings
[ ] XST 0 latches

[ ] MAP PASS
[ ] PAR PASS
[ ] timing errors = 0
[ ] 83.33ns时钟约束正确
[ ] 新FF/LUT/IO资源基线已记录

[ ] 未执行program
[ ] BOARD = NOT_TESTED
[ ] PRESSURE = NOT_CALIBRATED
[ ] ANALOG AUDIO = NOT_TESTED
```

---
