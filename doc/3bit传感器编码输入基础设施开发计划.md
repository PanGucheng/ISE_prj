# finger_piano 3-bit 传感器编码输入基础设施开发计划

> **Status**: IMPLEMENTED / STANDALONE（已仿真通过,默认不接顶层,未上板）
> **Scope**: standalone 3-bit 传感器输入 RTL + ISim（legacy 7-key 顶层保持不动）
> **Depends on**: 现有同步/滤波基础设施（`key_sync` / `key_filter`）；与 P1 独立
> **Top integration**: NO
> **UCF changes**: NO
> **Hardware programming**: FORBIDDEN
> **Acceptance**: full `verify`（`.\ise.ps1 verify -Project finger_piano`）
>
> **落地记录（2026-09-16）**:Commit A decoder（776659d）、B atomic vector
> filter（c454e22）、C frontend（1821585）逐阶段仿真 PASS;D 全量
> verify-20260916-015815-edd2f5fa Overall PASS（综合 0 errors / 0 warnings /
> 0 latches,232 FF / 20 IOs 与基线一致,13 个仿真全部 PASS）;E 文档（本条）。
> 文件:`src/input/sensor_code_{decoder,filter,frontend}.v` +
> `sim/tb_sensor_code_*.v`;新增仿真 sensor_code_decoder / sensor_code_filter /
> sensor_code_frontend_high / sensor_code_frontend_low。
> 顶层迁移（§31）仍等用户逐脚确认 3 个 LM393 引脚后单独执行。

本阶段只开发并验证 3-bit 传感器编码输入基础设施，不进行最终顶层迁移。当前 key_in[6:0] → note_encoder 路径是已验证 legacy baseline，必须保持不变。真实硬件采用 3 个 LM393 输出组成 3-bit 编码，项目冻结编码为 000=静音，001~111=唱名1~7。三位编码必须先经两级同步，再使用 whole-vector atomic stable filter；禁止简单复用现有逐bit key_filter 作为最终码字滤波。新增 RTL 可以进入 project.json 接受 XST/ISim 验证，但不得增加未约束顶层端口、不得修改 UCF、不得执行 program。每个阶段完成后运行对应 simulation，最终必须执行完整 verify -Project finger_piano，任何回归失败必须先修复，不得带着失败继续叠加功能。

## 1. 本阶段目标

为 projects/finger_piano 增加真实硬件所需的 3 路 LM393 数字输入 → 3-bit 编码 → note_code[2:0] 输入基础设施，并通过 ISim 完成独立验证。

真实硬件输入最终为：

LM393 #0 ──→ bit0 ─┐
LM393 #1 ──→ bit1 ─┼──→ 3-bit sensor code ──→ note_code
LM393 #2 ──→ bit2 ─┘

编码约定冻结为：

sensor code	note_code	唱名
000	0	静音
001	1	C4
010	2	D4
011	3	E4
100	4	F4
101	5	G4
110	6	A4
111	7	B4

其中：

sensor_code[0] = 权重 1
sensor_code[1] = 权重 2
sensor_code[2] = 权重 4

因此：

$$ \boxed{note\_code=sensor\_code} $$

数值上虽然是恒等映射，但仍保留独立的 sensor_code_decoder 模块作为硬件语义边界。

课程资料只要求采样后的数据编码产生 1～7 音，并给出 3 路 0/1 采样验收；上述二进制编码次序属于本项目设计冻结。

## 2. 本阶段必须保持的 legacy baseline

当前远端工程已经验证的路径仍然是：

key_in[6:0]
   ↓
key_sync
   ↓
key_filter
   ↓
note_encoder
   ↓
tone_generator
   ↓
audio_out

即：

7 路独立数字键 → 7 路优先级编码 → 音符

这是已经通过综合、仿真和板级工具链验证的软件基线。

本阶段不得修改这条路径。

也就是说本阶段：

finger_piano_top.v   不改端口
note_encoder.v       不删
key_in[6:0]          不改
现有 UCF             不改
audio_out            不改

新增的 3-bit 输入基础设施：

作为可综合但尚未接入现有顶层的独立 RTL 存在。

## 3. 明确不做

本计划禁止：

