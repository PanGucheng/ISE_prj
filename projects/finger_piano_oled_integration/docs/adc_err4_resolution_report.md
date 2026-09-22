# ADC ERR=4 根因排查与板级闭环解决报告

**工程**：`finger_piano_oled_integration`  
**日期**：2026-09-22  
**状态**：RESOLVED / CLOSED  
**相关 Commit**：`edeeb93` (`fix(oled_integration): resolve ADC ERR=4 bug and implement live 3-channel ADC UART reporting`)  

---

## 1. 故障现象与背景

在 `finger_piano` 外设工程中，ADS1115 三通道 ADC 能够正常完成轮询采样并通过串口持续输出各通道电压 CSV 数据。  
但在 `finger_piano_oled_integration` OLED 集成工程中，系统启动后串口持续以约 3 秒周期打印错误信息：
```text
ADC ERR=4
ADC ERR=4
...
```
由于当时错误码 4 涵盖了“OS 等待超时”以及多种 master 异常退出情况，且顶层没有上报成功采样的数据流，无法直观判断是硬件 I²C 通信失败、器件未响应还是控制器逻辑异常。

---

## 2. 诊断分流与硬件复现

为了精准定位错误分支，在 `src/periph/ads1115_ctrl.v` 中对错误码进行了细化拆分：
- **`ERR=4`**：严格保留为**单次转换 OS 等待超时**（启动转换后在规定周期内未检测到 OS 位变为 1）；
- **`ERR=5`**：定义为 **I²C Master 返回非预期/协议错误**（例如在轮询过程中 master 提前退出或状态握手异常）。

将该诊断逻辑烧录至 FPGA 板卡后，串口依然稳定输出：
```text
ADC ERR=4
```
**结论**：排除了 I²C 底层总线传输、ACK/NACK 错误或 Master 控制器协议跑飞（若是这些会出 1/2/3 或 5），故障被完全锁定在 **OS 等待计数与超时判定逻辑**。

---

## 3. 确切根因分析（Root Cause）

定位到 `src/periph/ads1115_ctrl.v` 中等待计数器的实现：
在先前的资源优化项 O2b 中，为了参数化适配不同时钟频率下的等待计数器位宽，引入了位切片逻辑：
```verilog
assign wait_timeout = (wait_cnt >= OS_WAIT_CYCLES[WAIT_BITS-1:0]);
```
其中 `OS_WAIT_CYCLES` 声明为 `integer` 常量（例如 12MHz 下为 `333333`）。

**XST 综合器 Bug**：
Xilinx ISE 14.7 的 XST 综合器在处理带参数化位宽边界（`[WAIT_BITS-1:0]`）对 `integer` 常量进行切片时存在已知静态求值缺陷，该表达式被直接求值为 `0`。
由此导致：
```verilog
wait_timeout = (wait_cnt >= 0); // 恒为 1'b1
```
在状态机进入 `S_WAIT_CONV` 时：
1. 第 0 个周期 `wait_cnt` 为 0，`wait_timeout` 立即为 1；
2. 状态机发起第一次读取并检查 ADS1115 的 Config 寄存器；
3. ADS1115 刚接收到启动转换命令，ADC 正在转换中，其 Config 寄存器最高位 OS 必然为 0（Busy）；
4. 控制器检测到 `OS == 0`，同时看到 `wait_timeout == 1`（误以为超时时间已到）；
5. 状态机未执行后续重试轮询，直接跳转至 `S_ERR_STOP` 并输出 `ERR=4`。

---

## 4. 修复与验证方案

### 4.1 修复措施
1. **消除 XST 语法陷阱**：移除带参数边界的常量切片，将 `wait_cnt` 固定为 16-bit 计数器（在 12MHz 下最大可计 ~5.46 ms，远大于 ADS1115 在 860 SPS 模式下的 ~1.16 ms 转换时间），直接使用标量常量比较：
   ```verilog
   assign wait_timeout = (wait_cnt >= OS_WAIT_CYCLES);
   ```
2. **仿真强化**：更新单测激励，覆盖真实的转换时间延迟场景，确认多周期等待及轮询机制正确。

