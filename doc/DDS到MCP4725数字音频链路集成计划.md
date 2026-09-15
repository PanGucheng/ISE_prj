# finger_piano DDS → MCP4725 数字音频链路集成计划

> **Status**: PLANNED（本计划尚无任何 RTL 落地）
> **Scope**: DDS → MCP4725 数字链集成 RTL + ISim（含行为模型与 0 drop / 0 overrun 吞吐测试）
> **Depends on**: P1 + P3
> **Top integration**: NO
> **UCF changes**: NO
> **Hardware programming**: FORBIDDEN
> **Acceptance**: full `verify`（`.\ise.ps1 verify -Project finger_piano`）

## 0. 最高优先级约束

本阶段只验证 DDS → MCP4725 controller → I²C → MCP4725行为模型 的完整数字音频链路，不进行板级启用。finger_piano_top、现有 tone_generator → audio_out 方波路径、UCF 和烧录流程必须保持不变。不得新增未约束顶层端口，不得执行 program。DDS保持固定8 kS/s时间轴，禁止因MCP4725 busy而暂停、拉伸或重定时DDS。正常配置必须证明所有DDS样点均被MCP4725 controller接受并形成对应Fast Write，达到0 drop / 0 overrun。

## 1. 前置依赖

本计划不是重新实现 DDS 或 MCP4725 driver。

实施前必须确认前两份计划已经提供并独立通过：

dds_sine_generator.v
sine_lut_12bit.v
tb_dds_sine_generator.v

i2c_master.v
mcp4725_ctrl.v
mcp4725_model.v
tb_mcp4725_ctrl.v

要求：

DDS standalone PASS
MCP4725 standalone PASS
完整 verify PASS

如果其中任何一个还没有完成：

先完成对应计划，不得在本计划里复制、临时重写或旁路它。

## 2. 本阶段目标

建立独立音频 pipeline：

note_code[2:0]
      ↓
dds_sine_generator
      │
      ├── dac_code[11:0]
      └── dac_code_valid @ 8 kS/s
               ↓
        mcp4725_ctrl
               ↓
       dac_i2c_scl/sda
               ↓
       mcp4725_model
               ↓
      captured DAC code

通过端到端仿真证明：

$$ \boxed{\text{DDS产生的每一个样点，都正确到达MCP4725}} $$

正常路径必须满足：

$$ \boxed{0\ drop,\ 0\ overrun,\ 0\ protocol\ error} $$
## 3. 本阶段冻结参数
参数	值
系统时钟	12 MHz
DDS采样率	8 kS/s
DDS样点周期	125 µs
系统时钟/样点	1500 clk
DAC位宽	12 bit
静音码	12'h800
MCP4725模式	Fast Write only
DAC I²C	独立总线
I²C默认目标	约333 kHz
EEPROM	禁止写入
DDS下游策略	固定时间轴，不等待ready

MCP4725 Fast Write 使用地址字节加两个数据字节，正常DDS期间只更新 DAC Register，不应写 EEPROM。MCP4725 数据手册把 Fast Write 与 EEPROM 写入明确区分；本项目继续只使用 Fast Write。

## 4. 为什么这一层必须单独验证

DDS standalone PASS 只能证明：

数字正弦产生正确

MCP4725 controller standalone PASS 只能证明：

给定dac_code时I²C格式正确

两者并不能自动证明：

8kHz DDS
   +
约333kHz I²C
   +
pending buffer

组合后不会：

丢样；
overrun；
重复发送；
发送旧样点；
顺序错乱；
note切换时多发/少发；
mute时发送错误值；
I²C busy导致DDS时间轴变化。

本计划就是专门验证这些接口边界。

## 5. 新增集成模块

建议新增：

projects/finger_piano/src/audio/
    dds_mcp4725_pipeline.v

这是一个可综合的独立组合层/集成层。

本阶段不实例化进：

finger_piano_top.v
## 6. 推荐接口
module dds_mcp4725_pipeline #(
    parameter integer SYS_CLK_HZ = `SYS_CLK_HZ,
    parameter integer SAMPLE_RATE_HZ = `CFG_DAC_SAMPLE_RATE,
    parameter integer DAC_I2C_HZ = `CFG_DAC_I2C_SPEED,
    parameter [6:0] MCP4725_ADDR = `CFG_MCP4725_ADDR,
    parameter integer ENABLE = 1
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [2:0] note_code,

    inout  wire       dac_i2c_scl,
    inout  wire       dac_i2c_sda,

    output wire       dac_busy,
    output wire       dac_error,
    output wire       dac_overrun
);

