# finger_piano 文档入口

本目录是 `finger_piano` 课程设计的软件、FPGA、扩展外设与验证文档入口。

当前工程采用 **Xilinx ISE 14.7 + XC3S50AN**。已验证的 legacy baseline 仍保留现有方波电子琴路径；新增的 3-bit 传感器输入、ADS1115、MCP4725、DDS 和压力数据处理均按照独立计划分阶段开发、独立仿真，并在板级管脚与实物条件确认后再进行最终顶层集成。

> **重要：计划文档描述“准备怎样实现”，不等于相关功能已经实现或已经通过板上验证。**
>
> 实际状态必须以当前源码、`projects/finger_piano/README.md`、Git 提交记录以及
>
> ```powershell
> pwsh -File .\ise.ps1 verify -Project finger_piano
> ```
>
> 的真实结果为准。

---

## 0. 当前实施状态与事实来源优先级

### 0.1 当前实施状态

> 本表只用于快速导航。出现冲突时以源码、`projects/finger_piano/README.md` 和最新 `verify` 结果为准。
> **每完成一个阶段才更新对应一行**，不要在这里写 run ID、资源数量或几十条测试结果——那些留在工程 README 和 artifacts 里。

| Plan | 状态 | 顶层接入 | 板测 |
|---|---|---|---|
| P1 ADC/DAC drivers | SIMULATED / INTEGRATED（经 `finger_piano_system` 接入 stage-2；ADS1115 压力链当前被综合 trim） | 是 | NO |
| P2 3-bit input | SIMULATED / INTEGRATED（`sensor_async` P28/P29/P30） | 是 | NO |
| P3 DDS | SIMULATED / INTEGRATED（经 P4 进入 stage-2 顶层） | 是 | NO |
| P4 DDS → MCP4725 | SIMULATED / INTEGRATED（`dac_i2c` P102/P103） | 是 | NO |
| P5 Pressure processor | RTL-INTEGRATED / SYSTEM-SIMULATED；当前无硬件消费方，Stage-2 综合中有意 trim；`NOT_CALIBRATED` | 逻辑是 / 综合 trim | NO |
| P6 stage-2 系统集成 | **P6 COMPLETE**：STAGE2 TOP = IMPLEMENTED / SIMULATED / IMPLEMENTED（综合+实现+时序通过）；BOARD = NOT_TESTED | 是 | NO |
| P7 启动/时钟板级验证 | **SOFTWARE PREPARATION = COMPLETE**（独立诊断工程 `finger_piano_clock_test`，verify/implement/bitstream 全过）；HARDWARE TEST = WAITING USER | 独立工程 | WAITING USER |

**P1~P6 已全部完成并交叉集成**：正式 Stage-2 顶层 `finger_piano_stage2_top`
（12 个用户 I/O，引脚 2026-09-16 逐脚冻结）已通过全量 verify（Overall PASS，
33 仿真）、实现（MAP/PAR 0/0）与人工时序复核（`TS_clk = PERIOD 83.33 ns`，
0 timing errors）。当前 12 脚顶层没有压力数据消费方，ADS1115 压力链被 XST
合法 trim（已审阅告警白名单，见工程 README §12.5/§13）。**从未烧录，板卡
功能 = NOT_TESTED；FSR = NOT_CALIBRATED。**

P7 已新建独立诊断工程 `projects/finger_piano_clock_test`（P110=2 MHz、
P111=100 kHz、P113=1 kHz，clk=P57、rst_n=P3），软件侧（仿真 / 综合 /
实现 / bitstream）全部通过，停在 `READY_FOR_BOARD_TEST`，等待用户明确授权后
再做 JTAG / ISF 写入与实测。

### 0.2 事实来源优先级（冲突时以此为准）

