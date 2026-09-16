# finger_piano P7 FPGA 启动与时钟分频板级验证计划

> **Status**: SOFTWARE PREPARATION COMPLETE；HARDWARE（用户 2026-09-16 授权「测试与 ISF」）已执行 probe PASS + JTAG 易失配置 PASS + ISF program/verify VERIFIED；**POWER-CYCLE PERSISTENT BOOT = NOT_TESTED**、板测频率/reset 待用户实测，`userDesignFunctional = NOT_TESTED`
> **Scope**: FPGA basic bring-up / clock characterization / divider measurement / persistent boot
> **Depends on**: P6 COMPLETE
> **Main finger_piano RTL**: FROZEN
> **Main finger_piano UCF**: FROZEN
> **Hardware programming**: 只有用户明确授权后才执行
> **Board measurements**: USER + oscilloscope / frequency counter
> **Purpose**: 在验证 ADS1115、MCP4725、LM386 之前，先独立证明 FPGA、12 MHz 时钟、分频器和 ISF 冷启动工作正确

---

## 0. P7 开始前先完成一次 P6 文档一致性修复

本阶段第一个 commit 只允许修文档和过时注释，不修改功能 RTL。

需要修正：

- `doc/P6B最终顶层与UCF迁移实施计划.md`
  - `READY TO IMPLEMENT`
  - → `P6B COMPLETE`
- `doc/README.md §12`
  - 删除“P6B 等待引脚确认”的旧 blocker；
  - 删除 P76/P77、P78/P79/P90 的旧候选方案；
  - 改为最终冻结 12-pin map。
- `doc/README.md §10.5`
  - 从：
    `XST warnings = 0`
  - 改为：
    `unexpected XST warnings = 0`
  - 明确 `synthesisWarningAllowlist` 中经过审阅的 trim warning 是当前唯一例外。
- `projects/finger_piano/AGENTS.md`
  - 删除“Stage-2 引脚仍待确认”的过时内容；
  - 写入 P6 COMPLETE 和最终 pin map 的入口。
- `src/system/finger_piano_system.v`
  - 只更新文件头过时注释：
    `project top still legacy / P6B pending`
    → 当前 Stage-2 已正式切换。
- `projects/finger_piano/README.md`
  - 把 legacy 目录树和模块关系明确标记为历史，或同步 Stage-2 当前结构。

本 commit 后：

```text
P6 documentation state = internally consistent
````

然后再进入 P7。

---

# 1. 不使用正式 Stage-2 工程做基础时钟测试

禁止为了测试时钟临时修改：

```text
projects/finger_piano/project.json
projects/finger_piano/constraints/finger_piano.ucf
finger_piano_stage2_top
```

原因：

正式 Stage-2 已经是 P6 冻结成果。

如果为了时钟测试不断：

```text
切 top
改 UCF
测完再切回来
```

会产生无意义的回归风险。

因此 P7 必须建立独立诊断工程。

---

# 2. 不复用 `xc3s50an_smoke`

仓库已有：

```text
projects/xc3s50an_smoke
```

它是工具链 smoke test：

```text
synthetic 50 MHz
无真实 LOC
自动布局
仅用于验证 ISE 流程
```

它明确不是开发板设计。

因此禁止把它改造成 P7 板测工程。

---

# 3. 新建独立工程

新增：

```text
projects/finger_piano_clock_test/
├── project.json
├── README.md
├── src/
│   └── clock_test_top.v
├── constraints/
│   └── clock_test.ucf
└── sim/
    └── tb_clock_test_top.v
