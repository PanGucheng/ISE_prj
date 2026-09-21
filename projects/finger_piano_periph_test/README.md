# finger_piano_periph_test — ADS1115 ADC UART 诊断版本

独立、可观测、低风险的 ADC UART 调试 bitstream：将 ADS1115 的硬件排查从完整电子琴中剥离，关闭 MCP4725/DAC 诊断链，通过串口实时输出 16-bit 原始采样值与精确错误码。

---

## 1. 硬件引脚与电气规范

- 器件型号：`xc3s50an-4-tqg144`；单一系统时钟：`P57` (12 MHz)；外部复位：`P3` (低有效)
- 电气标准：全部引脚均为 **LVCMOS33**，Bank VCCO = 3.3 V
- 引脚分配与用途：

| 信号名 | 物理引脚 | I/O 类型 | 描述与接线指南 |
| :--- | :--- | :--- | :--- |
| **`clk`** | **P57** | INPUT | 12 MHz 板载有源晶振输入 |
| **`rst_n`** | **P3** | INPUT | 外部异步复位（低有效，平时保持高电平） |
| **`adc_i2c_scl`** | **P31** | TRISTATE | ADS1115 I2C SCL（100 kHz 开漏，依赖板级 4.7 kΩ 外部上拉） |
| **`adc_i2c_sda`** | **P32** | BIDIR | ADS1115 I2C SDA（100 kHz 开漏，依赖板级 4.7 kΩ 外部上拉） |
| **`dac_i2c_scl`** | **P102** | TRISTATE | 关闭 DAC，**严格保持 `1'bz` 高阻释放**，无任何 I2C 活动 |
| **`dac_i2c_sda`** | **P103** | TRISTATE | 关闭 DAC，**严格保持 `1'bz` 高阻释放**，无任何 I2C 活动 |
| **`uart_tx`** | **P110** | OUTPUT | **UART TX (115200 baud, 8N1)**，接 USB 转串口模块 RXD |
| **`dbg_heartbeat`** | **P111** | OUTPUT | **约 1 Hz 方波心跳**（500 ms 翻转，证明 FPGA 配置及时钟/复位正常） |
| **`dbg_unused`** | **P113** | OUTPUT | **固定输出 `1'b0`**，安全接地 |

> [!NOTE]
> I2C 上拉依赖板级 4.7 kΩ 外部硬件电阻，UCF 严禁配置 `PULLUP`。
> 上位机串口接收端配置：波特率 **115200**、数据位 **8**、校验位 **None**、停止位 **1** (8N1)。

---

## 2. UART 报文协议与调度机制

### 2.1 报文格式（纯 ASCII）
- **正常采样上报**（约 100 ms 一次，长 41 字节）：
  ```text
  ADC OK CH0=0x1234 CH1=0x5678 CH2=0x9ABC\r\n
  ```
- **错误状态上报**（`adc_error` 触发时立即调度，长 18 字节）：
  ```text
  ADC ERROR CODE=x\r\n
  ```

### 2.2 错误码定义（严格沿用 `ads1115_ctrl.v` 事实）
- **`CODE=1`**：地址字节 NACK（ADS1115 未应答其 `0x48` 地址，常见于未上电、虚焊、ADDR 引脚未接地、SCL/SDA 断线）
- **`CODE=2`**：Pointer 或数据字节 NACK（写寄存器或 Pointer 过程中被从机拒收）
- **`CODE=3`**：I2C Master 超时（SCL/SDA 被外部强制拉低超过 36 个位周期阈值）
- **`CODE=4`**：其它错误，包括转换等待超时或协议异常（Config 写入后等待 OS 位就绪超时）

### 2.3 缓冲与仲裁机制
1. **最新值单槽缓存**：`adc_sample_valid` 脉冲到来时原子更新 `latest_ch0/ch1/ch2`，不建采样队列，UART 发送绝对零阻塞 ADS1115 采样 FSM。
2. **首次采样门控**：增设 `have_valid_sample` 标志（初值 0，首次有效采样后置 1）。在初次采样完成前，100 ms 定时器保持静默，严禁输出虚假的 `0x0000` 报文。
3. **行完整性保证（非抢占式）**：当 `adc_error` 到来时立即锁存 `err_pending` 与错误码；若此时 UART 正在发送正常报文，先完整发完当前这一行（41 字节 + `\r\n`），进入空闲态后下一拍立即优先发出错误报文，杜绝串口端接收乱码。

---

## 3. 仿真与门禁结果