```
1. 当前源码 / project.json / UCF
        ↓
2. projects/finger_piano/README.md 中有实测或工具证据的当前状态
        ↓
3. doc/ISE工具链最终状态.md
        ↓
4. 本文件（doc/README.md）
        ↓
5. 当前开发计划文档（P1~P5）
        ↓
6. doc/archive/*（仅历史追溯，不得作为当前事实来源）
```

**计划文档可以比当前源码更“先进”，因为它描述的是待实现目标。不得根据计划内容声称功能已经存在或已经通过验证。**

---

## 1. 从哪里开始

如果第一次进入本工程，建议依次阅读：

1. [ISE 工具链最终状态](./ISE工具链最终状态.md)  
   了解当前冻结的构建、仿真、JTAG、ISF 和安全边界。

2. [finger_piano 工程 README](../projects/finger_piano/README.md)  
   了解当前 RTL、板卡、历史验证结果和仍未完成的实物测试。

3. 本页下面的“开发计划执行顺序”  
   根据依赖关系选择下一项开发任务。

日常修改 RTL 后的主验收入口始终是：

```powershell
pwsh -File .\ise.ps1 verify -Project finger_piano
```

除非明确进入人工板级验证阶段，否则开发 Agent 不得执行 program。

## 2. 当前总体架构

最终目标系统分为三条逻辑上相互独立的数据链。

### 2.1 数字音符选择链

真实硬件最终采用三个 LM393 比较器输出组成 3-bit 编码：

FSR ×3
  ↓
模拟调理
  ↓
LM393 ×3
  ↓
sensor_code[2:0]
  ↓
同步 + whole-vector 稳定滤波
  ↓
000 = 静音
001~111 = C4~B4
  ↓
note_code[2:0]

当前仓库仍保留已经验证的：

key_in[6:0]
  ↓
7-key legacy priority encoder
  ↓
note_code

该路径是 legacy baseline，不是最终三传感器硬件模型。

### 2.2 模拟压力采集链

三个压力传感器的模拟量经 ADS1115 独立采集：

FSR ×3
  ↓
TL084 / RC
  ↓
ADS1115
  ↓
CH0 / CH1 / CH2 raw ADC code
  ↓
pressure processing
  ↓
三路相对压力数据

这一链负责“按压力度”，不负责决定当前是哪一个音符。

### 2.3 DDS 数字音频链

音符编码进入 DDS：

note_code
  ↓
24-bit DDS phase accumulator
  ↓
sine LUT
  ↓
12-bit / 8 kS/s sine samples
  ↓
MCP4725
  ↓
模拟重构滤波
  ↓
LM386
  ↓
Speaker

当前新增 DDS / MCP4725 设计不得破坏已经工作的：

tone_generator → audio_out

方波基线。

## 3. 开发计划总览

| 顺序 | 计划 | 解决的问题 | 主要依赖 | 本阶段是否接顶层 |
|---|---|---|---|---|
| P1 | [ADS1115 与 MCP4725 可选外设开发计划](./ADS1115与MCP4725可选外设开发计划.md) | I²C master、ADC driver、DAC driver | ISE 工具链 | 否 |
| P2 | [3-bit 传感器编码输入基础设施开发计划](./3bit传感器编码输入基础设施开发计划.md) | 三个 LM393 编码、同步、原子码字滤波 | 现有同步基础设施 | 否 |
| P3 | [DDS 正弦音频发生器开发计划](./DDS正弦音频发生器开发计划.md) | 8 kS/s、24-bit DDS、12-bit 正弦样点 | P1 的统一配置 | 否 |
| P4 | [DDS 到 MCP4725 数字音频链路集成计划](./DDS到MCP4725数字音频链路集成计划.md) | DDS 与 DAC controller 端到端吞吐 | P1 + P3 | 否 |
| P5 | [ADS1115 压力数据处理与标定基础设施开发计划](./ADS1115压力数据处理与标定基础设施开发计划.md) | ADC raw → 干净的三路压力数据 | P1 | 否 |
| P6 | [P6 最终顶层迁移与系统级数字集成计划](./P6最终顶层迁移与系统级数字集成计划.md) | stage-2 system core 纯数字集成 + 系统级仿真 + final top/UCF 迁移 | P1+P2+P3+P4+P5 | 是（P6A+P6B 全部完成） |
| P7 | [P7 FPGA 启动与时钟分频板级验证计划](./P7FPGA启动与时钟分频板级验证.md) | 独立诊断工程的 FPGA 启动 / 12 MHz 时钟 / 分频 / ISF 冷启动板级验证 | P6 | 独立工程 `finger_piano_clock_test`（软件侧完成） |