```

器件：

```text
xc3s50an-4-tqg144
```

正式 top：

```text
clock_test_top
```

---

# 4. P7 只使用 5 个已经确认的引脚

最终：

| Signal       |  LOC | 用途                      |
| ------------ | ---: | ----------------------- |
| `clk`        |  P57 | 12 MHz board oscillator |
| `rst_n`      |   P3 | reset                   |
| `ref_2mhz`   | P110 | 精确 ÷6 基准                |
| `ref_100khz` | P111 | 精确 ÷120 基准              |
| `ref_1khz`   | P113 | 精确 ÷12000 基准            |

全部：

```text
IOSTANDARD = LVCMOS33
VCCO = 3.3 V
```

这五个引脚均已经在 P6B 中确认，不引入任何新 LOC。

---

# 5. 为什么选择这三个频率

输入标称：

```text
fclk = 12 MHz
```

测试输出：

```text
2 MHz
100 kHz
1 kHz
```

其中 2 MHz 直接对应课程资料中的基础分频时基。

三个频率跨度较大：

```text
12 MHz
 ↓ ÷6
2 MHz

12 MHz
 ↓ ÷120
100 kHz

12 MHz
 ↓ ÷12000
1 kHz
```

因此可以同时检查：

* 小计数器；
* 中等计数器；
* 较长计数器；
* 示波器/频率计在不同频段的一致性。

---

# 6. RTL实现原则

所有逻辑仍然：

```verilog
always @(posedge clk or negedge rst_n)
```

只有：

```text
clk = P57
```

一个时钟域。

三个测试输出绝不能被其它逻辑当作时钟。

---

# 7. 精确分频方法

对于 50% 方波：

```text
fout = fclk / (2 × N)
```

因此：

| 输出      | N（每 N 个 clk 翻转） | 完整周期输入 clk 数 |
| ------- | --------------: | -----------: |
| 2 MHz   |               3 |            6 |
| 100 kHz |              60 |          120 |
| 1 kHz   |            6000 |        12000 |

理论值：

```text
P110 ref_2mhz   = 2,000,000 Hz
P111 ref_100khz =   100,000 Hz
P113 ref_1khz   =     1,000 Hz
```

这些值在“输入恰好为 12 MHz”的假设下不存在整数取整误差。

---

# 8. 推荐寄存器位宽

避免无意义大计数器：

```text
2 MHz:
N = 3
counter width = 2 bit

100 kHz:
N = 60
counter width = 6 bit