可以额外暴露调试信号，例如：

dds_code_debug[11:0]
dds_valid_debug
dac_ready_debug

但只用于仿真/后续调试。

不要增加对基础钢琴功能不必要的控制输入。

## 7. 模块内部只能直接连接已有模块

结构：

dds_sine_generator
    │
    ├─ dac_code ─────────────┐
    │                        │
    └─ dac_code_valid ───────┤
                             ↓
                     mcp4725_ctrl
                             │
                             ↓
                        SDA / SCL

禁止在 pipeline 内：

再生成第二套 DDS；
再生成第二个 sample counter；
对 dac_code 做重采样；
加 FIFO；
加音量乘法器；
修改正弦数据；
改变 note_code 含义。

pipeline 只负责正确连接和状态汇总。

## 8. DDS不得等待DAC

这一条冻结。

DDS始终：

每125us
    ↓
产生一个dac_code_valid

不允许：

if (dac_ready)
    DDS才前进

因为这会使：

$$ T_s $$

随I²C状态变化。

音频采样时间轴会变成：

125us
125us
250us
125us
...

从而产生音高/相位调制。

因此：

DDS = producer with fixed cadence
DAC = 必须跟得上producer

而不是：

DAC busy → 暂停DDS
## 9. ready 的用途

虽然 DDS不能被ready阻塞，但 pipeline 必须观察：

dac_code_valid && !dac_code_ready

如果发生：

dac_overrun = 1

这代表：

当前MCP4725链路不具备8 kS/s实时能力。

正常默认配置下：

$$ \boxed{这个条件永远不能出现} $$
## 10. 理论吞吐预算

DDS样点间隔：

$$ T_s=\frac1{8000}=125\mu s $$

MCP4725 Fast Write主要传输：

Address + ACK
Data1   + ACK
Data2   + ACK

即约：

$$ 27 $$

个I²C位时间，另加 START / STOP / bus-free 状态。

约333 kHz时单bit约：

$$ 3\mu s $$

仅27 bit约：

$$ 81\mu s $$

因此理论上125 µs内有余量。

但：

不能只靠理论判断PASS。

必须由12 MHz真实参数的ISim端到端吞吐测试证明。

## 11. Pipeline不增加额外buffer

mcp4725_ctrl 已经按照第一计划具有：

1-entry pending buffer
+
dac_overrun

pipeline：

$$ \boxed{\text{不得再加第二层FIFO}} $$

否则可能掩盖：

MCP4725本身实际上跟不上实时采样率

的问题。

如果默认参数无法0 overrun：

应修I²C实现/时序或重新评估采样率，而不是靠堆FIFO隐藏问题。

## 12. 新增行为模型能力

现有：

mcp4725_model.v

如果当前只负责 ACK，可以在不模拟模拟电压的前提下扩展：

captured_code[11:0]
write_count
last_write_code
fast_write_seen
eeprom_write_seen

每收到合法 Fast Write：

write_count++
captured_code = 新DAC码

方便系统级TB验证。

模型不需要产生真实模拟电压。

## 13. 强制验证“发送值 == DDS值”

testbench不能只检查：

write_count == sample_count

还必须验证：

每一个发出的MCP4725 code与对应DDS sample完全一致。

推荐 TB 建立简单 scoreboard：

DDS valid
   ↓
push expected sample

MCP4725 model captures write
   ↓
pop expected sample
   ↓
compare

必须：

expected == actual

逐样点比较。

这样可以发现：

样点错位；
重复旧值；
丢一个样点后整体错位；
byte拆分错误。
## 14. Scoreboard深度

正常状态理论上只需要极小深度。

TB可以使用 testbench-only memory：

reg [11:0] expected_samples [0:4095];

这不综合，因此不受FPGA资源限制。

但 RTL pipeline 本身：

不允许因为TB方便而增加FIFO。

## 15. 必测的基本序列

至少运行：

mute
↓
C4
↓
A4
↓
B4
↓
mute

检查：

mute  → 全部12'h800
C4    → 正弦码流
A4    → 新频率正弦码流
B4    → 新频率正弦码流
mute  → 回到12'h800

每一阶段：

sample_count == write_count
## 16. 七音都必须进入Pipeline

DDS standalone已经验证七音频率。

本计划无需每个音都长时间重新测频，但必须至少让：

1 2 3 4 5 6 7

全部经过一次真实：