这些计划的共同原则是：

先做独立 RTL 和可重复仿真，再做顶层和实物集成。

P6 已全部完成。P6A 交付纯数字集成层 `finger_piano_system` 与 7 个系统级
仿真；P6B 交付正式物理顶层 `finger_piano_stage2_top`（wrapper only）、冻结
12 脚 UCF、stage2 top TB、全量 verify（Overall PASS，33 仿真）与实现/时序
（MAP/PAR 0/0、`Timing Score: 0`、`TS_clk = 83.33 ns` 0 timing errors）。最终
引脚由用户在 2026-09-16 逐脚确认（clk=P57、rst_n=P3、
sensor_async[0..2]=P28/P29/P30、adc_i2c=P31/P32、dac_i2c=P102/P103、
note_debug=P110/P111/P113，全部 LVCMOS33，VCCO=3.3 V）。**从未烧录，板卡
功能 = NOT_TESTED**；当前 12 脚顶层没有压力数据消费方，P5 压力链被 XST
有意 trim（已审阅告警白名单，见工程 README §12.5/§13）。

## 4. 推荐执行顺序

推荐 Agent 严格按照下面的依赖关系推进：

                    ┌─────────────────────┐
                    │ P1 I²C + ADC / DAC │
                    └──────┬───────┬──────┘
                           │       │
                           │       └──────────────┐
                           │                      │
                           ▼                      ▼
                  P5 Pressure             P3 DDS generator
                    processing                    │
                                                 │
                                                 ▼
                                      P4 DDS → MCP4725

同时：

P2 3-bit sensor input

与上述两条数据链基本独立，可以在 P1 之后或与 P3 前后独立完成。

推荐实际顺序：

P1  ADS1115 / MCP4725 driver
 ↓
完整 verify
 ↓
P2  3-bit sensor input
 ↓
完整 verify
 ↓
P3  DDS sine generator
 ↓
完整 verify
 ↓
P4  DDS → MCP4725 pipeline
 ↓
完整 verify
 ↓
P5  ADS1115 pressure processing
 ↓
完整 verify
 ↓
P6A stage-2 system core（纯数字集成,不动 legacy top/UCF）
 ↓
完整 verify
 ↓
P6B final top / UCF 迁移（引脚已冻结;见工程 README §13 第十四轮）

任何阶段出现回归失败：

先修复当前阶段，不得带着 FAIL 继续向后叠加功能。

## 5. P1 — ADS1115 / MCP4725 可选外设

入口：

[ADS1115 与 MCP4725 可选外设开发计划](./ADS1115与MCP4725可选外设开发计划.md)

主要目标：

通用 I²C master
       ├── ADS1115 controller
       └── MCP4725 controller

关键设计冻结：

ADC 与 DAC 使用两条独立 I²C 物理总线；
可复用同一份 i2c_master.v，但必须为两个独立实例；
ADS1115：
AIN0 / AIN1 / AIN2；
single-shot；
860 SPS；
PGA ±4.096 V；
原始 16-bit two's-complement 数据；
MCP4725：
12 bit；
Fast Write only；
禁止 DDS 写 EEPROM；
pending buffer + overrun；
默认 I²C 目标约 333 kHz；
两个外设默认关闭；
不增加未确认的顶层 GPIO；
不修改 UCF；
不执行 program。