1 kHz:
N = 6000
counter width = 13 bit
```

不要使用统一 24-bit counter。

目标之一是让这个诊断设计：

```text
0 synthesis warnings
```

而不是产生新的 trim warning。

---

# 9. Reset 行为

`rst_n = 0`：

```text
全部 counter = 0
ref_2mhz   = 0
ref_100khz = 0
ref_1khz   = 0
```

释放后，从完整半周期重新开始。

因此板测时也能检查：

```text
P3 reset input
```

是否工作。

---

# 10. 新增行为仿真

`tb_clock_test_top.v` 必须验证：

### reset

拉低 reset：

```text
3 outputs == 0
```

### 2 MHz

相邻翻转必须严格相隔：

```text
3 input clocks
```

完整周期：

```text
6 input clocks
```

### 100 kHz

相邻翻转：

```text
60 clocks
```

完整周期：

```text
120 clocks
```

### 1 kHz

相邻翻转：

```text
6000 clocks
```

完整周期：

```text
12000 clocks
```

要求明确：

```text
TB_CLOCK_TEST_TOP: PASS
```

---

# 11. 独立工程 verification policy

`project.json` 建议：

```text
constraintsReviewed = true
expectImplementationBlocked = false
failOnSynthesisWarnings = true
```

P7 工程：

```text
不使用 finger_piano 的 166-warning allowlist
```

要求真正：

```text
XST errors   = 0
XST warnings = 0
latches      = 0
```

---

# 12. P7 UCF

活动约束只包含：

```text
P57   clk
P3    rst_n
P110  ref_2mhz
P111  ref_100khz
P113  ref_1khz
```

以及：

```text
TS_clk = PERIOD 83.33 ns
```

不得：

```text
自动分配 LOC
增加 OFFSET 假装板级时序已认证
把 ref_2mhz 当内部 clock
```

---

# 13. 软件侧验收

执行：

```powershell
pwsh -File .\ise.ps1 verify -Project finger_piano_clock_test
```

要求：

```text
Overall PASS
simulation PASS
synthesis 0 errors
synthesis 0 warnings
synthesis 0 latches
```

然后：

```powershell
pwsh -File .\ise.ps1 build -Project finger_piano_clock_test -Stage implement
```

人工读取：

```text
timing.twr
```

要求 83.33 ns 时钟满足。

---

# 14. 生成诊断 bitstream

然后：

```powershell
pwsh -File .\ise.ps1 build -Project finger_piano_clock_test -Stage bitstream
```

记录：

```text
run id
bitstream path
SHA-256
target device
file size
```

本阶段到这里为止：

```text
READY_FOR_BOARD_TEST
```

Agent 不得因为 bitstream 已生成而自行 program。

---

# 15. 同时准备 Stage-2 恢复 bitstream

为了诊断 ISF 测试之后能方便恢复正式工程，建议同时对：

```text
finger_piano
```

运行一次：

```powershell
pwsh -File .\ise.ps1 build -Project finger_piano -Stage bitstream
```

记录：

```text
Stage-2 bitstream SHA-256
commit = cc82f73 or later doc-only equivalent
```

但：

```text
DO NOT PROGRAM
```

这只是 recovery artifact。

---

# 16. 第一次硬件动作：只读 probe

用户明确开始板测后，先执行：

```text
probe
```

必须确认：

```text
cableDetected = PASS
jtagChainDetected = PASS
deviceMatched = PASS
XC3S50AN
```

probe 是只读的。

---

# 17. 第二次硬件动作：JTAG 易失配置

必须得到用户明确授权后才能：

```text
program -Mode Jtag
```

写入：

```text
finger_piano_clock_test
```

诊断 bitstream。

这是：

```text
VOLATILE
```

不能改变内部 ISF 内容。

---

# 18. JTAG 配置后首先看三个输出

示波器建议：

```text
P110 → CH1
P111 → CH2
P113 → CH3（若仪器支持）
GND  → board common GND
```

测：

| Pin  | Expected f | Expected period |
| ---- | ---------: | --------------: |
| P110 |      2 MHz |          500 ns |
| P111 |    100 kHz |           10 µs |
| P113 |      1 kHz |            1 ms |

占空比目标：

```text
约 50 %
```

---

# 19. 先不要用逻辑分析仪判定“高精度”

频率准确度优先使用：

```text
frequency counter
```

或示波器的 frequency measurement / period averaging。

廉价逻辑分析仪本身的采样晶振可能有较大误差，因此：

> 可以判断波形存在，但不适合拿来证明 ppm 或 0.01% 级精度。

---

# 20. 分频器正确性不只看绝对频率

这三路来自同一个 12 MHz 时钟，因此还必须计算：

```text
f_2MHz / f_100kHz
```

理论：

```text
20
```

以及：

```text
f_100kHz / f_1kHz
```

理论：

```text
100
```

这个比例检查可以把公共晶振绝对误差与 divider 错误区分开。

---

# 21. 反推真实 FPGA 输入时钟

分别计算：

```text
fclk_2m   = measured_ref_2mhz   × 6
fclk_100k = measured_ref_100khz × 120
fclk_1k   = measured_ref_1khz   × 12000
```

三个值应该在测量仪器精度允许范围内相互一致。

例如：

```text
ref_1khz = 999.98 Hz

