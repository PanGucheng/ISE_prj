# tone_dac_demo — 3-bit 传感器方波与 DDS+MCP4725 双音频输出独立验证工程

## 1. 工程目的

本工程是针对手指钢琴课程设计建立的独立、隔离的验证工程。目标是：
由 3-bit 数字编码输入 `sensor_async[2:0]`（`000~111`）产生唯一的 `note_code[2:0]`，并行驱动：
1. **单音方波音频发生器**（`tone_generator`）通过 `P110` 输出 50% 占空比推挽方波；
2. **DDS 正弦波音频发生器 + MCP4725 DAC 控制器链路**（`dds_mcp4725_pipeline`）通过独立 I²C（`P102/P103`）输出 12 位、8 kS/s 模拟正弦波。

通过示波器或测量仪器可直观比对同一音符编码下方波与正弦波的基频一致性。

## 2. 基线与工程关系

- **基线 Commit**：`fb3f2abf064708957b48ef2249387faae78f0981` (2026-09-17)
- **工程隔离原则**：本工程为完全独立的工程目录，不修改任何现有的 `finger_piano`、`finger_piano_periph_test`、`finger_piano_od_test` 文件。
- **复用源码清单**（来自 `projects/finger_piano` 快照副本）：
  - 配置真值源：`src/finger_piano_cfg.vh`
  - 同步与复位：`src/reset_sync.v`、`src/key_sync.v`
  - 输入前端：`src/input/sensor_code_decoder.v`、`src/input/sensor_code_filter.v`、`src/input/sensor_code_frontend.v`
  - 方波音频：`src/tone_generator.v`
  - DDS 与 DAC：`src/audio/sine_lut_12bit.v`、`src/audio/dds_sine_generator.v`、`src/audio/dds_mcp4725_pipeline.v`、`src/periph/i2c_master.v`、`src/periph/mcp4725_ctrl.v`
  - 仿真模型：`sim/models/mcp4725_model.v`

## 3. 3-bit 音符编码表

| 3-bit 码字 | 音符 | 标称频率 (Hz) | 方波状态 | MCP4725 正弦输出状态 |
|:---:|:---:|:---:|:---:|:---:|
| `000` | 静音 | - | 低电平 (0) | 输出中点偏置 (代码 2048) |
| `001` | C4 | 261.62 | 261.62 Hz 方波 | 261.62 Hz 正弦波 |
| `010` | D4 | 293.67 | 293.67 Hz 方波 | 293.67 Hz 正弦波 |
| `011` | E4 | 329.63 | 329.63 Hz 方波 | 329.63 Hz 正弦波 |
| `100` | F4 | 349.23 | 349.23 Hz 方波 | 349.23 Hz 正弦波 |
| `101` | G4 | 391.99 | 391.99 Hz 方波 | 391.99 Hz 正弦波 |
| `110` | A4 | 440.00 | 440.00 Hz 方波 | 440.00 Hz 正弦波 |
| `111` | B4 | 493.88 | 493.88 Hz 方波 | 493.88 Hz 正弦波 |

## 4. 引脚分配表与 Stage-2 冻结约束关系

| 信号名 | LOC | 方向 | IOSTANDARD | 与 Stage-2 冻结关系 | 说明 |
|---|---|---|---|---|---|
| `clk` | `P57` | input | LVCMOS33 | 完全一致 | 12 MHz 有源晶振 (唯一时钟源) |
| `rst_n` | `P3` | input | LVCMOS33 | 完全一致 | 外部低有效复位 (RC/上拉) |
| `sensor_async[0]` | `P28` | input | LVCMOS33 | 完全一致 | LM393 CH0 (权重 1) |
| `sensor_async[1]` | `P29` | input | LVCMOS33 | 完全一致 | LM393 CH1 (权重 2) |
| `sensor_async[2]` | `P30` | input | LVCMOS33 | 完全一致 | LM393 CH2 (权重 4) |
| `square_out` | `P110` | output | LVCMOS33 | **临时占用** | 最终工程为 `note_debug[0]`，此处输出推挽方波 |
| `dac_i2c_scl` | `P102` | inout | LVCMOS33 | 完全一致 | MCP4725 独立 I²C SCL (开漏，外部 4.7kΩ 上拉) |
| `dac_i2c_sda` | `P103` | inout | LVCMOS33 | 完全一致 | MCP4725 独立 I²C SDA (开漏，外部 4.7kΩ 上拉) |

> **特别声明**：
> - ADS1115 引脚 `P31`、`P32` 保持完全空闲，不在本工程约束中分配。
> - `P111`、`P113` 保持完全空闲。
> - 时钟周期约束：`TS_clk = PERIOD 83.33 ns HIGH 50%`。

## 5. 软件与仿真记录

- **Stage A (Scaffold)**: `ise.ps1 check -Project tone_dac_demo -Stage synth` PASS
- **Stage B (Input + Square)**: PASS
  - `sensor_code_frontend`: run `sim-20260921-135942-db901a7e` (PASS)
  - `tone_generator_12m`: run `sim-20260921-135955-eb4c4a75` (PASS)