协议实现的第一事实来源：

ADS1115 数据手册
MCP4725 数据手册

任何寄存器、地址、位域或 I²C 时序问题，均以这两份仓库内手册为准。

## 6. P2 — 3-bit 传感器编码输入

入口：

[3-bit 传感器编码输入基础设施开发计划](./3bit传感器编码输入基础设施开发计划.md)

真实硬件只有三个压力传感器和三个比较器数字输出。

项目编码冻结为：

| 3-bit code | note |
|---|---|
| 000 | 静音 |
| 001 | C4 |
| 010 | D4 |
| 011 | E4 |
| 100 | F4 |
| 101 | G4 |
| 110 | A4 |
| 111 | B4 |

关键设计不是简单的：

3 × 独立 bit debounce

而是：

3-bit async input
      ↓
2FF synchronization
      ↓
whole-vector atomic stable filter
      ↓
3-bit stable code

三个 bit 必须作为一个完整码字达到稳定条件后一次性提交，避免：

001 → 011 → 111

转换过程中短暂播放错误音符。

本阶段只做 standalone infrastructure，不替换当前 7-key 顶层。

## 7. P3 — DDS 正弦发生器

入口：

[DDS 正弦音频发生器开发计划](./DDS正弦音频发生器开发计划.md)

目标：

note_code
   ↓
24-bit phase accumulator
   ↓
sine LUT
   ↓
12-bit unsigned samples
   ↓
8 kS/s valid

当前冻结值：

| 项 | 值 |
|---|---|
| Sample rate | 8 kS/s |
| Phase accumulator | 24 bit |
| Phase address | 8 bit |
| DAC width | 12 bit |
| Center | 2048 / 12'h800 |
| Amplitude | 1792 |
| Output range | 256～3840 |
| Mute code | 2048 |

所有 DDS 时序仍运行在系统 clk：

12 MHz clock
   ↓
sample clock-enable

禁止产生：

clk_8k

作为第二时钟域。

DDS 本阶段只生成数字样点，不声称已经产生真实模拟正弦波。

## 8. P4 — DDS → MCP4725 数字链路

入口：

[DDS 到 MCP4725 数字音频链路集成计划](./DDS到MCP4725数字音频链路集成计划.md)

该计划不是重新实现 DDS 或 MCP4725，而是验证：

DDS
 ↓
12-bit / 8 kS/s
 ↓
MCP4725 controller
 ↓
I²C
 ↓
MCP4725 behavioral model

正常路径的核心验收目标：

Generated : N
Accepted  : N
Written   : N
Mismatch  : 0
Overrun   : 0
I2C error : 0

计划要求真实 12 MHz 参数下进行长时间吞吐测试。

DDS 的 8 kS/s 时间轴不能因为：

DAC busy

而暂停，否则会改变音频时间轴和实际频率。

本计划完成只能说明：

端到端数字音频数据链 PASS

不能声称：

MCP4725 实际模拟输出已经验证；
RC 重构滤波已经验证；
LM386 输入已经验证；
扬声器已经验证。

这些结论必须来自之后的实物测试。

## 9. P5 — ADS1115 压力数据处理

入口：

[ADS1115 压力数据处理与标定基础设施开发计划](./ADS1115压力数据处理与标定基础设施开发计划.md)

目标：

ADS1115 raw
     ↓
三通道轮询扫描帧
     ↓
negative clamp
     ↓
zero-offset correction
     ↓
pressure_ch0
pressure_ch1
pressure_ch2

特别注意：

ADS1115 的 AIN0 / AIN1 / AIN2 是通过内部 MUX 顺序转换的，因此：

三个通道组成的是“一轮扫描帧”，不是严格意义上的三个通道同时采样。

当前没有真实 FSR 校准数据，所以禁止 Agent 猜测：

released offset；
light / normal / strong threshold；
full-scale；
牛顿压力；
gain normalization。