=> fclk ≈ 11,999,760 Hz
```

---

# 22. 记录绝对时钟误差

以三个估计值的合理平均值作为：

```text
fclk_measured
```

计算：

```text
clock_error_percent =
(fclk_measured - 12,000,000)
/
12,000,000
× 100%
```

同时记录：

```text
clock_error_ppm
```

但没有晶振 datasheet 和仪器精度依据时：

> 不自行发明 ±20 ppm、±50 ppm 之类的合格标准。

---

# 23. 与课程 1% 指标关联

后续音阶实际误差由：

```text
时钟基准误差
+
数字频率量化误差
```

共同决定。

当前 legacy 分频算法理论量化误差约：

```text
≤ 0.0103 %
```

DDS 数字理论误差更小。

因此 P7 应把实测 12 MHz 偏差记录下来，后续实际七音验收使用：

```text
真实时钟值
```

重新估算，而不是继续假定理想 12.000000 MHz。

---

# 24. Reset 实物检查

在 JTAG clock-test 正常后：

```text
rst_n 拉低
```

要求：

```text
P110 = 0
P111 = 0
P113 = 0
```

释放：

```text
三个方波重新开始
```

这样同时验证：

```text
P3
外部 reset 电路
FPGA reset 行为
```

---

# 25. JTAG板测结果状态

如果成功，只允许更新为：

```text
FPGA JTAG configuration     PASS
12 MHz clock path           OBSERVED
clock divider               MEASURED / PASS
reset input                 PASS
```

此时：

```text
power-cycle persistent boot
```

仍然：

```text
NOT_TESTED
```

---

# 26. 第三次硬件动作：写内部 ISF

只有用户再次明确授权后才能：

```text
program -Mode Isf
```

写入同一个：

```text
clock_test bitstream
```

工具必须继续使用已冻结的：

```text
erase
→ program
→ in-step verify
```

流程。

Spartan-3AN 内部 Flash 自启动模式要求：

```text
M[2:0] = 011
```

并满足相应供电条件。

---

# 27. ISF 成功仍不等于冷启动成功

如果工具报告：

```text
Programming completed
Verification completed successfully
```

只能记录：

```text
ISF programmingVerified = VERIFIED
```

不能立即记录：

```text
persistent boot = PASS
```

必须实际断电。

---

# 28. 冷启动测试

ISF 写入并 verify 后：

1. 完全关闭板卡电源；
2. 避免 USB/JTAG 对板卡产生反向供电；
3. 等待约数秒；
4. 不运行任何 JTAG 命令；
5. 重新上电；
6. 直接观察 P110/P111/P113。

如果三个测试波形自动出现：

```text
FPGA did boot from nonvolatile configuration
```

---

# 29. 冷启动必须重复

建议：

```text
5 次
```

完整 power cycle。

记录：

| Cycle | P110 2MHz | P111 100k | P113 1k | Result |
| ----- | --------- | --------- | ------- | ------ |
| 1     |           |           |         |        |
| 2     |           |           |         |        |
| 3     |           |           |         |        |
| 4     |           |           |         |        |
| 5     |           |           |         |        |

不要只成功一次就结束。

---

# 30. 可选：测启动延迟

如果示波器方便，可以：

```text
CH1 = 3.3 V supply
CH2 = P110 ref_2mhz
```

单次触发测：

```text
power valid
→
first ref_2mhz activity
```

这只是 characterization。

当前课程设计不要求严格 boot-time 上限，因此：

```text
记录数值
```

即可，不自行发明 PASS 门限。

---

# 31. P7最终状态定义

如果 JTAG、分频和 ISF 冷启动全部完成：

```text
FPGA JTAG CONFIGURATION       PASS
FPGA ISF PROGRAM/VERIFY       VERIFIED
POWER-CYCLE PERSISTENT BOOT   PASS

P57 CLOCK PATH                PASS
2 MHz DIVIDER                 PASS
100 kHz DIVIDER               PASS
1 kHz DIVIDER                 PASS

MEASURED FPGA CLOCK           <actual value>
CLOCK ERROR                   <actual % / ppm>

