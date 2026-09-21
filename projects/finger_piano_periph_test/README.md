# finger_piano_periph_test — ADS1115 VOFA+ FireWater 电压诊断版本

独立、可观测、低风险的 ADC UART 调试 bitstream：将 ADS1115 的硬件排查从完整电子琴中剥离，关闭 MCP4725/DAC 诊断链，采用 VOFA+ 官方 **FireWater 协议** 格式输出 CH0 模拟电压（单位：伏特 V，保留 4 位小数，分辨率 0.1 mV），上位机可直接绘制实时电压曲线。

---

## 1. 硬件引脚与电气规范

- 器件型号：`xc3s50an-4-tqg144`；单一系统时钟：`P57` (12 MHz)；外部复位：`P3` (低有效)
- 电气标准：全部引脚均为 **LVCMOS33**，Bank VCCO = 3.3 V
- 引脚分配与用途：

| 信号名 | 物理引脚 | I/O 类型 | 描述与接线指南 |
| :--- | :--- | :--- | :--- |
| **`clk`** | **P57** | INPUT | 12 MHz 板载有源晶振输入 |
| **`rst_n`** | **P3** | INPUT | 外部异步复位（低有效，平时保持高电平） |
| **`adc_i2c_scl`** | **P31** | TRISTATE | ADS1115 I2C SCL（100 kHz 开漏，**必须外挂 2.2k ~ 4.7k 上拉电阻至 3.3V**） |
| **`adc_i2c_sda`** | **P32** | BIDIR | ADS1115 I2C SDA（100 kHz 开漏，**必须外挂 2.2k ~ 4.7k 上拉电阻至 3.3V**） |
| **`dac_i2c_scl`** | **P102** | TRISTATE | 关闭 DAC，**严格保持 `1'bz` 高阻释放**，无任何 I2C 活动 |
| **`dac_i2c_sda`** | **P103** | TRISTATE | 关闭 DAC，**严格保持 `1'bz` 高阻释放**，无任何 I2C 活动 |
| **`uart_tx`** | **P110** | OUTPUT | **UART TX (115200 baud, 8N1)**，接 USB 转串口模块 RXD |
| **`dbg_heartbeat`** | **P111** | OUTPUT | **约 1 Hz 方波心跳**（500 ms 翻转，证明 FPGA 配置及时钟/复位正常） |
| **`dbg_unused`** | **P113** | OUTPUT | **固定输出 `1'b0`**，安全接地 |

> [!IMPORTANT]
> **已实测验证**：ADS1115 的 I2C 总线若外部上拉不足，会导致 SCL/SDA 上升沿过缓而稳定触发地址 NACK（`CODE=1`）。**请务必确保 SCL (P31) 和 SDA (P32) 均已外接 2.2 kΩ ~ 4.7 kΩ 上拉电阻到 3.3V**。

---

## 2. VOFA+ FireWater 协议与电压转换

### 2.1 报文格式（FireWater 规范）
- **正常采样上报**（约 100 ms 一次，长 12 字节）：
  ```text
  ch0:0.9220\r\n
  ```
  - `ch0:` 为前导标识，VOFA+ FireWater 引擎会自动剔除该前缀并将数值绘制在通道 0 曲线上。
  - `0.9220` 为十进制伏特值（保留 4 位小数，分辨率 $0.1\text{ mV}$）。
- **错误状态上报**（`adc_error` 触发时立即优先调度，长 18 字节）：
  ```text
  ADC ERROR CODE=x\r\n
  ```

### 2.2 硬件电压换算算法（零乘法器 / 零除法器）
ADS1115 在当前配置（PGA = `001`，量程 $\pm 4.096\text{ V}$，16-bit）：
- $1\text{ LSB} = 4.096\text{ V} / 32768 = 125\ \mu\text{V}$。
- 微伏电压计算：$V_{\mu V} = \text{raw} \times 125 = (\text{raw} \ll 7) - (\text{raw} \ll 1) - \text{raw}$（仅用移位和减法，零硬件乘法器）。
- 22 拍 Double-Dabble（Shift-and-Add-3）状态机将 22 位微伏二进制数转换为 7 位 BCD 码，取高 5 位生成整数伏特与 4 位小数，在 12 MHz 下耗时仅 $1.84\ \mu\text{s}$。