当前校准状态应保持：

NOT_CALIBRATED

默认 zero offset 为 0，只用于建立数据处理基础设施。

## 10. 全工程共同不可违反的约束

以下规则优先级高于任意单一计划中的局部实现便利。

### 10.1 Legacy baseline 必须保持

在真正进行最终集成前：

finger_piano_top
tone_generator
audio_out
现有 UCF

不得因为扩展功能而随意修改。

### 10.2 不猜板级管脚

任何尚未由用户确认的：

LM393 input pin
ADS1115 SDA/SCL
MCP4725 SDA/SCL

均不得自行写 LOC。

不得依赖 MAP 自动分配新增外设 I/O。

### 10.3 新外设默认不启用

ADS1115、MCP4725、DDS 等新增能力即使已经：

IMPLEMENTED
SIMULATED

也不能因此自动成为当前板级设计的一部分。

真正启用通常还需要：

top-level port
+
RTL instance
+
verified UCF LOC
+
board wiring
### 10.4 只有一个系统时钟域

全工程主时钟：

clk

派生节拍必须使用：

clock enable

不得把：

audio_out
sample_tick
I2C SCL

用作新逻辑时钟。

### 10.5 ISE / Verilog 兼容性

可综合 RTL 以：

Verilog-2001

为目标。

不要无必要使用：

logic
always_ff
always_comb
SystemVerilog-only constructs

项目启用了 synthesis warning 阻断策略，因此最终必须：

XST errors             = 0
unexpected XST warnings = 0
latches                = 0

唯一例外是 `project.json` 的 `verification.synthesisWarningAllowlist`：逐条
审阅过的 trim warning（id + 正则 + 期望计数）算 allowed。任何未命中条目、
新路径/类别、或计数漂移仍判 FAIL；不得用 `XIL_XST_HIDEMESSAGES`、全局静音、
`KEEP`/`DONT_TOUCH` 或假消费者绕过，也不得关闭 `failOnSynthesisWarnings`。
`finger_piano` 当前有一份 12 脚 Stage-2 专用的白名单（166 条，见工程 README
§12.5/§13）；诊断/新工程一律要求原始 0 warnings，不得复用该白名单。

### 10.6 仿真 PASS 不能只看退出码

每个 testbench 必须产生明确：

TB_xxx: PASS

或：

TB_xxx: FAIL

工程工具按 passPattern / failPattern 判定。

退出码 0 本身不代表功能 PASS。

### 10.7 每阶段必须回归

完成每个计划或重要 commit 后：

pwsh -File .\ise.ps1 verify -Project finger_piano

必须重新验证完整工程。

不得只运行新增 TB 后就声称工程通过。

### 10.8 开发 Agent 不执行板卡写入

正常无人值守开发阶段：

禁止 program -Mode Jtag
禁止 program -Mode Isf

构建和仿真不需要向 FPGA 写入任何内容。

烧录由用户在明确需要时单独执行。

## 11. 状态术语

文档与 README 应尽量使用下面的状态，不混淆软件验证和实物验证。

| 状态 | 含义 |
|---|---|
| PLANNED | 只有计划，没有实现 |
| IMPLEMENTED | RTL/代码已实现 |
| SIMULATED | 对应自动仿真已通过 |
| INTEGRATED | 已接入系统顶层 |
| IMPLEMENTED / STANDALONE | 已实现，但尚未接顶层 |
| NOT_INTEGRATED | 尚未进入最终数据链或顶层 |
| NOT_CALIBRATED | 真实硬件校准尚未完成 |
| NOT_BOARD_TESTED | 没有实物验证证据 |
| PASS | 对明确指定的测试对象和测试范围通过 |
| NOT_TESTED | 尚未测试，不等于失败 |

尤其禁止把：

simulation PASS

写成：

board PASS

也禁止把：

programmingVerified = VERIFIED

解释成：

