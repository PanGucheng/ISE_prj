# finger_piano P8 DDS 数字音量控制基础设施开发计划

> **Status**: IMPLEMENTED / SIMULATED / STANDALONE（audio gain 单元 + pipeline 仿真全过，未接 Stage-2 顶层；PRESSURE→VOLUME = NOT_IMPLEMENTED，FSR = NOT_CALIBRATED）  
> **Scope**: DDS sample → digital gain → MCP4725 的纯数字音量控制基础设施  
> **Depends on**: P1～P7 已完成的软件/数字基础设施；P6 正式 Stage-2 已冻结  
> **Main Stage-2 top/UCF**: 本计划默认不修改  
> **FSR calibration**: NOT_CALIBRATED  
> **Pressure → Volume Mapping**: NOT INCLUDED  
> **Hardware programming**: FORBIDDEN  
> **Acceptance**: unit simulation + standalone pipeline simulation + full regression + synthesis/resource review

---

## 0. 当前前提

当前正式工程已经具备：

```text
sensor_async[2:0]
      ↓
sensor_code_frontend
      ↓
note_code[2:0]
      ↓
DDS
      ↓
MCP4725
```

以及独立压力链：

```text
ADS1115
   ↓
pressure_processor
   ↓
pressure_ch0/1/2
```

当前 12-pin Stage-2 顶层没有 pressure 数据的真实硬件消费者，因此 P5 pressure datapath 在最终综合中会被 XST 合法 trim；该状态已经过 warning allowlist 审核并冻结。

P8 的目标不是立即决定 `pressure → volume`，而是先建立稳定、可验证的：

```text
DDS sample
   ↓
digital gain
   ↓
MCP4725
```

这样后续 FSR 实物标定完成后，只需要新增 `pressure → volume_level` 映射，而不用重新设计 DDS 音量数学。

---

## 1. 本计划边界

P8 只完成：

```text
12-bit unsigned DDS sample
          ↓
以 2048 为中心的数字增益
          ↓
12-bit unsigned DAC sample
```

本阶段明确不完成：

```text
FSR raw → Light/Normal/Strong
FSR raw → gain
三通道压力融合策略
真实音量标定
LM386 增益调整
扬声器响度标定
```

以上必须等待实物数据。

---

## 2. 新增模块

新增：

```text
projects/finger_piano/src/audio/audio_gain_12bit.v
```

推荐接口：

```verilog
module audio_gain_12bit (
    input  wire [11:0] sample_in,
    input  wire [2:0]  volume_level,
    output wire [11:0] sample_out
);
```

第一版保持纯组合逻辑，不增加第二时钟域，不增加握手协议。

---

## 3. 音量等级冻结

第一版冻结：

```text
volume_level = 0..7
```

| level | 数字增益 |
|---:|---:|
| 0 | 0/8 |
| 1 | 1/8 |
| 2 | 2/8 |
| 3 | 3/8 |
| 4 | 4/8 |
| 5 | 5/8 |
| 6 | 6/8 |
| 7 | 7/8 |

说明：

- level 0 = 数字静音；
- level 7 = 第一版最大数字音量；
- 不定义 Light / Normal / Strong 对应哪一级；
- 不把 level 7 声称为“扬声器最大音量”。

---

## 4. 必须围绕 DAC 中点缩放

当前音频数据中心：

```text
center = 2048
DDS range = 256..3840
```

因此数字增益必须作用在：

```text
delta = sample_in - 2048
```

数学定义：

```text
sample_out = 2048 + delta × volume_level / 8
```

禁止直接：

```text
sample_out = sample_in × gain
```

否则 DAC 直流中心会一起移动。

---

## 5. signed 与位宽规则

内部必须显式处理 signed/unsigned：

```text
sample_in (12-bit unsigned)
      ↓
显式扩位
      ↓
delta (signed)
      ↓
scaled_delta (signed)
      ↓
2048 + scaled_delta
      ↓
saturate to 0..4095
```

Verilog-2001 下禁止依赖模糊的隐式 signed 扩展。TB 必须同时覆盖正半波和负半波。

---

## 6. 不使用通用乘法器

XC3S50AN 资源有限，第一版禁止最终综合依赖通用运行时乘法器：

```text
delta * volume_level
```

推荐使用 shift/add：

```text
0: 0
1: delta/8
2: delta/4
3: delta/4 + delta/8
4: delta/2
5: delta/2 + delta/8
6: delta/2 + delta/4
7: delta - delta/8
```

负数右移必须是 arithmetic right shift。

资源目标：

```text
multiplier usage = 0
```