不把 key_in[6:0] 改成 3 bit；
不删除 legacy note_encoder.v；
不修改当前七路输入 UCF LOC；
不猜三路 LM393 最终 FPGA 管脚；
不让 MAP 自动给新端口分配管脚；
不修改 tone_generator；
不实现 DDS；
不修改 ADS1115 / MCP4725 方案；
不执行 JTAG / ISF program；
不改变 12 MHz 系统时钟；
不把本计划与 ADC/DAC commit 混在一起；
不为了赶进度绕过已有 verify 门禁。
## 4. 为什么不能直接把现有 key_filter 改成 WIDTH=3

现有：

key_filter.v

是每一个 bit 独立计数、独立更新。

对于七个独立按键这是合理的。

但真实系统的三个 bit 不是三个独立音符，而是：

共同组成一个二进制码字。

例如：

001 → 111

实际三路比较器由于：

手指按压不同步；
比较器翻转时刻不同；
FPGA 输入同步延迟；
模拟噪声；

可能短暂经过：

001
 ↓
011
 ↓
111

如果三个 bit 分别独立去抖，可能把：

011

短暂提交为稳定结果，从而错误播放 E4。

因此新链路必须采用：

$$ \boxed{\text{whole-vector atomic filtering}} $$

即：

整个 3-bit 向量连续稳定达到门限后，三个 bit 一次性更新。

## 5. 新的数字输入架构

最终准备好的独立模块链：

sensor_async[2:0]
        ↓
   polarity normalize
        ↓
key_sync WIDTH=3
        ↓
sensor_code_filter
  （整体码字稳定）
        ↓
sensor_code_stable[2:0]
        ↓
sensor_code_decoder
        ↓
note_code[2:0]

形成：

              ┌──────────────────────────────┐
LM393[2:0] →  │ sensor_code_frontend        │
              │                              │
              │ polarity                    │
              │    ↓                         │
              │ key_sync WIDTH=3             │
              │    ↓                         │
              │ vector stable filter         │
              │    ↓                         │
              │ sensor_code_decoder          │
              └──────────┬───────────────────┘
                         ↓
                  note_code[2:0]

全工程仍只有：

clk

一个时钟域。

不得使用 sensor input 作为时钟。

## 6. 新增文件

建议：

projects/finger_piano/
├── src/
│   └── input/
│       ├── sensor_code_decoder.v
│       ├── sensor_code_filter.v
│       └── sensor_code_frontend.v
│
├── sim/
│   ├── tb_sensor_code_decoder.v
│   ├── tb_sensor_code_filter.v
│   └── tb_sensor_code_frontend.v
│
└── project.json

不要修改：

finger_piano_top.v
constraints/finger_piano.ucf
note_encoder.v
tone_generator.v
## 7. sensor_code_decoder.v

功能：

稳定3-bit传感器编码
        ↓
     note_code

推荐接口：

module sensor_code_decoder (
    input  wire [2:0] sensor_code,
    output reg  [2:0] note_code
);

明确编码：

always @(*) begin
    case (sensor_code)
        3'b000: note_code = 3'd0;
        3'b001: note_code = 3'd1;
        3'b010: note_code = 3'd2;
        3'b011: note_code = 3'd3;
        3'b100: note_code = 3'd4;
        3'b101: note_code = 3'd5;
        3'b110: note_code = 3'd6;
        3'b111: note_code = 3'd7;
        default: note_code = 3'd0;
    endcase
end

虽然逻辑等价于：

assign note_code = sensor_code;

但本阶段建议显式 case。

原因不是综合需要，而是：

编码表是课程设计的重要设计语义

这样：

RTL直接表达编码关系；
TB容易核对；
以后编码表调整只改一处；
报告里可以直接对应编码表；
不把“位线”和“音符编号”概念混成同一件事。

XST 即使最终把它优化成连线也没有问题。

## 8. sensor_code_filter.v

这是本计划最重要的新模块。

接口：

module sensor_code_filter #(
    parameter integer SYS_CLK_HZ = 12000000,
    parameter integer STABLE_MS  = 10,
    parameter integer ENABLE     = 1
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [2:0] code_sync,
    output wire [2:0] code_stable
);

实现必须采用：

candidate register
+
一个稳定计数器
+
stable register

不能：

三个 bit 三个独立 counter
## 9. vector filter 精确定义

定义：

$$ STABLE\_CYCLES = \max \left( 1, \frac{SYS\_CLK\_HZ}{1000}\times STABLE\_MS \right) $$

与当前工程去抖时间定义保持一致。

12 MHz、10 ms：

$$ STABLE\_CYCLES=120000 $$

现有：

FP_FILTER_CNT_WIDTH = 24

足够使用。

