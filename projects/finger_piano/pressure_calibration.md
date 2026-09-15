# ADS1115 压力通道标定记录(pressure_calibration.md)

> **STATUS = NOT_CALIBRATED**
>
> 本文所有实测字段均为 **TODO**。真实 FSR + TL084 + RC + ADS1115 硬件
> 尚未搭建,以下没有任何一个数值是实测值;禁止 Agent 用模拟数字填充。
> 零点宏 `CFG_PRESSURE_CH0/1/2_ZERO` 当前默认 0(**UNMEASURED DEFAULT**,
> 不是 CALIBRATED),标定完成后才允许修改。

## 1. 模拟前端配置(记录在案,改动后本表全部作废重测)

| 项 | 值 |
|---|---|
| 传感器 | FSR ×3(型号/批次 TODO) |
| Sensor divider RSET | TODO(实际值) |
| TL084 gain | TODO(实际电阻值 / gain) |
| RC 滤波 | TODO(实际 R / C) |
| ADS1115 PGA | 001 / ±4.096 V(`CFG_ADS1115_PGA`) |
| ADS1115 DR | 111 / 860 SPS(`CFG_ADS1115_DR`) |
| ADS1115 VDD | 3.3 V |
| 采集模式 | single-shot,三通道轮询扫描帧(非同步采样) |

任何一个模拟项或 PGA 改变,raw code 与 Volt 的比例都会变,
**本表必须整体重测**。

## 2. 每通道实测记录(全部 TODO)

每个状态(Released / Light / Normal / Strong)**至少重复 20 帧**,
记录 minimum / maximum / average,得到噪声范围;只写一次读数是不够的。
必须保存 **ADS1115 raw code**(不要只写百分比),将来改映射算法时无需重测。

| Channel | 状态 | min (raw) | max (raw) | avg (raw) |
|---|---|---|---|---|
| CH0 | Released | TODO | TODO | TODO |
| CH0 | Light    | TODO | TODO | TODO |
| CH0 | Normal   | TODO | TODO | TODO |
| CH0 | Strong   | TODO | TODO | TODO |
| CH1 | Released | TODO | TODO | TODO |
| CH1 | Light    | TODO | TODO | TODO |
| CH1 | Normal   | TODO | TODO | TODO |
| CH1 | Strong   | TODO | TODO | TODO |
| CH2 | Released | TODO | TODO | TODO |
| CH2 | Light    | TODO | TODO | TODO |
| CH2 | Normal   | TODO | TODO | TODO |
| CH2 | Strong   | TODO | TODO | TODO |

## 3. ZERO_OFFSET 的选取方法(方法已定,数值待实测)

不要简单取 released average。建议工程方法:

```
ZERO = released_max + margin
```

其中 `margin` 由 Released 状态的实测噪声范围(§2 的 max−min)确定,
**必须以实测为依据**。当前 `CFG_PRESSURE_CHx_ZERO` 全部保持 0。

## 4. 明确不做(当前阶段冻结)

- 不做满量程(FULL_SCALE)参数与增益标定(§14);
- 不做 0~4095 归一化(§15);
- 不做电压换算 `V = Code/32768 × 4.096`(§36,只适合报告/调试);
- 不做牛顿(N)换算 —— FSR 非线性且无校准曲线,本项目只称
  "pressure magnitude / 相对按压力度"(§37);
- 不定义 Light/Normal/Strong 阈值分级(§21,阈值未实测);
- 不决定 max/mean/min 压力融合策略(§20,属于音乐控制层)。

## 5. 相关 RTL

| 模块 | 职责 |
|---|---|
| `src/pressure/pressure_frame_capture.v` | 三通道轮询扫描帧原子锁存 |
| `src/pressure/pressure_channel_corrector.v` | 负码钳 0 + 零点减法 + 下溢饱和 |
| `src/pressure/pressure_processor.v` | 三通道包装,pressure_valid 与数据同沿 |

标定流程完成后:更新本文表格 → 修改 `finger_piano_cfg.vh` 的
`CFG_PRESSURE_CHx_ZERO` → 重跑 `verify`。