### 2.3 错误码定义（沿用 `ads1115_ctrl.v`）
- **`CODE=1`**：地址字节 NACK（ADS1115 未应答 `0x48` 地址，常见于未上电、虚焊、ADDR 悬空未接地、或上拉不足）
- **`CODE=2`**：Pointer 或数据字节 NACK（写寄存器被从机拒收）
- **`CODE=3`**：I2C Master 超时（SCL/SDA 被外部强制拉低超过超时阈值）
- **`CODE=4`**：转换等待超时（Config 写入后等待 OS 位就绪超时）

---

## 3. 仿真与门禁结果

- **全量门禁 (`verify`)**：run `verify-20260921-155059-fc036230` (**Overall PASS**)
  - **静态检查**：Verilog-2001 PASS，单一时钟域 PASS，无虚构约束 PASS，引用文件 PASS
  - **综合阶段**：run `20260921-155059-ceb494d4`，0 errors，0 latches，**54 audited allowed / 0 unexpected**（审查了 ADS1115 内部状态裁剪、DAC 高阻释放、UART/line_len 恒定零位、以及未输出的 CH1/CH2 寄存器裁剪，无泛化规则）
  - **仿真阶段**：5 / 5 项仿真全部 **PASS**
    - `bin_to_dec_volt_unit` (top: `tb_bin_to_dec_volt`): 严格验证 0V, 0.9220V, 1.0000V, 3.3000V, 4.0958V 与负数钳位 (PASS)
    - `uart_tx_unit` (top: `tb_uart_tx`): 严格验证 idle=1, start=0, 8 bits LSB first, stop=1 及每 bit 严格 104 拍 (PASS)
    - `periph_test_normal` (top: `tb_periph_test_top`, `TB_MODE=0`): 验证首帧门控、12 字节 FireWater `ch0:0.5825\r\n` 接收、心跳翻转及 DAC 释放 (PASS)
    - `periph_test_adc_nack` (top: `tb_periph_test_top`, `TB_MODE=1`): 验证注入地址 NACK 时输出 `ADC ERROR CODE=1\r\n` (PASS)
    - `periph_test_heartbeat_real` (top: `tb_periph_test_top`, `TB_MODE=2`): 验证真实 6,000,000 拍半周期方波接线与时钟周期 (PASS)
  - **实现门禁**：PASS (`expectImplementationBlocked=false`, gate open)

- **完整实现与 Bitstream 构建**：run `20260921-155206-89ec1fca`
  - **MAP / PAR**：0 errors / 0 warnings，全部 9 个物理管脚 100% `LOCATED`
  - **时序分析 (`timing.twr`)**：
    - 约束：`TS_clk = PERIOD TIMEGRP "clk_group" 83.33 ns HIGH 50%;`
    - 分析路径：25,171 paths, 1,683 endpoints, **0 failing endpoints, 0 timing errors**
    - Setup 最差 slack: **72.276 ns**，最小周期: **11.054 ns**（最高时钟支持 **90.465 MHz**）
    - Hold 最差 slack: 满足要求，`All constraints were met.` (Timing PASS)
  - **DRC**：0 errors, 2 warnings (DAC inout 释放至 `1'bz` 导致的空载告警)
  - **比特流产物**：
    - 路径：`projects/finger_piano_periph_test/artifacts/20260921-155206-89ec1fca/results/design.bit`
    - 大小：**54,738 字节**
    - SHA-256：`F500DDC0A4B444309CA73625DB6293DA8315AB4DF1EB160AB1C03B48E3A804A7`

---

## 4. 上位机 VOFA+ 使用配置

1. 打开 **VOFA+** 软件。
2. 顶部工具栏配置：
   - **控件 / 协议**：选择 **FireWater**
   - **端口**：选择实际串口（如 `COM19`）
   - **波特率**：`115200`，数据位 `8`，停止位 `1`，无校验
3. 点击连接（打开串口）：
   - 下方控件区即可看到名为 `ch0` 的电压实时波形曲线（数值在 0.0000 ~ 3.3000 V 之间动态浮动）。