## 10. Filter行为

必须保证：

一个完整的3-bit输入向量只有连续保持相同 STABLE_CYCLES 个系统时钟，才更新 code_stable。

例如：

当前稳定码 = 001

然后输入：

011     2ms
101     3ms
111    10ms

则：

011 不能输出
101 不能输出
111 达到稳定门限后才一次性输出

即：

code_stable

001 ─────────────────────────────── 111
                                   ↑
                              整体一次更新

禁止出现：

001 → 011 → 101 → 111

这种由于 bit 独立滤波造成的短暂错误 note。

## 11. 推荐 FSM/算法

内部建议：

stable_q
candidate_q
stable_count

工作逻辑：

code_sync == stable_q
    ↓
计数清零
candidate同步回stable_q

code_sync != stable_q
    ↓
如果 code_sync != candidate_q
    ↓
记录新的 candidate
重新开始计数

如果 code_sync == candidate_q
    ↓
继续累计稳定周期

达到 STABLE_CYCLES
    ↓
stable_q <= candidate_q
三个bit一次更新

语义冻结为：

连续观察到同一个完整向量 STABLE_CYCLES 次后接受。

TB必须专门检查 off-by-one：

STABLE_CYCLES - 1

周期时：

不得更新

达到：

STABLE_CYCLES

后：

必须更新
## 12. Filter bypass

和当前 key_filter 一样，支持：

ENABLE = 0

此时：

assign code_stable = code_sync;

不得留下无意义的 counter。

建议用：

generate

使 bypass 综合为纯直通。

## 13. sensor_code_frontend.v

用于把三个基础模块组合成未来可直接接顶层的完整前端。

建议接口：

module sensor_code_frontend #(
    parameter integer SYS_CLK_HZ    = 12000000,
    parameter integer STABLE_MS     = 10,
    parameter integer FILTER_ENABLE = 1,
    parameter integer ACTIVE_HIGH   = 1
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [2:0] sensor_async,

    output wire [2:0] sensor_code_stable,
    output wire [2:0] note_code
);

数据流：

sensor_async
      ↓
ACTIVE_HIGH polarity normalize
      ↓
key_sync #(.WIDTH(3))
      ↓
sensor_code_filter
      ↓
sensor_code_decoder

允许复用现有：

key_sync.v

不得重新复制一个几乎相同的 synchronizer。

## 14. 输入极性

当前模拟设计约定 LM393 输出：

未按 → 0
按下 → 1

所以默认：

ACTIVE_HIGH = 1

但 frontend 必须参数化：

ACTIVE_HIGH = 0 / 1

极性归一化只能发生一次。

推荐：

wire [2:0] sensor_normalized =
    ACTIVE_HIGH ? sensor_async : ~sensor_async;

之后所有模块只处理：

按下 = 1

的统一逻辑。

## 15. CDC要求

三个 LM393 输出对于 FPGA：

都是异步输入。

所以每一位必须经过已有：

key_sync

的两级同步。

流程必须是：

异步输入
 ↓
2FF同步
 ↓
vector filter

不能：

先filter异步输入
再同步

也不能：

LM393 → FPGA逻辑直接用
## 16. 为什么2FF后仍然需要vector filter

两级同步解决的是：

metastability

不是：

多bit同时变化的一致性

三个比较器可能并非同时翻转。

所以：

2FF synchronization

和：

whole-vector stable filter

是两个不同问题。

必须两个都存在。

## 17. tb_sensor_code_decoder.v

必须遍历全部：

$$ 2^3=8 $$

种状态。

自动检查：

000 → 0
001 → 1
010 → 2
011 → 3
100 → 4
101 → 5
110 → 6
111 → 7

输出：

TB_SENSOR_CODE_DECODER: PASS

或：

TB_SENSOR_CODE_DECODER: FAIL

不能只依赖仿真退出码0。

## 18. tb_sensor_code_filter.v

必须覆盖以下情况：

测试	要求
reset	输出 000
000→001	达门限后一次更新
001→111	整个码字一次更新
短毛刺	不更新
多个短暂中间码	不泄漏
candidate改变	计数必须重新开始
回到原stable值	counter清零
ENABLE=0	纯直通
off-by-one	N−1不更新，N更新

其中最关键的测试：

初始 stable = 001

输入 011 持续 < threshold
输入 101 持续 < threshold
输入 111 持续 threshold

结果必须只观察到：

001
111

禁止：

011
101

出现在 code_stable。