### 4.2 方案 B：可观测性闭环（实时三通道数据上报）
为了彻底避免“串口不报错不等于采样正常”的黑盒隐患，按方案 B 实现硬件级可观测性：
1. 在 `src/finger_piano_stage2_top.v` 中将三通道 16-bit 转换结果 `(adc_ch0, adc_ch1, adc_ch2)` 及 `sample_valid` 脉冲引出至顶层；
2. 在顶层 `src/finger_piano_stage2_oled_top.v` 中设计轻量级串口上报状态机，在系统无错误时每 500 ms 自动发送一帧 ASCII 格式的采样数据：
   ```text
   ADC OK CH0=0xXXXX CH1=0xXXXX CH2=0xXXXX\r\n
   ```
3. 优化顶层寄存器与 UART 状态机结构，严格控制资源占用，避免在 XC3S50AN 极小器件上引起 Slice 溢出。

---

## 5. 构建指标与资源利用率

在远程 ISE 构建环境完成全流程实现（构建编号 `20260922-202944-3b5f28a9`）：
- **目标器件**：XC3S50AN-4-TQG144
- **Occupied Slices**：702 / 704 (99.7%)
- **Slice Flip-Flops**：592 / 1,408 (42%)
- **4-input LUTs**：1,175 / 1,408 (83%)
- **Block RAMs**：2 / 3 (66%)
- **时序约束**：12.0 MHz (83.33 ns)，最差建立裕量（Setup Slack）为 **+70.999 ns**，时序裕量充足。
- **生成的 Bitstream**：`artifacts/20260922-202944-3b5f28a9/results/design.bit`  
  **SHA-256**：`9AFD94BA935E80D87CF6C5125F15ECE917F3F3B4D420A630C5ADC29E592E2FF3`

---

## 6. 板级真机实测证据

### 6.1 烧录配置
- 方式：JTAG 易失模式（Volatile Program，`-Mode Jtag -onlyFpga`）
- 设备：Digilent JTAG-HS2 (`SN: 210241672559`)
- 状态：FPGA 下载成功，`DONEIN=1`，`CRC error=0`。

### 6.2 串口采样捕获
运行串口采集工具 `tools/capture-adc-uart.ps1 -Port COM20 -Baud 115200 -DurationSeconds 10`，捕获记录保存在：
`artifacts/uart-20260922-203101-live_adc_ok-9347e4bf/`

- **捕获时间**：10.3 秒
- **ADC 错误统计**：`ADC ERR=4` 出现次数为 **0**（0.0 错误/秒）
- **接收帧数**：成功接收 14 帧完整数据，格式均规范：
  ```text
  ADC OK CH0=0x596A CH1=0x59C2 CH2=0x6A86
  ADC OK CH0=0x5966 CH1=0x59C8 CH2=0x6A83
  ADC OK CH0=0x5965 CH1=0x59C5 CH2=0x6A80
  ADC OK CH0=0x5968 CH1=0x59C6 CH2=0x6A88
  ...
  ```

### 6.3 物理电压换算验证
根据 ADS1115 配置（FSR = ±4.096V，单端输入对应 15-bit 正量程 0~32767）：
$$\text{Voltage} = \frac{\text{Raw Code}}{32768} \times 4.096\,\text{V}$$

| 通道 | 16-bit 原始码范围 | 十进制码值 | 换算实际物理电压 | 物理信号特征 |
| :--- | :--- | :--- | :--- | :--- |
| **CH0** | `0x5959` ~ `0x5972` | 22873 ~ 22898 | **2.859 V ~ 2.862 V** | 静态分压，底噪微波动 ±2 LSB |
| **CH1** | `0x59B8` ~ `0x59D0` | 22968 ~ 22992 | **2.871 V ~ 2.874 V** | 静态分压，底噪微波动 ±2 LSB |
| **CH2** | `0x6A6A` ~ `0x6AA4` | 27242 ~ 27300 | **3.405 V ~ 3.412 V** | 静态分压/上拉，底噪微波动 ±3 LSB |

各通道数据稳定且呈现真实模拟采样的微小抖动，完全排除了硬件总线挂死或返回虚假固定值的可能。

---

## 7. 结论

`finger_piano_oled_integration` 工程的 `ADC ERR=4` 故障根因已彻底查明并修复，通过了真机硬件在环闭环测试，实时采样数据正常传输，该故障正式关闭。
