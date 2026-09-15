finger_piano DDS 正弦音频发生器开发计划
0. 最高优先级约束

本阶段只开发并验证数字 DDS 正弦样点发生器，不进行最终顶层音频迁移。当前 tone_generator → audio_out 方波路径是已验证 legacy baseline，必须保持不变。DDS 输出为 12-bit 无符号数字样点，未来交给 MCP4725；本阶段不得新增 DAC GPIO、不得修改 UCF、不得实例化 MCP4725 到顶层、不得修改 LM386 接口、不得执行 program。所有新时序逻辑只能使用系统 clk，8 kHz 只能作为 clock-enable/sample-valid，禁止生成第二时钟。每阶段完成后必须运行对应 ISim，最终执行完整 verify -Project finger_piano。

1. 本阶段目标

新增一条独立的数字音频生成链：

note_code[2:0]
      ↓
音符 → phase increment
      ↓
24-bit DDS phase accumulator
      ↓
8-bit phase address
      ↓
12-bit sine LUT
      ↓
dac_code[11:0]
      +
dac_code_valid @ 8 kS/s

目标接口最终能够直接连接：

DDS
 ↓ 12 bit + valid
MCP4725 controller

但本阶段二者不集成。

当前工程：

note_code
   ↓
tone_generator
   ↓
audio_out 方波

保持原样。

新增 DDS 只是：

IMPLEMENTED / STANDALONE
NOT_INTEGRATED
2. 课程指标与工程设计值

课程资料支持的要求是：

扩展：数字 DDS 音频；
扩展：音频功放输入正弦波；
提高部分音阶误差目标 1% 以内。

本项目进一步冻结以下工程参数：

