# finger_piano_periph_test — ADS1115 / MCP4725 板级诊断工程(P9)

独立、可观测、低风险的 ADC/DAC 诊断 bitstream:把 ADS1115 / MCP4725 的
板级排故从完整电子琴中拆出来,提供**确定输入、确定输出、明确状态脚**
(P9 计划 §0)。

- 器件:`xc3s50an-4-tqg144`;时钟 P57(12 MHz,唯一时钟域);复位 P3
- ADS1115:0x48 / PGA ±4.096 V / 860 SPS / single-shot / CH0-CH1-CH2 轮询
  (与正式工程同一 driver,行为零修改)
- MCP4725:0x60 / Fast Write only / 不写 EEPROM;诊断源 8 kS/s
- 状态脚:**P110 `dbg_alive`**(~1 Hz heartbeat,只证明 FPGA 活着)、
  **P111 `dbg_adc`**(每完成一个三通道帧翻转一次)、**P113 `dbg_error`**
  (sticky,任一 ADC/DAC 错误或 overrun 置位,仅 reset 清除)
- DAC 诊断模式(compile-time `DAC_TEST_MODE`,无 mode pin):
  `0`=0x800 DC、`1`=0x400 DC、`2`=0xC00 DC、`3`=1 kHz / 8 kS/s 八点波形
  (2048, 3316, 3840, 3316, 2048, 780, 256, 780,由
  round(1792·sin(2πk/8)) 离线复核)

## 与正式工程的关系

正式 `finger_piano` 工程(Stage-2)**零修改**。本工程持有一份复用 RTL 的
逐字副本(工具限制 sources 不能越出工程目录):`src/periph/i2c_master.v`、
`src/periph/ads1115_ctrl.v`、`src/periph/mcp4725_ctrl.v`、`src/reset_sync.v`、
`src/finger_piano_cfg.vh` 与 `sim/models/*.v` 均复制自
`projects/finger_piano/` 同名文件——**不构成第二套实现**,禁止在本工程内
单独修改这些文件;如需变更,先改正式工程再同步副本。

## 仿真

```powershell
pwsh -File .\ise.ps1 sim    -Project finger_piano_periph_test          # 全部 7 项
pwsh -File .\ise.ps1 verify -Project finger_piano_periph_test          # 综合+全部仿真+门禁
pwsh -File .\ise.ps1 build  -Project finger_piano_periph_test -Stage implement
pwsh -File .\ise.ps1 build  -Project finger_piano_periph_test -Stage bitstream
```

7 个仿真:normal(0x800)、dac_400、dac_c00、dac_1khz、adc_nack、
dac_nack、heartbeat_real(板上 1 Hz 常量验证)。诊断工程要求
**XST 0 errors / 0 warnings / 0 latches**(P9 §28:最小诊断设计不接受
任何 trim warning 作为常态)。

## 软件准备状态

```
P9 SOFTWARE PREPARATION       = COMPLETE
PERIPH DIAGNOSTIC BITSTREAM   = READY(见下节记录)
BOARD TEST                    = WAITING USER
```

软件阶段到此停止。**烧录必须由用户明确要求并带 `-ConfirmHardwareWrite`**
(本工程任何阶段都不会自动 program);板测完成后是否恢复 Stage-2 ISF
由用户决定(P9 §37)。

## Bitstream 记录

| 项 | 值 |
|---|---|
| DAC_TEST_MODE | 0(0x800 DC;其余模式在仿真侧验证,烧录前按需重构建) |
| run id | bitstream `20260917-004330-18966658`(implement `20260917-004237-e5b4c5b2`,verify `verify-20260917-004113-3c4a791f`) |
| SHA256 | `9654a942b3ca1aab9acc6ac6ddcbbee19768069ecc3096c9254008ef764ae09a` |
| size | 54 738 字节(DRC 0 errors / 0 warnings) |
| device | xc3s50an-4-tqg144 |
| commit | `261eea5`(p9a-d)+ 本文档提交 |

implement 记录(人工阅读 `map.log` / `routed.pad` / `timing.twr`):
MAP/PAR **0 errors / 0 warnings**,317 FF / 455 slices,**9 个 bonded IOB
全部 `LOCATED`** 且与 §3 冻结表逐脚一致(P57/P3/P31/P32/P102/P103/
P110/P111/P113,全部 LVCMOS33),无自动分配 I/O;`TS_clk = 83.33 ns` →
**0 timing errors**(setup/hold/switching 全 0),`All constraints were met.`。
结论边界(P9 §51/§35):这是 DIGITAL IMPLEMENTATION PASS,不构成
I2C BOARD PASS;上升时间/绝对精度必须由示波器/已知输入实测。

## 板测记录表(P9 §34,实测值必须由用户填写)

| 项目 | 理论/预期 | 实测 | 结果 |
|---|---|---|---|
| P110 heartbeat | ~1 Hz 固定慢速翻转 | TODO | TODO |
| P111 ADC toggle | 持续活动 | TODO | TODO |
| P113 error | 正常时 0 | TODO | TODO |
| ADC SCL | ~333 kHz | TODO | TODO |
| DAC SCL | ~333 kHz | TODO | TODO |
| DAC 0x400 VOUT | 低于 0x800 | TODO | TODO |
| DAC 0x800 VOUT | ~VDD/2(3.3 V 时约 1.65 V,仅理论参考) | TODO | TODO |
| DAC 0xC00 VOUT | 高于 0x800 | TODO | TODO |
| DAC 1 kHz | 1 kHz / 8 段阶梯 | TODO | TODO |

板测顺序与判读见 `doc/P9_ADS1115与MCP4725板级诊断工程计划.md` §33;
结论边界(§35):逻辑分析仪解码成功 ≠ I2C 上升时间 PASS;raw code
变化 ≠ ADC 绝对精度 PASS。LM386 / 扬声器不在本阶段。