DDS → MCP4725 Fast Write

序列。

建议每个音至少：

128 samples

端到端发送。

这样可以确认：

note_code任意值

都不会触发pipeline边界bug。

## 17. 真实吞吐压力测试

必须新增一个：

12 MHz
333 kHz nominal I²C
8 kS/s DDS

的真实配置测试。

至少连续：

$$ 1000 $$

个样点。

我建议直接：

$$ 4096 $$

个样点。

4096样点对应：

$$ 4096/8000=0.512s $$

模拟音频时间。

系统时钟周期总数：

$$ 4096\times1500 = 6,144,000 $$

对于夜间ISim是完全合理的。

## 18. 吞吐PASS条件

4096样点结束后必须：

dds_samples_generated = 4096
samples_accepted      = 4096
mcp_writes_completed  = 4096

dac_overrun = 0
dac_error   = 0

并且：

scoreboard_errors = 0

即：

$$ \boxed{4096/4096/4096} $$
## 19. 事务延迟测量

TB建议记录每个：

dac_code_valid

到：

对应MCP4725 write完成

的延迟。

统计：

min_latency
max_latency

验收核心要求不是某个武断微秒数，而是：

$$ max\ latency < sample\ period $$

即：

$$ \boxed{max\ latency <125\mu s} $$

或者更准确地说：

下一次 DDS valid 到来前 controller 必须已经具备接受新样点的能力。

## 20. ready时序检查

每一次：

dds_valid == 1

TB都检查：

dac_ready == 1

默认配置出现一次：

valid && !ready

就判：

FAIL

即使 controller 后来恢复也不能算正常吞吐PASS。

## 21. 样点顺序验证

输入：

S0
S1
S2
S3
...

MCP4725必须收到：

S0
S1
S2
S3
...

禁止：

S0
S2
S3

也禁止：

S0
S1
S1
S2

所以 scoreboard比较必须严格保持序号。

## 22. 音符切换边界

DDS计划规定：

音符改变时相位重启，新音符从DAC中点开始，但8kHz sample cadence不重启。

因此 pipeline TB必须验证：

例如：

C4 sample
C4 sample
note ← A4
next scheduled sample = 12'h800
之后进入A4正弦

不能：

note变化
→ 立即额外发送一个I2C写

也不能漏掉原定的下一个sample。

## 23. 静音行为

DDS静音：

note_code = 0

仍产生：

8k valid
12'h800

所以本阶段 MCP4725 也继续接收：

12'h800

不要在 pipeline 中做：

if mute
    停止I2C

优化。

理由是第一阶段先保持：

固定采样时间轴与最简单数据链。

以后若为了降低I²C流量做“静音只写一次”，必须另开计划，并重新验证恢复时相位/时序。

## 24. Reset行为

rst_n_sync=0 时：

DDS:
    phase = 0
    code  = 800
    valid = 0

MCP4725 ctrl:
    idle
    SDA/SCL release
    overrun = 0

复位释放以后：

第一个 sample 按8k节拍出现；
第一个note有效样点行为符合DDS定义；
总线不能产生半截事务。
## 25. Mid-transaction reset

必须专门刺激：

I2C正在发送
↓
rst_n_sync拉低

要求：

SDA release
SCL release
busy = 0
pending清除

复位后重新开始：

完整的新Fast Write

禁止：

延续旧事务剩余字节。

## 26. 错误注入：Address NACK

行为模型增加一次：

address NACK

检查：

mcp4725_ctrl
→ abort
→ STOP/release
→ dac_error
→ error_code = ADDR_NACK

同时 DDS：

8k cadence继续

不能因为DAC错误而停止系统时钟或卡DDS。

## 27. 错误后的策略

本阶段不实现自动重传。

因为实时音频中过时样点没有必要在数百微秒后补发。

冻结策略：

发生NACK
→ 当前样点失败
→ error置位
→ controller恢复idle
→ 后续新样点仍可处理

即：

不重传旧音频样点。

TB要证明：

错误不会造成永久busy
## 28. 错误测试与正常吞吐测试必须分开

不能在：

0 drop / 0 overrun

正常测试中故意插NACK后仍要求：

write_count == sample_count

正常路径：

无错误
→ 0 drop

错误注入路径：

有意NACK
→ 当前样点允许失败
→ 但必须恢复

两者分别判定。

## 29. Overrun故障测试

还必须人为制造：

producer > DAC throughput

例如 testbench 不使用真实DDS，而直接高速刺激 controller，或者参数化 pipeline test source。