参数	本阶段设计值
系统时钟	12 MHz
DDS采样率	8 kS/s
DAC样点位宽	12 bit unsigned
相位累加器	24 bit
相位地址	8 bit / 256相位位置
正弦中心码	2048 (12'h800)
最大幅度	1792
正弦数字范围	256～3840
静音数字值	2048
音符	C4～B4 七音

8 kS/s 与第一份 ADS1115/MCP4725 计划保持一致。

第一份计划若已经提供：

`define CFG_DAC_SAMPLE_RATE 8000

DDS必须复用该配置，不再创建第二份采样率真值源。

3. 为什么采用 8 kS/s

最高音：

$$ f_{B4}=493.88Hz $$

所以：

$$ \frac{8000}{493.88}\approx16.2 $$

即最高音每个周期仍有约16个实际DAC采样点。

最低 C4：

$$ \frac{8000}{261.62}\approx30.6 $$

约31点/周期。

因此：

C4  ≈ 31 samples / cycle
B4  ≈ 16 samples / cycle

对于课程设计的：

DDS → MCP4725 → 重构低通 → LM386

是可用的。

8 kS/s 同时给 MCP4725 的独立约333 kHz I²C总线留有发送裕量。

4. 不做哪些事情

本阶段明确禁止：

不删除或修改 tone_generator.v；
不修改现有 audio_out；
不修改 finger_piano_top.v 端口；
不增加 MCP4725 SDA/SCL；
不修改 UCF；
不执行烧录；
不实现 LM386 模拟滤波；
不实现压力控制音量；
不实现 ADS1115 → DDS 联动；
不实现 DDS → MCP4725 系统级 pipeline；
不用 PWM 假装 DAC；
不产生 clk_8k；
不在 always @(posedge sample_tick) 中写逻辑；
不使用 SystemVerilog；
不修改冻结 ISE 工具链。

DDS→MCP4725 联调属于下一份计划。

5. 新增模块建议

新增：

projects/finger_piano/
├── src/
│   └── audio/
│       ├── sine_lut_12bit.v
│       └── dds_sine_generator.v
│
├── sim/
│   ├── tb_sine_lut_12bit.v
│   └── tb_dds_sine_generator.v
│
├── dds_frequency_table.md
│
└── project.json

不需要拆出独立：

sample_clock.v
phase_accumulator.v

第一版保持适度模块化即可。

6. DDS数学原理

采用标准相位累加 DDS：

$$ \phi[n+1] = \phi[n]+\Delta\phi \pmod{2^{24}} $$

其中：

$$ \Delta\phi = round \left( \frac{f_{note}}{f_s}2^{24} \right) $$

本设计：

$$ f_s=8000Hz $$

相位分辨率对应的频率步进：

$$ \Delta f = \frac{8000}{2^{24}} \approx0.000477Hz $$

远优于课程要求的 1%。

7. 七音 Phase Increment 冻结表

使用课程资料给出的实际两位小数频率，而不是现有方波模块为了整数运算采用的0.1 Hz近似。

8 kS/s、24-bit phase accumulator：

note	标称频率 Hz	Phase Increment	24-bit hex	DDS理论频率 Hz
C4	261.62	548657	24'h085F31	261.620045
D4	293.67	615871	24'h0965BF	293.670177
E4	329.63	691284	24'h0A8C54	329.629898
F4	349.23	732388	24'h0B2CE4	349.229813
G4	391.99	822063	24'h0C8B2F	391.990185
A4	440.00	922747	24'h0E147B	440.000057
B4	493.88	1035741	24'h0FCDDD	493.879795

误差都远小于：

$$ 0.001\% $$

但验收标准仍按课程指标：

$$ \boxed{|error|<1\%} $$
8. Phase Increment 不允许“神秘硬编码”

RTL可以使用上表的24位常量，原因是老版本 XST 下直接做：

frequency × 2^24

容易涉及32位整数常量溢出。

但是必须同时新增：

dds_frequency_table.md

记录：

公式；
8 kS/s；
24-bit phase；
七个标称频率；
十进制 increment；
十六进制 increment；
理论输出频率；
理论误差。

TB必须独立使用课程标称频率检查结果。

不得让：

RTL表错了 + 文档照抄RTL表 + TB也照抄同一表

三者一起错误仍然PASS。

9. 采样 Clock Enable

12 MHz系统时钟下：

$$ \frac{12,000,000}{8000}=1500 $$

所以：

每1500个clk产生一次sample_tick

必须实现为：

clk
 ↓
counter
 ↓
sample_tick (1 clk wide)

不能生成：

clk_8k

作为新时钟。

所有时序逻辑必须：

always @(posedge clk ...)

然后：

if (sample_tick)

更新DDS。

10. 采样率生成精确定义

建议：

localparam integer SAMPLE_DIV =
    SYS_CLK_HZ / SAMPLE_RATE_HZ;

当前设计冻结条件：

SYS_CLK_HZ     = 12000000
SAMPLE_RATE_HZ = 8000

必须满足：

SAMPLE_DIV = 1500

第一版不需要实现任意非整除频率的 fractional-N sample enable。

如果未来：

SYS_CLK_HZ % SAMPLE_RATE_HZ != 0

属于后续功能扩展，不得在本阶段为了“泛化”增加复杂度。

文档明确写：

本阶段 12 MHz / 8 kHz 是精确整除配置。

11. sine_lut_12bit.v

不建议写256个完整12位波形值。

考虑 XC3S50AN 资源规模，采用：

$$ \boxed{\text{quarter-wave LUT}} $$

建议：

65 × 11-bit magnitude

存储：

$$ 0^\circ\sim90^\circ $$

幅度：

$$ 0\sim1792 $$

然后利用四象限对称得到完整256相位。

12. LUT输入输出

推荐：

module sine_lut_12bit (
    input  wire [7:0]  phase_addr,
    output reg  [11:0] sine_code
);

其中：

phase_addr = phase_acc[23:16]

对应：

00 ~ 3F :   0° ~ <90°
40 ~ 7F :  90° ~ <180°
80 ~ BF : 180° ~ <270°
C0 ~ FF : 270° ~ <360°
13. LUT输出采用无符号偏置正弦

MCP4725不能输出负电压。

因此数字正弦定义为：

$$ DAC= 2048+1792\sin(\theta) $$

数字范围：

$$ 256\le DAC\le3840 $$

即：

minimum = 12'h100
center  = 12'h800
maximum = 12'hF00

保留两端余量，不使用：

000
FFF

满轨。

14. 为什么中心必须是 12'h800

将来 MCP4725 3.3V供电时：

2048 ≈ 1.65V

因此：

DAC输出 = 直流1.65V + 正弦

经过交流耦合后：

DC被去掉

LM386得到交流信号。

因此静音不能定义成：

DAC code = 0

否则音符停止时 DAC 会从波形跳到0V，引入很大的直流阶跃。

静音冻结为：

$$ \boxed{12'h800} $$
15. Quarter-wave 索引建议

使用：

phase_addr[7:6] → quadrant
phase_addr[5:0] → index

LUT定义65点：

LUT[0]  = sin(0°)
...
LUT[64] = sin(90°)

映射建议：

quadrant 0:
    +LUT[index]

quadrant 1:
    +LUT[64-index]

quadrant 2:
    -LUT[index]

quadrant 3:
    -LUT[64-index]

这样：

phase 0   → 2048
phase 64  → 3840
phase 128 → 2048
phase 192 → 256

TB必须精确验证这四个关键点。

16. LUT生成原则

LUT magnitude：

$$ M[k] = round \left( 1792\sin\frac{k\pi}{128} \right) $$

其中：

$$ k=0\ldots64 $$

Agent可以在实施过程中使用脚本生成常量，但最终可综合 RTL必须是稳定的 Verilog-2001 内容。

不得在综合 RTL 中依赖：

real
$sin
运行时文件生成

测试代码可以使用 real 做独立检查。

17. LUT TB

tb_sine_lut_12bit.v 至少检查：

范围

对：

phase = 0..255

全部遍历。

要求：

$$ 256\le code\le3840 $$
四个象限关键点

必须：

phase 0   = 2048
phase 64  = 3840
phase 128 = 2048
phase 192 = 256

允许 LUT舍入造成：

±1 LSB

仅限非关键中间点。

半周期反对称

检查：

$$ code[p]+code[p+128]\approx4096 $$

容差：

≤ 1 LSB
四分之一波单调性
phase 0→64

必须单调不减。

18. dds_sine_generator.v

推荐接口：

module dds_sine_generator #(
    parameter integer SYS_CLK_HZ     = `SYS_CLK_HZ,
    parameter integer SAMPLE_RATE_HZ = `CFG_DAC_SAMPLE_RATE,
    parameter integer ENABLE         = `CFG_ENABLE_DDS
) (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire [2:0]  note_code,

    output wire [11:0] dac_code,
    output reg         dac_code_valid
);