user design functional = PASS
## 12. 板级验证阻塞项（顶层集成已完成）

P6B 已于 2026-09-16 完成正式 Stage-2 顶层迁移：引脚由用户逐脚冻结，
`projects/finger_piano/constraints/finger_piano.ucf` 就是最终活动约束。
本节只保留**仍需实物信息解除**的板级 blocker（12.4/12.5）；旧的
「引脚池 / 候选分配」提案已被最终冻结表取代，不再作为依据。

### 12.1 Stage-2 最终引脚冻结（用户 2026-09-16 确认，已完成）

| 信号 | LOC | Bank | VCCO | IOSTANDARD | 外部 |
|---|---|---|---|---|---|
| `clk` | P57 | 2 | 3.3 V | LVCMOS33 | 12 MHz 有源晶振 |
| `rst_n` | P3 | 3 | 3.3 V | LVCMOS33 | 低有效，外部上拉/RC |
| `sensor_async[0]` | P28 | 3 | 3.3 V | LVCMOS33 | LM393 CH0（权重 1） |
| `sensor_async[1]` | P29 | 3 | 3.3 V | LVCMOS33 | LM393 CH1（权重 2） |
| `sensor_async[2]` | P30 | 3 | 3.3 V | LVCMOS33 | LM393 CH2（权重 4） |
| `adc_i2c_scl` | P31 | 3 | 3.3 V | LVCMOS33 | ADS1115 SCL |
| `adc_i2c_sda` | P32 | 3 | 3.3 V | LVCMOS33 | ADS1115 SDA |
| `dac_i2c_scl` | P102 | 1 | 3.3 V | LVCMOS33 | MCP4725 SCL |
| `dac_i2c_sda` | P103 | 1 | 3.3 V | LVCMOS33 | MCP4725 SDA |
| `note_debug[0]` | P110 | 0 | 3.3 V | LVCMOS33 | 当前音符编码 |
| `note_debug[1]` | P111 | 0 | 3.3 V | LVCMOS33 | 当前音符编码 |
| `note_debug[2]` | P113 | 0 | 3.3 V | LVCMOS33 | 当前音符编码 |

共 12 个用户 I/O，全部 LVCMOS33、VCCO=3.3 V。实现报告 `routed_pad.txt`
实测 12 脚全部 `LOCATED`、无自动分配 I/O。**不使用 P76/P77**（配置期 DUAL），
也不使用额外 GCLK/RHCLK 作普通功能 I/O。旧提案（DAC 用 P76/P77、note_debug
用 P78/P79/P90）作废，不再作为候选。

（历史：2026-09-15 用户曾确认一份 38 脚可用池，仅表示这些脚"可以用"，且
不含 P8/P11/P16/P18/P24。该池与差集信息保留在 Git history；最终功能分配以
上表为准。）

### 12.2 三个 LM393 GPIO（已冻结）

| 信号 | LOC | 说明 |
|---|---|---|
| `sensor_async[0]` | P28 | LM393 CH0，权重 1 |
| `sensor_async[1]` | P29 | LM393 CH1，权重 2 |
| `sensor_async[2]` | P30 | LM393 CH2，权重 4 |

输入经 `sensor_code_frontend`（极性归一化 → 2FF 同步 → 原子码字滤波 → 解码）
得到 `sensor_code_stable[2:0]` 与 `note_code[2:0]`；**位序不得交换**。

### 12.3 两套 I²C GPIO（已冻结）

| 信号 | LOC | 总线 |
|---|---|---|
| `adc_i2c_scl` / `adc_i2c_sda` | P31 / P32 | ADS1115 独立总线 1 |
| `dac_i2c_scl` / `dac_i2c_sda` | P102 / P103 | MCP4725 独立总线 2 |

两条总线物理独立，禁止共享 SDA/SCL、arbiter、bus mux；开漏 0/Z，
外部 4.7 kΩ 上拉到 3.3 V；UCF 不加 `PULLUP`。