目的是证明：

dac_overrun

真的有效。

要求：

valid && !ready
→ overrun = 1

且：

pending中的旧样点不能被新样点覆盖。

这项是故障测试，不是正常8kHz路径。

## 30. 禁止 EEPROM 命令的端到端检查

行为模型或总线monitor必须确认整个pipeline运行期间：

EEPROM write count = 0

必须只有：

Fast Write

如果任何事务表现为：

DAC Register + EEPROM

立即 FAIL。

MCP4725 EEPROM 写周期远慢于实时音频路径，因此 DDS 路径绝不允许使用EEPROM写。

## 31. 总线地址检查

所有写事务必须：

7-bit address = CFG_MCP4725_ADDR

默认：

7'h60

但 testbench还应有一次参数覆盖，例如：

7'h61

证明：

地址不是 controller 内散落的硬编码0x60。

## 32. Pipeline ENABLE

建议 pipeline 自身提供：

ENABLE

默认：

0

用于 future integration。

ENABLE=0 时：

DDS不产生valid
MCP controller不启动
SDA/SCL释放
dac_busy=0
dac_overrun=0

但要注意：

pipeline宏仍不是系统级“启用DAC”的开关，因为当前pipeline尚未进入顶层。

## 33. 配置来源

继续复用：

finger_piano_cfg.vh

其中：

CFG_ENABLE_DDS
CFG_DAC_SAMPLE_RATE
CFG_DAC_I2C_SPEED
CFG_MCP4725_ADDR

不得重新建立：

pipeline_sample_rate
pipeline_dac_addr

第二套真值源。

模块参数可以覆盖宏以支持TB。

## 34. I²C timing仍由MCP controller/master负责

pipeline不计算：

LOW_CYCLES
HIGH_CYCLES
tBUF

这些属于：

mcp4725_ctrl
→ i2c_master

的职责。

集成层只向下传：

SYS_CLK_HZ
DAC_I2C_HZ
I2C_ADDR

避免重复时序算法。

## 35. 新增 Testbench

建议：

sim/tb_dds_mcp4725_pipeline.v

以及如有必要：

sim/models/mcp4725_model.v

只扩展已有模型，不另复制：

mcp4725_audio_model.v
## 36. Pipeline TB至少包含六组测试
A. Reset / idle

检查：

reset
bus released
busy=0
overrun=0
B. 静音

连续：

128 samples

必须全部：

12'h800
C. 七音短序列

每个音：

128 samples

全部逐样点scoreboard比对。

D. 长时间吞吐

真实：

12MHz
8kS/s
~333k I²C
4096 samples

要求0 drop / 0 overrun。

E. note transition

例如：

C4 → A4 → B4 → mute

检查相位和样点序列。

F. 错误/overrun恢复

地址NACK、数据NACK或故意过载，检查：

不死锁
总线释放
后续可恢复
## 37. 推荐新增 simulations

建议 project.json 增加：

name	用途
dds_mcp4725_pipeline	基础端到端
dds_mcp4725_pipeline_12m	真实吞吐
dds_mcp4725_pipeline_error	NACK/恢复
dds_mcp4725_pipeline_disabled	ENABLE=0

passPattern：

TB_DDS_MCP4725_PIPELINE: PASS

错误测试也应该最终输出PASS——表示：

预期错误被正确处理。

## 38. 是否需要再次测量七音频率

需要做传输后抽检，但不用像DDS standalone那样跑特别长。

推荐直接对：

MCP4725 model captured DAC samples

进行零交叉统计。

也就是说频率观察点必须放在：

I2C接收后的DAC code序列

而不是DDS内部。

至少验证：

C4
A4
B4

三个代表音。

要求：

$$ |error|<1\% $$

这可以证明：

数据经过controller和I²C以后，波形时间顺序仍然正确。

## 39. 最终输出仍然是数字样点，不声称“模拟正弦已验证”

本计划结束后只能说：

DDS digital sine samples: PASS
MCP4725 Fast Write pipeline: PASS
end-to-end digital audio stream: PASS

不能说：

MCP4725 analog sine output: PASS
LM386 audio input sine: PASS
speaker output: PASS

因为这些需要：

真实DAC
示波器
模拟低通
LM386

实测。

## 40. 本阶段不实现模拟重构滤波器

后续硬件链会是：

MCP4725 VOUT
    ↓
RC低通
    ↓
音量/耦合
    ↓
LM386

本计划只到：

MCP4725数字写入

为止。