- **Stage C (DDS + MCP4725)**: PASS
  - `dds_mcp4725_pipeline`: run `sim-20260921-140027-8600e28a` (PASS)
- **Stage D (Top Integration)**: PASS
  - `tone_dac_demo_top`: run `sim-20260921-140138-b0107917` (PASS, 88 checks, 0 errors)
- **Stage E (Full Verify)**: PASS
  - `verify`: run `verify-20260921-140458-3b273ad1` (Overall PASS, synthesis `20260921-140458-1cea9935`: 0 errors / 25 audited allowed warnings / 0 unexpected / 0 latches; all 4 simulations PASS)
- **Stage F (Bitstream)**: PASS
  - `build -Stage bitstream`: run `20260921-140556-ded16c9b`
  - MAP / PAR: 0 errors / 0 warnings, 全部布线完成 (`Timing Score: 0`)
  - I/O 绑定: 8 / 8 (100%) 全部 `LOCATED`（`rst_n` P3, `sensor_async` P28/P29/P30, `clk` P57, `dac_i2c_scl` P102, `dac_i2c_sda` P103, `square_out` P110；P31/P32/P111/P113 保持未占用）
  - 时序核对（人工阅读 `timing.twr` 与 `par.log`）：
    - 约束：`TS_clk = PERIOD 83.33 ns HIGH 50%`
    - Setup 最差 slack: `70.800 ns`，最小周期 `12.530 ns`（最高等效频率 `79.808 MHz`）
    - Hold 最差 slack: `0.872 ns`
    - Timing errors: 0, Failing endpoints: 0, All constraints were met (Timing PASS)
  - DRC: 0 errors / 0 warnings
  - 产物: `design.bit` (54 738 字节, SHA-256: `9E36A9718625F7D4AB3D7CE1A18467AF66FE90873DC377A5BC9A8EE36BE0E4FD`)

- **Stage G (Hardware Program - ISF)**: PASS
  - 命令: `ise.ps1 program -Project tone_dac_demo -Mode Isf -BitFile projects\tone_dac_demo\artifacts\20260921-140556-ded16c9b\results\design.bit -ConfirmHardwareWrite`
  - 运行 ID: `program-20260921-143137-c3f2eea6`
  - 下载线: Digilent JTAG-HS2 (`SN: 210241672559`, 10000000 Hz)
  - 烧录事务执行（一次性通过，`programAttempts = 1`）：
    - 静态与 Preflight: `xc3s50an` (IDCODE `0x02610093`) 匹配，Preflight `COMPLETE`
    - 擦除阶段 (Erase): `Erasing device...` → `Erasure completed successfully.`
    - 写入阶段 (Program): `Programming Flash...done.` → `Programming completed successfully.`
    - 校验阶段 (Verify): `Verifying device...done.` → `Verification completed successfully.`
    - 完成状态: `Checking done pin....done.` → `Programmed successfully.`
  - 六个状态字段:
    - `cableDetected        = PASS`
    - `jtagChainDetected    = PASS`
    - `deviceMatched        = PASS`
    - `programmingCompleted = PASS`
    - `programmingVerified  = VERIFIED`
    - `userDesignFunctional = NOT_TESTED`

## 6. 板级验证状态与测量指南

```
programmingVerified  = VERIFIED
userDesignFunctional = NOT_TESTED
BOARD TEST           = NOT_TESTED
```

烧录已按用户明确指令完成（`programmingVerified = VERIFIED`），但根据项目宪法，**烧录成功不等于设计工作正常**。板级功能测量固定标记为 `NOT_TESTED`。

### 硬件测试与测量引脚指引

上电/复位后，板卡内部 ISF 会自动配置 FPGA（要求跳线 `M[2:0] = 011`，`VCCAUX = 3.3V`）：

| 信号 | 板级引脚 | 测量方式 / 预期行为 |
| :--- | :--- | :--- |
| `rst_n` | **P3** | 低电平有效复位（默认上拉时为工作态） |
| `clk` | **P57** | 12 MHz 板载有源晶振输入 |
| `sensor_async[2:0]` | **P28 (bit 0), P29 (bit 1), P30 (bit 2)** | 3-bit 编码输入（000: 静音; 001~111: 音符 1~7） |
| `square_out` | **P110** | 示波器或蜂鸣器：输出对应音符频率的 50% 占空比方波（3.3V LVCMOS） |
| `dac_i2c_scl` | **P102** | 示波器探头：MCP4725 I2C 时钟（~375 kHz） |
| `dac_i2c_sda` | **P103** | 示波器探头：MCP4725 I2C 数据（Fast Mode 写 DAC 寄存器） |
| MCP4725 VOUT | 外接模块 | 示波器：对应音符频率的平滑模拟正弦波（0~3.3V 动态范围） |