建议新增：

`define CFG_ENABLE_DDS 0

但因为本阶段不实例化顶层，该宏只是：

standalone / future integration config

不是“改成1就启用硬件”。

19. DDS内部状态

至少：

sample_cnt
phase_acc[23:0]
phase_inc[23:0]
note_q[2:0]

不要额外生成新时钟。

20. note → phase increment

组合逻辑：

0 → 0
1 → C4 increment
2 → D4 increment
...
7 → B4 increment

对：

note_code = 0

冻结：

phase_inc = 0
phase_acc = 0
dac_code  = 2048
21. Phase更新规则

仅当：

sample_tick = 1

时：

phase_acc <= phase_acc + phase_inc

24-bit自然溢出即：

$$ mod\ 2^{24} $$

禁止自己写昂贵的 % 运算。

22. 音符切换行为

为了与现有 tone_generator 的可预测行为一致，同时尽量避免从随机幅值启动，定义：

note_code发生变化时相位重启到0。

即：

C4 → A4

首先：

phase_acc = 0

下一次正常采样输出：

sine(0°) = 2048

然后按新音符 phase increment 前进。

所以每个新音符从：

零交叉 / DAC中点

开始。

23. 音符切换不能改变8 kHz采样节拍

重要：

note change

不能：

立即额外产生一个 dac_code_valid；
重启 sample divider；
拉长或缩短一个 sample period。

dac_code_valid 必须始终：

严格每1500个系统clk一个脉冲

只改变：

phase

不改变 sample cadence。

24. dac_code_valid

在 ENABLE=1 时：

每个sample_tick拉高1个clk

包括：

note_code = 0

静音状态。

也就是说静音时仍产生：

8 kS/s
12'h800

这样后续 MCP4725 pipeline 可以保持完全统一的固定采样节拍。

因为 ADC 与 DAC 使用独立 I²C，总线流量不会影响 ADS1115。

25. ENABLE=0行为

当：

ENABLE=0

必须：

dac_code       = 12'h800
dac_code_valid = 0
phase_acc      = 0

不得产生周期性内部事务。

由于本阶段 DDS未实例化顶层，因此默认工程功能完全不变。

26. 与 MCP4725 ready 的关系

本阶段 DDS不要加入 dac_ready 输入。

原因：

DDS定义的是：

固定时间轴上的8 kHz样点发生器。

样点时间不能因为下游 busy 被随意推迟，否则实际采样周期发生抖动。

因此：

DDS：固定产生8 kHz valid
MCP4725 controller：负责判断能否接受

下一份 pipeline 计划必须证明：

每一次DDS valid到达时
MCP4725 ready都为1

正常状态：

0 drop
0 overrun

如果下游异常，则由 MCP4725 controller 的 dac_overrun 报告。

27. 为什么不要“ready拉低就暂停DDS”

如果：

ready=0

时暂停相位累加器，那么：

125us
125us
250us
125us
...

样点间隔会变化。

这相当于：

对音频进行时间轴拉伸

会直接造成频率/相位调制。

所以 DDS时间轴必须独立。

28. DDS Testbench总体结构

新增：

tb_dds_sine_generator.v

至少分为：

A. reset
B. sample cadence
C. mute
D. phase table
E. 7 notes frequency
F. note transition
G. range
H. ENABLE=0
29. Sample cadence测试必须使用真实12 MHz

必须至少有一个用例：

TB_SYS_CLK_HZ     = 12000000
TB_SAMPLE_RATE_HZ = 8000

测量相邻：

dac_code_valid

之间系统时钟数。

必须：

$$ 1500 $$

不能：

1499
1501

也必须确认：

dac_code_valid

只持续1个系统时钟。

30. 七音频率测试可以降系统仿真时钟

DDS输出频率由：

sample rate + phase increment

决定，与系统主时钟本身无关，只要8 kHz sample enable正确。

为了缩短 ISim：

TB_SYS_CLK_HZ = 1000000

仍保持：

SAMPLE_RATE_HZ = 8000

此时：

$$ 1MHz/8kHz=125 $$

个系统周期/样点。

可大幅降低仿真时间。

但：

sample cadence 的板上真实性测试必须另有 12 MHz 用例。

31. 七音必须全部实测

不能只测：

C4
A4

必须：

C4
D4
E4
F4
G4
A4
B4

全部验证。

目标频率必须来自课程资料的：

261.62
293.67
329.63
349.23
391.99
440.00
493.88

32. 频率外部验证方法

TB不能仅检查：

phase_inc == 某个硬编码值

还必须从输出样点独立估计频率。

推荐监测：

dac_code < 2048
→
dac_code >= 2048

的正向零交叉。

在固定样本窗口内统计 crossing 数：

$$ f_{meas} = \frac{N_{crossing}}{N_{samples}}f_s $$

建议：

8192～16384 samples / note

然后：

$$ \left| \frac{f_{meas}-f_{nom}}{f_{nom}} \right|<1\% $$
33. 再增加 Phase Increment 独立检查

为了避免零交叉统计分辨率较低，同时验证DDS核心参数，TB可以用 real 独立计算：

$$ round\left( f_{nom}\frac{2^{24}}{8000} \right) $$

并与 DUT 选择出的 phase increment 比较。

这里测试代码可以使用：

real

因为：

testbench不综合。

RTL仍不得使用 real。

这样得到双重验证：

phase increment数学检查
+
实际DAC sample零交叉检查
34. Range测试

整个仿真期间：

dac_code

必须始终：

$$ 256\le code\le3840 $$

启用状态下不能：

X
Z

静音必须：

12'h800
35. Note transition测试

例如：

C4
 ↓
A4
 ↓
B4
 ↓
mute

每次切换必须验证：

8 kHz valid cadence没有改变；
相位重启；
新音符第一个有效样点为 12'h800；
后续使用新 phase increment；
mute后所有有效样点为 12'h800；
不出现超出 [256,3840] 的数字值。
36. Phase wrap测试

24-bit：

FFFFFF + increment

应自然溢出。

TB至少让一个音持续足够时间，确认：

phase_acc

经过 wrap 后：

没有 X；
DAC仍连续；
valid节拍不变；
正弦重复。

不得使用 % 16777216。

37. 推荐 project.json 用例

建议新增：

name	top	用途
sine_lut_12bit	tb_sine_lut_12bit	LUT完整检查
dds_sine_generator	tb_dds_sine_generator	快速功能/七音频率
dds_sine_generator_12m	tb_dds_sine_generator	真实12MHz sample cadence
dds_sine_generator_disabled	tb_dds_sine_generator	ENABLE=0

对应 passPattern：

TB_SINE_LUT_12BIT: PASS
TB_DDS_SINE_GENERATOR: PASS
38. 现有仿真零修改

当前已经存在的 legacy 用例：

note_encoder
tone_generator
tone_generator_12m
top_default
top_active_low
top_filter_bypass

本阶段：

$$ \boxed{\text{零修改}} $$

全部必须继续 PASS。

39. 不修改现有 frequency_table.md

现有：

frequency_table.md

描述的是：

方波 tone_generator

不要把 DDS 数据塞进去。

新增：

dds_frequency_table.md

分别维护。

这样报告中可以明确比较：

基础功能：整数分频方波
扩展功能：DDS正弦波
40. dds_frequency_table.md 必须记录

至少包含：

课程标称频率来源；
SAMPLE_RATE_HZ = 8000；
PHASE_BITS = 24；
phase increment公式；
七个 increment；
理论DDS频率；
理论误差；
LUT中心/幅度；
数字输出范围；
静音=2048；
修改 sample rate 后必须重新生成 phase table。

特别写明：

Phase increment表只适用于8 kS/s，不能只修改采样率宏而继续沿用旧表。

41. 第一版不要做“任意采样率自动算phase increment”

原因是：

f × 2^24

在老 XST / Verilog integer 常量表达式中容易遇到32位溢出和类型宽度陷阱。

当前：

8k fixed sample rate
+
7 fixed notes

完全没有必要为通用性引入风险。

如果未来真的要改 sample rate：

重新生成7项表即可。

42. 第一版不要使用乘法器计算正弦

禁止：

CORDIC
Taylor
实时乘法sin

本项目：

7个固定音
12-bit DAC
8 kS/s

查表是最合适方案。

43. 不实现动态音量缩放

目前：

$$ A=1792 $$

固定。

不要在本阶段添加：

amplitude input

以及：

sine × volume

因为这会：

引入乘法器资源；
扩大验证范围；
把压力ADC功能耦进DDS核心。

以后如果做压力控制音量，另加：

audio_gain

层。

DDS核心只负责：

准确地产生标准幅值正弦样点。

44. 综合要求

新增 RTL 必须：

Verilog-2001

避免：

logic
always_ff
always_comb
$clog2
SystemVerilog array literal

所有 sequential logic：

always @(posedge clk or negedge rst_n_sync)

且只有：

clk

一个有效时钟。

45. 资源要求

这是 XC3S50AN 小器件，因此要特别检查：

FF
LUT
ROM inference

要求 Agent 在最终 verify 后记录新模块独立综合/工程综合资源变化。

由于新模块未实例化到顶层，默认 legacy 网表不应该明显膨胀。

但 DDS module本身必须通过XST语法检查和 standalone仿真。

46. LUT实现如果产生异常资源或XST warning

禁止：

为了坚持某种写法而接受 warning。

优先级：

XST 0 warning
↓
功能正确
↓
资源合理

如65项 quarter-wave case 最稳定，则使用它。

不强求 block RAM inference。

3072 bit左右的DDS数据不值得为了“必须BRAM”增加工具链风险。

47. 配置宏建议

在：

finger_piano_cfg.vh

追加：

`define CFG_ENABLE_DDS         0
`define CFG_DDS_PHASE_BITS    24

采样率继续复用：

`define CFG_DAC_SAMPLE_RATE   8000