---

## 7. 饱和策略

最终结果必须限制到：

```text
0..4095
```

推荐：

```text
result < 0     → 0
result > 4095  → 4095
otherwise      → result[11:0]
```

即使当前 DDS 正常输入不会越界，模块本身也必须有确定边界行为。

---

## 8. 静音语义

当：

```text
volume_level = 0
```

任意 `sample_in` 都必须：

```text
sample_out = 2048
```

禁止输出 0，因为 0 是 DAC 近地电压，不是以 2048 为中心的音频静音。

---

## 9. 新增 Unit TB

新增：

```text
projects/finger_piano/sim/tb_audio_gain_12bit.v
```

必须打印：

```text
TB_AUDIO_GAIN_12BIT: PASS
```

Unit TB 至少覆盖：

- `sample_in=2048` 时 level 0..7 均输出 2048；
- level 0 对多个输入均输出 2048；
- 正半波：2560 / 3072 / 3840；
- 负半波：256 / 1024 / 1536；
- level 0..7 全覆盖；
- 端点 0 / 4095 不 wrap；
- 对称输入 `2048±d` 的输出仍围绕 2048 对称；
- 增益随 level 单调增加。

允许由 shift truncation 导致明确的 ±1 LSB 对称误差，但规则必须在 TB 和 RTL 中一致。

---

## 10. 独立参考模型

TB 中用独立整数参考模型计算：

```text
delta = sample - 2048
expected = 2048 + trunc(delta * level / 8)
```

必须与 RTL 的负数截断规则一致。禁止用 real 四舍五入制造与 RTL 不同的参考答案。

---

## 11. 不修改 DDS 核心

P8 不修改：

```text
dds_sine_generator.v
sine_lut_12bit.v
dds_frequency_table.md
phase_inc
8 kS/s cadence
```

数字音量模块位于 DDS 后面。

---

## 12. 新增 standalone gain pipeline

建议新增：

```text
projects/finger_piano/src/audio/dds_gain_mcp4725_pipeline.v
```

结构：

```text
note_code
   ↓
DDS
   ↓
audio_gain_12bit
   ↓
MCP4725 controller
```

输入至少包括：

```text
clk
rst_n
note_code[2:0]
volume_level[2:0]
```

P8 第一版不要直接替换已验证的 `dds_mcp4725_pipeline.v`；保留 P4 baseline。

---

## 13. 新增 Pipeline TB

新增：

```text
sim/tb_dds_gain_mcp4725_pipeline.v
```

复用现有：

```text
sim/models/mcp4725_model.v
```

至少覆盖：

```text
mute
C4 level 1
C4 level 4
C4 level 7
A4 level 2
A4 level 6
B4 level 7
```

对 MCP4725 捕获样点逐点比对：

```text
expected_dds
  ↓
expected_gain
  ↓
expected_dac_code
```

验收目标：

```text
Mismatch = 0
Overrun = 0
I2C error = 0
EEPROM writes = 0
```

---

## 14. 音量变化不能改变频率

固定 note 时切换：

```text
level 1 → 4 → 7
```

必须满足：

```text
phase increment 不变
8 kS/s cadence 不变
音频频率不变
```

只允许振幅变化。

音量变化不得重启 DDS phase，也不得重启 sample divider。

---

## 15. 两种 mute 必须区分

### note_code = 0
DDS 自身输出 2048。

### volume_level = 0
gain 层将任意 DDS sample 缩到 2048。

两者最终 DAC 结果相同，但 TB 必须分别覆盖。

---

## 16. MCP4725 协议冻结

继续保持：

```text
Fast Write only
no EEPROM
8 kS/s input
open-drain I2C
```

P8 不重写 `mcp4725_ctrl.v`。

---

## 17. 不连接 pressure

P8 中 `volume_level` 只作为 standalone pipeline 的显式输入。

禁止：

```text
pressure_ch0/1/2 → volume_level
```

也禁止猜测任何 pressure 阈值。

---

## 18. 正式 Stage-2 不切换

本计划默认不修改：

```text
finger_piano_stage2_top.v
project.json top
constraints/finger_piano.ucf
```

P8 完成状态应为：

```text
IMPLEMENTED / SIMULATED / STANDALONE
```

---

## 19. Warning allowlist 规则

正式 `finger_piano` 当前 warning allowlist 已冻结。

P8 不允许自动修改它。

如果新增 source 导致：

```text
warning 数量变化
warning path 变化
warning class 变化
```

必须：

```text
STOP → 人工审核
```

禁止为了“全绿”自动调整 expected count。