## 41. project.json集成

将：

dds_mcp4725_pipeline.v

加入 sources。

顺序必须保证：

sine_lut_12bit.v
dds_sine_generator.v

i2c_master.v
mcp4725_ctrl.v

dds_mcp4725_pipeline.v

...
finger_piano_top.v

被引用模块先于引用模块。

## 42. 现有顶层仍然不实例化Pipeline

即：

finger_piano_top.v

完全不需要知道：

dds_mcp4725_pipeline

存在。

因此默认 implementation：

I/O数量不应增加

也不会因为DAC管脚未确认而影响当前 UCF。

## 43. 旧回归必须全部保持

所有已有：

legacy 7-key
tone_generator
3-bit standalone
ADS1115 standalone
MCP4725 standalone
DDS standalone

测试都必须继续 PASS。

本计划禁止为了使新pipeline通过而修改旧测试期望。

## 44. 综合警告仍为零容忍

项目已有：

failOnSynthesisWarnings=true

因此：

XST warning > 0

不能接受。

如果未实例化 pipeline 被优化掉：

这是正常现象。

但源码本身必须通过XST解析/检查。

## 45. Pipeline状态输出

建议只保留真正有价值的：

dac_busy
dac_error
dac_overrun

不要添加过多：

state_debug
byte_count_debug
phase_debug

到可综合公共接口。

仿真可以通过层级引用观察内部状态。

## 46. 未来顶层启用时的边界

本计划完成以后，未来真正接入顶层只需：

note_code
  ↓
dds_mcp4725_pipeline

以及：

dac_i2c_scl
dac_i2c_sda

两根物理管脚。

但本计划：

不做这个动作
## 47. 提交顺序

建议严格分成以下 commits。

Commit A — Pipeline wrapper

新增：

dds_mcp4725_pipeline.v

只连接已有模块。

运行XST语法检查。

Commit B — Basic end-to-end TB

新增：

tb_dds_mcp4725_pipeline.v

实现：

mute
C4
A4
B4

以及逐样点scoreboard。

Commit C — Real throughput verification

加入：

12MHz
8kHz
~333kHz I2C
4096 samples

要求：

0 drop
0 overrun
0 errors
Commit D — Error/recovery verification

增加：

address NACK
data NACK
mid-transaction reset
forced overrun

全部验证恢复。

Commit E — Project integration

更新：

project.json

增加 pipeline RTL 和 simulations。

然后运行：

pwsh -File .\ise.ps1 verify -Project finger_piano
Commit F — Documentation

新增/更新：

doc/DDS到MCP4725数字音频链路集成计划.md
projects/finger_piano/README.md

README状态写：

DDS → MCP4725 digital pipeline:
IMPLEMENTED
SIMULATED
NOT_TOP_INTEGRATED
NOT_BOARD_TESTED
## 48. 最终验收清单

Agent结束时必须逐项满足：

[ ] DDS standalone仍PASS
[ ] MCP4725 standalone仍PASS

[ ] pipeline只复用现有DDS和DAC controller
[ ] pipeline没有第二套sample counter
[ ] pipeline没有额外FIFO
[ ] pipeline没有暂停DDS的ready反馈

[ ] DDS valid保持8kHz固定时间轴
[ ] 12MHz下每1500 clk一个sample
[ ] MCP4725 ready在正常每个sample到达时均为1

[ ] 4096连续样点生成
[ ] 4096连续样点被接受
[ ] 4096个Fast Write完成
[ ] scoreboard逐样点0 mismatch
[ ] dac_overrun = 0
[ ] dac_error = 0

[ ] mute样点始终12'h800
[ ] C4/A4/B4传输后频率抽检<1%
[ ] 七个note_code均完成端到端短序列

[ ] note切换不改变sample cadence
[ ] note切换后传输顺序正确

[ ] reset时总线释放
[ ] mid-transaction reset能够终止并恢复
[ ] NACK不会永久busy
[ ] 错误后允许处理后续新样点
[ ] 不重传已过时音频样点

[ ] 整个DDS路径无EEPROM写
[ ] 默认地址可参数化
[ ] ENABLE=0无总线活动

[ ] finger_piano_top.v未修改
[ ] tone_generator/audio_out未修改
[ ] UCF未修改
[ ] 未增加板级DAC端口
[ ] 未执行program

[ ] XST 0 errors
[ ] XST 0 warnings
[ ] 所有新增simulation PASS
[ ] 所有旧simulation继续PASS
[ ] 完整verify PASS