## 19. Filter TB允许使用缩短参数

为了避免 ISim 测试过慢，可以例如使用：

SYS_CLK_HZ = 10000
STABLE_MS  = 1

则：

$$ STABLE\_CYCLES=10 $$

这样非常方便精确验证：

9 cycles  → unchanged
10 cycles → updated

这一用例验证的是数字算法，因此不需要强制使用板上 12 MHz。

## 20. tb_sensor_code_frontend.v

需要验证完整：

async input
 ↓
2FF sync
 ↓
vector filter
 ↓
decoder

至少覆盖：

000 → mute
001 → C
011 → E
111 → B
111 → 000

并加入快速中间码：

001
 ↓
011（短）
 ↓
111

检查最终 note 不产生短暂 3。

## 21. Active-low测试

必须至少再运行一次：

ACTIVE_HIGH = 0

确认：

物理111 → logical000
物理110 → logical001
...
物理000 → logical111

并最终正确得到：

0～7 note_code

建议在 project.json 中形成独立仿真：

sensor_code_frontend_high
sensor_code_frontend_low

而不是只靠代码审阅。

## 22. 推荐新增 simulation 项

最终可以加入：

name	top	passPattern
sensor_code_decoder	tb_sensor_code_decoder	TB_SENSOR_CODE_DECODER: PASS
sensor_code_filter	tb_sensor_code_filter	TB_SENSOR_CODE_FILTER: PASS
sensor_code_frontend_high	tb_sensor_code_frontend	TB_SENSOR_CODE_FRONTEND: PASS
sensor_code_frontend_low	tb_sensor_code_frontend	TB_SENSOR_CODE_FRONTEND: PASS

低有效版本通过 generic：

TB_ACTIVE_HIGH=0

覆盖。

## 23. project.json 修改

将新增可综合 RTL 加入：

sources

顺序：

key_sync.v
sensor_code_decoder.v
sensor_code_filter.v
sensor_code_frontend.v
...
finger_piano_top.v

其中被引用模块放在引用者之前。

现有 6 个仿真：

不得修改。

新增 4 个输入基础设施仿真。

因此完整 verify 后：

旧6个 PASS
+
新4个 PASS

全部成立。

## 24. 本阶段不要实例化到顶层

即使新模块全部完成：

sensor_code_frontend

仍然：

finger_piano_top
    × 不实例化

原因是当前：

真实3个输入GPIO尚未由用户最终确认

如果现在添加：

sensor_code_in[2:0]

却不写 LOC，ISE 可能自动分配管脚。

这违反工程已经建立的：

不猜板级约束原则。

## 25. 综合要求

因为这些 RTL 会加入工程 sources，即便当前顶层不实例化，也必须：

纯 Verilog-2001

避免：

logic
always_ff
always_comb
$clog2
SystemVerilog专用语法

要求：

XST 0 errors
XST 0 warnings

现有工程已经开启：

failOnSynthesisWarnings=true

不能用 warning 换进度。

## 26. 不新增新的系统时钟常量

禁止出现：

parameter SYS_CLK_HZ = 12000000

散落在多个 RTL 文件中作为新的真实配置源。

正式实现应继续遵循：

finger_piano_cfg.vh

作为工程时钟真值源。

模块可：

`include "finger_piano_cfg.vh"

parameter integer SYS_CLK_HZ = `SYS_CLK_HZ

保持现有工程风格。

## 27. 建议暂时复用现有滤波参数

本阶段不需要再增加一套：

SENSOR_FILTER_MS
SENSOR_FILTER_COUNTER_WIDTH

默认可以复用：

KEY_STABLE_MS
KEY_FILTER_ENABLE
FP_FILTER_CNT_WIDTH

因为当前两者语义上都是：

人体按压产生的低速数字状态稳定判断。

testbench仍可以通过 parameter 覆盖。

如果以后实测证明三位编码需要不同稳定时间，再单独引入：

SENSOR_CODE_STABLE_MS

本阶段不要提前增加无实测依据的配置项。

## 28. 不要增加“非法编码”逻辑

三位输入总共有：

$$ 8 $$

个状态。

本设计全部有定义：

000 = silence
001～111 = note1～7

因此不存在：

illegal sensor code

不要加入没有意义的：

code_error

或：

invalid_code

逻辑。

## 29. 提交顺序

建议严格分为：

Commit A — Decoder

新增：

sensor_code_decoder.v
tb_sensor_code_decoder.v