---

## 20. 资源综合

为了得到真实 `audio_gain_12bit` 资源，建议用独立临时 synthesis top 或独立小测试工程。

不要依赖正式 Stage-2 synth 估算未实例化模块资源，因为未消费逻辑可能被 trim。

至少记录：

```text
FF
LUT
Slices
Multiplier usage
```

要求：

```text
Multiplier usage = 0
```

---

## 21. Full regression

完成 P8 后运行：

```powershell
pwsh -File .\ise.ps1 verify -Project finger_piano
```

要求：

```text
现有全部 simulation PASS
unexpected synthesis warnings = 0
当前 warning allowlist 不变
```

---

## 22. 文档更新

更新：

```text
projects/finger_piano/README.md
doc/README.md
本 P8 计划
```

完成后状态：

```text
AUDIO GAIN RTL                IMPLEMENTED
AUDIO GAIN UNIT SIM           PASS
DDS→GAIN→MCP PIPELINE         SIMULATED / STANDALONE
PRESSURE→VOLUME MAPPING       NOT_IMPLEMENTED
FSR CALIBRATION               NOT_CALIBRATED
BOARD AUDIO VOLUME            NOT_TESTED
LM386                         NOT_TESTED
SPEAKER                       NOT_TESTED
```

---

## 23. 推荐提交序列

### P8-A — audio_gain RTL

新增：

```text
src/audio/audio_gain_12bit.v
```

### P8-B — Unit TB

新增：

```text
sim/tb_audio_gain_12bit.v
```

### P8-C — Gain Pipeline

新增：

```text
src/audio/dds_gain_mcp4725_pipeline.v
sim/tb_dds_gain_mcp4725_pipeline.v
```

### P8-D — Resource / Regression

运行 standalone synthesis/resource + full `finger_piano verify`。

### P8-E — Docs Closeout

更新 README / doc/README / P8 状态。

---

## 24. Agent 停止条件

出现任一项立即停止：

```text
unit TB FAIL
pipeline TB FAIL
现有回归 FAIL
新增 synthesis warning
当前 allowlist count 变化
出现 multiplier
DDS frequency/cadence 被改变
MCP4725 protocol 被改变
需要修改 UCF
需要 program
```

---

## 25. 严禁行为

Agent 不得：

```text
猜 FSR 阈值
猜 ZERO_OFFSET
把 pressure 接到 volume
修改 Stage-2 UCF
修改最终 pin map
自动扩大 warning allowlist
使用 KEEP/DONT_TOUCH 掩盖问题
增加第二时钟域
使用 DAC code=0 作为静音
修改 DDS phase increment
执行 JTAG/ISF program
```

---

## 26. 最终验收清单

```text
[ ] audio_gain_12bit.v 已创建
[ ] 以 2048 为中心缩放
[ ] volume_level = 0..7
[ ] level 0 输出恒为 2048
[ ] 全部 8 个 level 已测试
[ ] 正半波 PASS
[ ] 负半波 PASS
[ ] 对称性 PASS
[ ] 端点/饱和 PASS
[ ] 无通用乘法器
[ ] 无第二时钟域

[ ] tb_audio_gain_12bit PASS
[ ] dds_gain_mcp4725_pipeline 已创建
[ ] pipeline TB PASS
[ ] volume change 不改变 DDS frequency
[ ] volume change 不改变 8 kS/s cadence
[ ] MCP4725 Fast Write 行为保持
[ ] EEPROM write = 0
[ ] overrun = 0
[ ] mismatch = 0

[ ] 正式 Stage-2 top 未修改
[ ] 正式 UCF 未修改
[ ] warning allowlist 未自动修改
[ ] full verify PASS
[ ] unexpected synthesis warnings = 0

[ ] PRESSURE→VOLUME 仍为 NOT_IMPLEMENTED
[ ] FSR 仍为 NOT_CALIBRATED
[ ] 未执行 program
```

---

## 27. Agent 执行提示

> 按本计划完成 P8。目标是建立 `DDS sample → audio_gain_12bit → MCP4725` 的 standalone 数字音量基础设施，不得实现 pressure→volume 映射。音量必须围绕 DAC 中点 2048 缩放，使用 3-bit `volume_level=0..7` 与 shift/add，不使用通用乘法器。先完成 Unit TB，再完成 DDS→gain→MCP4725 Pipeline TB，最后 full regression。正式 Stage-2 top/UCF 不动，166-warning allowlist 不得自动修改；任何新 warning 或 count drift 必须停止并报告。禁止任何 JTAG/ISF program。