STAGE2 FINGER PIANO BOARD     NOT_TESTED
ADS1115 BOARD                 NOT_TESTED
MCP4725 ANALOG                NOT_TESTED
FSR                           NOT_CALIBRATED
LM386                         NOT_TESTED
SPEAKER                        NOT_TESTED
```

禁止因为 clock-test PASS 就把整个 finger_piano 标成 BOARD PASS。

---

# 32. 一个重要的恢复提醒

一旦把：

```text
clock_test
```

写进内部 ISF，

板卡下一次上电启动的就是诊断设计，而不是：

```text
finger_piano_stage2_top
```

这是预期行为，不是故障。

P7 完成后：

> 是否把正式 Stage-2 bitstream 写回 ISF，必须再次由用户明确决定。

Agent 不得自动恢复或自动再次写 Flash。

---

# 33. Agent不得做的事情

* 不修改正式 `finger_piano` top；
* 不修改正式 Stage-2 UCF；
* 不改 P6 的 166-warning allowlist；
* 不把 `ref_2mhz` 当内部时钟；
* 不修改 ISE programmer 流程；
* 不自动 JTAG program；
* 不自动 ISF program；
* 不根据仿真编造实测频率；
* 不把诊断设计 PASS 扩大为 Stage-2 BOARD PASS。

---

# 34. 推荐提交序列

### P7-A — P6 documentation consistency cleanup

只修前述 stale docs/comments。

### P7-B — clock-test project

加入：

```text
projects/finger_piano_clock_test
```

RTL + UCF + project config。

### P7-C — clock-test simulation

加入 TB，验证：

```text
÷6
÷120
÷12000
reset
```

### P7-D — verify / implement / bitstream

要求：

```text
0 synthesis warnings
simulation PASS
implementation PASS
timing constraints met
bitstream generated
```

并记录 SHA256。

到这里 Agent 自动工作结束：

```text
P7 SOFTWARE PREPARATION = COMPLETE
HARDWARE TEST = WAITING USER
```

### P7-E — JTAG hardware measurement

只有用户明确授权后执行。

实测数据由用户提供/确认后写文档。

### P7-F — ISF persistent boot

再次由用户明确授权。

完成 5 次 power-cycle 后写入最终结果。

---

# 35. P7 软件侧最终验收

```text
[ ] P6 stale documentation 已清理
[ ] 正式 finger_piano project 未被修改功能/约束
[ ] xc3s50an_smoke 未被改成板级工程

[ ] finger_piano_clock_test 独立存在
[ ] clk = P57
[ ] rst_n = P3
[ ] ref_2mhz = P110
[ ] ref_100khz = P111
[ ] ref_1khz = P113

[ ] ÷6 simulation PASS
[ ] ÷120 simulation PASS
[ ] ÷12000 simulation PASS
[ ] reset simulation PASS

[ ] synthesis errors = 0
[ ] synthesis warnings = 0
[ ] latches = 0
[ ] implementation PASS
[ ] timing constraint PASS
[ ] bitstream generated
[ ] SHA256 recorded

[ ] 未执行任何 program
```

---

# 36. P7 实物验收表

用户实测后填写：

| 项目                       |            理论 |   实测 |   误差 |
| ------------------------ | ------------: | ---: | ---: |
| P110                     |  2,000,000 Hz | TODO | TODO |
| P111                     |    100,000 Hz | TODO | TODO |
| P113                     |      1,000 Hz | TODO | TODO |
| inferred clock from P110 | 12,000,000 Hz | TODO | TODO |
| inferred clock from P111 | 12,000,000 Hz | TODO | TODO |
| inferred clock from P113 | 12,000,000 Hz | TODO | TODO |

以及：

```text
JTAG CONFIG               TODO
RESET                      TODO
ISF PROGRAM/VERIFY         TODO
POWER-CYCLE #1             TODO
POWER-CYCLE #2             TODO
POWER-CYCLE #3             TODO
POWER-CYCLE #4             TODO
POWER-CYCLE #5             TODO
```

任何 TODO 都不得由 Agent 自行填写。