### 12.4 FSR 实物标定

需要实际记录三个传感器：

Released
Light
Normal
Strong

对应的 ADS1115 raw code。

在此之前：

ZERO_OFFSET
pressure threshold
pressure normalization

均不得声称完成。

### 12.5 DAC模拟输出与LM386

数字链通过后还需要实际验证：

MCP4725 VOUT
 ↓
RC reconstruction filter
 ↓
AC coupling / volume
 ↓
LM386
 ↓
speaker

需要示波器或实际音频测试。

## 13. 数据手册

本仓库保存的外设手册属于协议实现依据：

ADS1115 数据手册
MCP4725 数据手册

涉及下列内容时必须优先查对应手册：

I2C timing
slave address
register layout
ADS1115 Config bits
ADS1115 conversion format
MCP4725 Fast Write
MCP4725 EEPROM command
electrical limits

不得因为网上示例代码写法不同而覆盖本仓库手册结论。

## 14. 工具链文档

当前正式维护文档：

ISE 工具链最终状态（Toolchain Freeze v1）

它定义：

doctor
new
check
build
fetch
sim
verify
report
probe
probe-diag
program -Mode Jtag
program -Mode Isf
board-check

以及工具链的边界、安全模型和当前已验证结论。

工具链已经冻结。

新增课程功能时：

优先使用现有工具，而不是继续给工具链增加命令或烧录模式。

## 15. 历史文档

历史第一阶段计划已移动到：

archive/手指钢琴ISE工程实施计划.md

该文件用于保留开发历史，不再作为当前事实来源。

当前烧录、时钟、工具链与板卡状态应优先查看：

ISE工具链最终状态.md
projects/finger_piano/README.md
当前源码与 project.json
最新 verify / build / program artifacts

不要从 archive 中恢复已经被后续实测取代的旧结论。

## 16. Agent 执行规则

如果由自动 Agent 按这些计划连续开发，遵循：

读计划
 ↓
确认依赖已满足
 ↓
实现最小阶段
 ↓
运行单项 simulation
 ↓
PASS
 ↓
提交独立 commit
 ↓
继续下一小阶段
 ↓
计划完成
 ↓
完整 verify

若任何一步：

FAIL

则：

停止叠加新功能
 ↓
定位并修复
 ↓
重新验证

不得使用以下方式制造“表面进度”：

禁用失败test
放宽PASS条件
删掉旧回归
忽略XST warning
绕过UCF门禁
伪造板级结果
猜测未确认参数
## 17. 文档维护规则

实现计划后，应同步更新：

projects/finger_piano/README.md

记录：

已实现哪些模块；
哪些 TB PASS；
哪些模块仍 standalone；
哪些功能已经进入顶层；
哪些真实管脚已经确认；
哪些硬件测试仍 NOT_TESTED；
实际 verify run 结果。

本文件 doc/README.md 只负责：

导航、架构、依赖关系和全局开发边界。

不要把每一次具体 run ID、资源数量和临时 debug 过程长期堆积在这里。

## 18. 最终目标

当前所有计划最终希望逐步从：

legacy 7-key digital piano
        +
square-wave audio

演进到：

                  ┌── LM393 ×3 ──→ 3-bit note code ────────────┐
FSR ×3 ── analog ─┤                                              │
                  └── ADS1115 ──→ pressure data                  │
                                                                 ↓
                                                           note / control
                                                                 │
                                                                 ↓
                                                               DDS
                                                                 ↓
                                                             MCP4725
                                                                 ↓
                                                         reconstruction LPF
                                                                 ↓
                                                              LM386
                                                                 ↓
                                                              Speaker

但这个最终架构必须通过：

独立模块验证
→ 数字链集成验证
→ 顶层集成
→ 管脚确认
→ 板上测试
→ 模拟测量

逐层取得证据。

任何前一层的 PASS，都不能替代后一层的验证。