- **全量门禁 (`verify`)**：run `verify-20260921-151844-5d21a112` (**Overall PASS**)
  - **静态检查**：Verilog-2001 PASS，单一时钟域 PASS，无虚构约束 PASS，引用文件 PASS
  - **综合阶段**：run `20260921-151844-7c13ab00`，0 errors，0 latches，**19 audited allowed / 0 unexpected**（窄口径精准白名单，严格覆盖结构性裁剪，无泛化规则）
  - **仿真阶段**：4 / 4 项仿真全部 **PASS**
    - `uart_tx_unit` (top: `tb_uart_tx`): 严格验证 idle=1, start=0, 8 bits LSB first, stop=1 及每 bit 严格 104 拍时钟周期 (PASS)
    - `periph_test_normal` (top: `tb_periph_test_top`, `TB_MODE=0`): 验证首帧门控、41 字节 ASCII 解码、心跳翻转及 DAC 释放 (PASS)
    - `periph_test_adc_nack` (top: `tb_periph_test_top`, `TB_MODE=1`): 验证注入地址 NACK 时输出 `ADC ERROR CODE=1\r\n` (PASS)
    - `periph_test_heartbeat_real` (top: `tb_periph_test_top`, `TB_MODE=2`): 验证真实 6,000,000 拍半周期方波接线与时钟周期 (PASS)
  - **实现门禁**：PASS (`expectImplementationBlocked=false`, gate open)

- **完整实现与 Bitstream 构建**：run `20260921-151944-f93a3045`
  - **MAP / PAR**：0 errors / 0 warnings，全部 8 个用户 I/O 100% `LOCATED`
  - **时序分析 (`timing.twr`)**：
    - 约束：`TS_clk = PERIOD TIMEGRP "clk_group" 83.33 ns HIGH 50%;`
    - 分析路径：16,525 paths, 1,438 endpoints, **0 failing endpoints, 0 timing errors**
    - Setup 最差 slack: **72.514 ns**，最小周期: **10.816 ns**（最高时钟支持 **92.456 MHz**）
    - Hold 最差 slack: 满足要求，`All constraints were met.` (Timing PASS)
  - **DRC**：0 errors, 2 warnings (因 DAC inout 引脚严格释放至 `1'bz` 导致的正常输入缓冲空载告警)
  - **比特流产物**：
    - 路径：`projects/finger_piano_periph_test/artifacts/20260921-151944-f93a3045/results/design.bit`
    - 大小：**54,738 字节**
    - SHA-256：`AA92B01010D96B2E082125F29DE9AF41D3EBAB5D2364E178C2063DAE80F38DDF`

---

## 4. 板级验证状态与排查指南

```
programmingCompleted = PASS
programmingVerified  = VERIFIED
userDesignFunctional = NOT_TESTED
BOARD TEST           = NOT_TESTED
```

- **烧录运行 ID**: `program-20260921-152203-a86db90c` (用户明确要求 `-Mode Isf` + `-ConfirmHardwareWrite`)
- **烧录模式**: `Isf` (Spartan-3AN 内部非易失 Flash，`program -p 1 -e -v`)
- **下载线**: Digilent JTAG-HS2 (`SN: 210241672559`, 10000000 Hz)
- **门禁证据**:
  1. `Erasing device...` → `Erasure completed successfully.`
  2. `Programming Flash...done.` → `Programming completed successfully.`
  3. `Verifying device...done.` → `Verification completed successfully.`
  4. `Checking done pin....done.` → `Programmed successfully.`
- **注意**: 烧录成功不等于板卡功能正常（`userDesignFunctional = NOT_TESTED`），串口实际输出需通过串口终端排查。

### 串口排查现象判定指南

1. **上电观察 P111 (Heartbeat)**：
   - 若 P111 约为 1 Hz 规律闪烁（点亮 0.5s，熄灭 0.5s），证明 FPGA 比特流加载成功、12 MHz 晶振与系统复位工作完全正常。
2. **连接串口终端 (P110 与 GND)**：
   - 终端配置：115200 baud, 8N1。
   - **若输出 `ADC OK CH0=0x... CH1=0x... CH2=0x...`**：
     - 说明 ADS1115 通信正常，三通道采样正在持续工作！观察手指按压压力传感器时 CH0/CH1/CH2 的读数变化。
   - **若输出 `ADC ERROR CODE=1`**：
     - 说明 ADS1115 从机地址 `0x48` 未被应答（地址字节 NACK）。请重点检查：
       a) ADS1115 模块 VCC 是否已接 3.3V，GND 是否共地；
       b) ADDR 引脚是否已可靠接 GND（若悬空或接 VDD，地址会变为 0x49/0x4A/0x4B）；
       c) P31 (SCL) 与 P32 (SDA) 杜邦线是否接反或接触不良；
       d) I2C 外部上拉电阻是否有效。
   - **若输出 `ADC ERROR CODE=3`**：
     - 说明 I2C 总线超时，SCL/SDA 可能被意外短路接地。
   - **若输出 `ADC ERROR CODE=4`**：
     - 说明已向 ADS1115 写入配置，但在等待转换完成（轮询 OS 就绪位）时超时。