不要新增：

CFG_DDS_SAMPLE_RATE

形成两个真值源。

输出位宽第一版固定12位，不必伪参数化。

48. 与第一份 ADC/DAC 计划的依赖关系

本计划依赖第一计划提供的：

CFG_DAC_SAMPLE_RATE = 8000

如果执行顺序为：

ADC/DAC计划
→
DDS计划

直接复用。

如果 Agent 执行 DDS 时第一计划尚未走到配置接入阶段：

先完成第一计划对应配置提交，再开始 DDS；不要临时在 DDS 模块中硬写第二份 8000 真值源。

49. 与第二份3-bit计划的关系

DDS只接受：

note_code[2:0]

所以它完全不关心 note_code 是由：

legacy 7-key priority encoder

还是未来：

3-bit sensor decoder

产生。

这是刻意的模块边界：

输入系统
    ↓
note_code
    ↓
音频生成系统

二者不得耦合。

50. 提交顺序

建议严格拆为以下 commits。

Commit A — DDS文档/参数表

新增：

dds_frequency_table.md

冻结：

8k
24bit
七音phase increment
12bit DAC范围

先把数学真值确定。

Commit B — Sine LUT

新增：

sine_lut_12bit.v
tb_sine_lut_12bit.v

要求：

256相位全部遍历PASS
Commit C — DDS Core