所有8个编码 PASS。

Commit B — Atomic Vector Filter

新增：

sensor_code_filter.v
tb_sensor_code_filter.v

重点验证：

multi-bit transition
glitch rejection
candidate reset
off-by-one
bypass
Commit C — Frontend

新增：

sensor_code_frontend.v
tb_sensor_code_frontend.v

复用：

key_sync WIDTH=3

跑：

active-high
active-low

两套。

Commit D — Project Integration

修改：

project.json

将三个 RTL 与新 simulation 正式列入工程。

但：

finger_piano_top.v 不改
UCF 不改

运行：

pwsh -File .\ise.ps1 verify -Project finger_piano

必须完整 PASS。

Commit E — Documentation

新增或更新：

doc/3bit传感器编码输入基础设施开发计划.md
projects/finger_piano/README.md

README只需要增加一节：

3-bit sensor input infrastructure

并明确：

IMPLEMENTED/STANDALONE
NOT_INTEGRATED
BOARD PINS TODO
## 30. 最终验收标准

Agent结束时必须逐项核对：

[ ] sensor_code_decoder 全8码正确
[ ] 000=静音，001~111=note 1~7

[ ] sensor_code_filter 使用一个完整向量candidate
[ ] 不使用三个独立bit滤波作为最终编码滤波
[ ] N-1周期不更新
[ ] N周期更新
[ ] 短暂中间码不会泄漏
[ ] ENABLE=0纯直通

[ ] sensor_code_frontend复用现有key_sync WIDTH=3
[ ] 异步输入先同步、后vector filter
[ ] ACTIVE_HIGH=1测试PASS
[ ] ACTIVE_HIGH=0测试PASS

[ ] 新RTL为Verilog-2001
[ ] XST 0 errors
[ ] XST 0 warnings

[ ] 现有6个仿真零修改且全部PASS
[ ] 新增仿真全部PASS
[ ] 完整 verify PASS

[ ] finger_piano_top端口未修改
[ ] legacy 7-key路径未修改
[ ] note_encoder未删除
[ ] audio_out路径未修改
[ ] UCF未增加猜测管脚

[ ] 未执行program
[ ] 未混入ADC/DAC修改
## 31. 明天才允许做的真正顶层迁移

当用户确认：

LM393 bit0 → FPGA Pin ?
LM393 bit1 → FPGA Pin ?
LM393 bit2 → FPGA Pin ?

之后另开一个独立计划/commit，把：

key_in[6:0]
 ↓
key_sync
 ↓
key_filter
 ↓
note_encoder

替换为：

sensor_code_in[2:0]
 ↓
sensor_code_frontend
 ↓
note_code

然后：

note_code
 ↓
tone_generator

保持后半部分不变。

届时才修改：

finger_piano_top.v
UCF
tb_finger_piano_top.v
README

并释放原七键输入中的四个不再使用的 FPGA I/O。

### 31.1 IO 重分配（与迁移同一次提交完成）

迁移同时改变输入引脚数量与新增外设的引脚需求，因此 IO 必须**一次规划、逐脚确认、单独提交**：

- **释放**：`key_in[1]`~`key_in[6]` 中不再使用的引脚，以及全部 `key_debug[6:0]`（`note_debug` 可保留 0~3 根作观测）。
- **复用 / 新增**：`sensor_async[2:0]` 3 根；属于 P1 的两套 I²C 共 4 根在同一次迁移里落 LOC。
- **可用引脚池（用户 2026-09-15 确认的 38 脚）、当前占用、池与现状的差集、候选分配与硬规则**：见 [`doc/README.md`](./README.md) 的「可用引脚池与 IO 重分配」。

**本阶段（§1~§30 的基础设施）仍然不改 UCF、不加顶层端口**；上面的重分配只属于 §31 的迁移提交，且必须由用户逐脚确认后才允许写 LOC，不得依赖 MAP 自动分配。

## 32. 顶层迁移后的目标结构

最终基础功能应该成为：

三个FSR
  ↓
TL084
  ↓
RC
  ↓
LM393 ×3
  ↓
sensor_code_in[2:0]
  ↓
2FF synchronization
  ↓
atomic 3-bit stable filter
  ↓
000 / 001 ... 111
  ↓
note_code 0...7
  ↓
tone_generator
  ↓
audio_out

之后提高功能再并行接：

ADS1115
   ↓
pressure data

和：

DDS
 ↓
MCP4725

这样各条功能链不会互相绑死。