新增：

dds_sine_generator.v
tb_dds_sine_generator.v

先跑：

reset
mute
sample timing
phase accumulation
note transition
Commit D — Seven-note frequency verification

扩展 TB：

C4~B4全部频率测试
phase increment独立数学检查
zero crossing实际样点检查

必须全部 PASS。

Commit E — Project integration

把新RTL和新simulation加入：

project.json

但：

finger_piano_top.v 不改
audio_out 不改
UCF 不改

运行完整：

pwsh -File .\ise.ps1 verify -Project finger_piano
Commit F — Documentation/status

更新：

projects/finger_piano/README.md

标记：

DDS sine generator:
IMPLEMENTED
SIMULATED
NOT_INTEGRATED
NOT_BOARD_TESTED

不得写：

DDS hardware PASS

因为还没有接 MCP4725。

51. 最终验收清单

Agent结束本计划时必须满足：

[ ] 当前 legacy 方波音频路径零修改
[ ] tone_generator.v 零修改
[ ] finger_piano_top.v 端口零修改
[ ] UCF无新增DAC管脚
[ ] 未执行program

[ ] SAMPLE_RATE = 8000 Hz
[ ] 12 MHz下sample interval = 1500 clk
[ ] sample valid严格1 clk宽
[ ] 无clk_8k或其它派生时钟

[ ] phase accumulator = 24 bit
[ ] C4~B4七个phase increment正确
[ ] 七音理论频率误差远小于1%
[ ] 七音ISim外部频率检查全部 <1%

[ ] sine LUT使用12-bit unsigned
[ ] center = 2048
[ ] output range = 256~3840
[ ] phase0 = 2048
[ ] phase64 = 3840
[ ] phase128 = 2048
[ ] phase192 = 256
[ ] LUT对称性PASS

[ ] note=0时输出持续2048
[ ] note切换相位归零
[ ] note切换不改变8k采样节拍
[ ] ENABLE=0时valid=0且code=2048

[ ] 所有新RTL为Verilog-2001
[ ] XST 0 errors
[ ] XST 0 warnings
[ ] 新DDS simulations全部PASS
[ ] 原有全部simulations继续PASS
[ ] 完整verify PASS

[ ] DDS状态标记为NOT_INTEGRATED
[ ] 未声称MCP4725硬件已验证