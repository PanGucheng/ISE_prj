# ADC / DAC 可选外设扩展设计(ADS1115 与 MCP4725)

> **Status**: IMPLEMENTED / STANDALONE(已仿真,默认关闭,未接顶层,未上板)
> **Scope**: 独立 I²C master + ADS1115 controller + MCP4725 controller 的驱动基础设施
> **Plan**: [ADS1115与MCP4725可选外设开发计划.md](./ADS1115与MCP4725可选外设开发计划.md)(实现细节以此计划为准)
> **协议依据**: 仓库内 [ads1115.pdf](./ads1115.pdf)(TI ZHCS311E/SBAS444)与
> [MCP4725.pdf](./MCP4725.pdf)(Microchip DS22039C_CN)。**不采用网络示例代码**;
> 网上资料只允许用来对照检查对本手册的理解,结论一律以这两份手册为准。
> **验收证据**: verify-20260916-013752-c8254ef6 Overall PASS(9 仿真 + 综合 0/0 + 门禁)。

---

## 1. 文件与模块

```
src/periph/i2c_master.v     命令级 I2C 主机核心(开漏、单时钟域)
src/periph/ads1115_ctrl.v   ADS1115 三通道轮询采集控制器
src/periph/mcp4725_ctrl.v   MCP4725 Fast Write DAC 控制器(pending+overrun)
sim/models/ads1115_model.v  ADS1115 协议级模型(OS 轮询时序、NACK 注入)
sim/models/mcp4725_model.v  MCP4725 协议级模型(EEPROM 命令违规检测)
sim/tb_i2c_master.v         11 组协议/错误路径测试(58 checks)
sim/tb_ads1115_ctrl.v       三通道采集 + 错误映射 + ENABLE=0(40 checks)
sim/tb_mcp4725_ctrl.v       Fast Write + NACK + 过载 + 12 MHz 吞吐(73 checks)
src/finger_piano_cfg.vh     外设配置宏(默认全关)
```

## 2. 为什么 ADS1115 与 MCP4725 使用两条独立 I²C

最终架构里两条数据链的节拍完全不同:ADC 按压力链路轮询(每帧 = 三通道
"配置→等转换→读结果",毫秒级),DAC 按音频流水线以 **8 kS/s(125 µs)**
持续推送样点。若共享一条总线,ADC 一次多字节轮询事务(约 2 ms 量级的
等待+读取)会把 DAC 的样点时间轴整体推迟,造成波形失真;而且两链路的
错误恢复、速率需求互不相同。因此硬件上是**两条物理总线、四个独立引脚**,
FPGA 内是**两个完全独立的 i2c_master 实例**(同一份代码、两个实例),
**没有**总线仲裁器、没有共享事务调度器。

## 3. ADS1115 接线(最终硬件,本阶段不搭建)

| 信号 | 连接 | 说明 |
|---|---|---|
| AIN0/AIN1/AIN2 | 三路 FSR 调理输出 | 单端对地(MUX 100/101/110),绝对输入不得超过 VDD(3.3 V 供电时不能因为 PGA=±4.096 V 就输入 4.096 V,见手册 Electrical Characteristics 脚注) |
| ADDR | GND | 器件地址 1001000b = 7'h48(手册表 7-2) |
| ALERT/RDY | NC | 本设计不用转换完成中断,用轮询 Config.OS(也不使用 RDY 比较器模式) |
| SCL/SDA | 独立总线 1 | 4.7 kΩ 上拉到 **3.3 V**。若使用模块板,须检查其自带上拉接的是 3.3 V 而不是 5 V(ADS1115 SDA/SCL 供电域) |

## 4. MCP4725 接线(最终硬件,本阶段不搭建)

| 信号 | 连接 | 说明 |
|---|---|---|
| SCL/SDA | 独立总线 2 | 独立 4.7 kΩ 上拉到 **3.3 V**(与 ADS 总线分开) |
| A0 | GND(或按需) | 与 A2/A1(出厂固定 00)组成地址位,默认 1100000b = 7'h60 |
| VOUT | 重构滤波 → LM386 | VOUT = VDD × D / 4096;本阶段只发数字码,模拟链路未验证 |

## 5. 默认地址与修改方法

所有配置集中在 `src/finger_piano_cfg.vh`:

```verilog
`define CFG_ADS1115_ADDR      7'h48   // ADDR=GND;改接 VDD/SDA/SCL -> 49/4A/4B
`define CFG_MCP4725_ADDR      7'h60   // A2A1A0=000;A0 接 VDD -> 7'h61
```

地址在 controller 内参与拼地址字节(`{ADDR_B, R/W}`),TB 的模型也按同一
宏实例化,改宏即可整体迁移。**禁止**在 RTL 里写死地址字面量。

## 6. ADS1115 Config 位域与 C3E3 / D3E3 / E3E3 的推导

手册 8.1.3(图 8-5):`OS[15] MUX[14:12] PGA[11:9] MODE[8] DR[7:5]
COMP_MODE[4] COMP_POL[3] COMP_LAT[2] COMP_QUE[1:0]`。

本设计固定:OS=1(启动单次转换)、PGA=001(±4.096 V)、MODE=1(single-shot)、
DR=111(860 SPS)、比较器关闭(COMP_QUE=11,其余 COMP 位=0)。三通道仅
MUX 不同(AIN0/1/2 对地 = 100/101/110):

```
CH0 = 1_100_001_1_111_0_0_0_11 = 1100 0011 1110 0011 = 16'hC3E3
CH1 = 1_101_001_1_111_0_0_0_11 = 16'hD3E3
CH2 = 1_110_001_1_111_0_0_0_11 = 16'hE3E3
```

RTL(`ads1115_ctrl.v`)按位域拼接生成,TB 逐一断言;**不是**从任务书粘贴
的十六进制。改 `CFG_ADS1115_PGA` / `CFG_ADS1115_DR` 宏,配置字随之自动变化。

## 7. ADC 采样 FSM 与 OS 轮询

`ads1115_ctrl` 每帧扫描三通道,每通道三步(手册 7.5/8.1):

```
写配置(启动转换)          START, addr+W, 0x01, CFG[15:8], CFG[7:0], STOP
轮询转换状态               START, addr+W, 0x01, RESTART, addr+R,
                           读 CFG 高/低字节(主机 NACK 末字节), STOP
                           -> OS 位(高字节 bit7)=0 则再来一轮;
                              超时(>=2ms 当量,覆盖 860SPS+-10%)报错误码 4
读转换结果                 START, addr+W, 0x00, RESTART, addr+R,
                           读结果高/低字节(主机 NACK 末字节), STOP
```

- 写 pointer 后读操作必须经过 **RESTART**(同一事务内改变传输方向),
  TB 断言了这一点;
- 结果按 16-bit **two's complement 原样输出**(含负数,不钳 0),钳位属于
  P5 压力处理阶段;
- `adc_sample_valid` 每帧(三通道全部完成)脉冲一次,`adc_busy` 常亮
  (连续扫描),错误时 `adc_error` 脉冲 + `error_code` 粘滞。

## 8. DAC Fast Write 帧与 VOUT 更新沿

手册 6.1.1:C2=0,C1=0,C0=X(X=任意,发 0),PD1PD0=00(正常模式):

```
START | 0x60+W | ACK | 0000_D11D10D9D8 | ACK | D7..D0 | ACK | STOP
例:12'hABC -> 字节1=8'h0A, 字节2=8'hBC
```

**VOUT 在第三字节的 ACK 下降沿更新**(图 6-1 注 2)——这决定了流水线模型:
一个样点只要字节发完就"已生效",controller 用 pending 槽保证每个 8 kS/s
样点恰好发一次。**EEPROM 写命令(C2C1C0 含 011 组合)结构上不可能出现**:
首字节高半字节恒 4'b0000,TB 的模型还会扫描总线做违规检测
(`eeprom_viol`)。

## 9. 为什么禁止 DDS 写 EEPROM

写 EEPROM 典型 25 ms / 最大 50 ms,且有擦写寿命。若 DDS 以 8 kS/s 写
EEPROM,一次写入期间将积压数百个样点,音频彻底失真,器件寿命也会在
数小时内耗尽。EEPROM 只适合"上电默认值"级别的一次性配置;音频样点
必须走 Fast Write(只写 DAC 寄存器)。因此 RTL 层面把 EEPROM 命令做成了
**不可能发生**,而不是"约定不写"。

## 10. I²C 拍数:强制公式与 12 MHz 默认 36 拍

**分层规则(计划冻结)**:

1. **默认路径**(`SYS_CLK_HZ == 12_000_000` 且 `I2C_HZ == 333_333`):
   固定 `PERIOD=36,LOW=18,HIGH=18`(actual 333333.333 Hz,略高于名义宏
   333333 是**允许的**——宏只是名义目标,不是 actual ≤ 宏的硬上限);
2. **任何其它 `I2C_HZ`**(含可配置的 400000):走强制公式,此时
   actual ≤ 所请求速率;
3. 400 kHz 只是可配置项,**不是**实物默认。

强制公式(`tLOW_MIN/tHIGH_MIN` 为手册 Fast-mode 下限:1300/600 ns;
ADS1115 的 tBUF=600 ns,MCP4725 的 tBUF=1300 ns,按实例传入):

```
LOW    = ceil(tLOW_MIN  * SYS_CLK)
PERIOD = ceil(SYS_CLK   / I2C_HZ)
HIGH   = max( ceil(tHIGH_MIN * SYS_CLK), PERIOD - LOW )
```

**32 位溢出**:`SYS_CLK_HZ * 1300 = 1.56e10` 已溢出 32 位,必须先除后取整:

```verilog
localparam integer Q_LOW  = 1000000000 / 1300;   // 769230
localparam integer Q_HIGH = 1000000000 / 600;    // 1666666
localparam integer LOW    = (SYS_CLK_HZ + Q_LOW  - 1) / Q_LOW;   // 16 -> 1333ns
localparam integer PERIOD = (SYS_CLK_HZ + I2C_HZ - 1) / I2C_HZ;  // 333333 -> 37
localparam integer HIGH   = max((SYS_CLK_HZ+Q_HIGH-1)/Q_HIGH, PERIOD-LOW)
```

若分别对 LOW/HIGH 向上取整再相加,12 MHz 得 16+8=24 拍 = 500 kHz,超过
Fast-mode 400 kHz 上限——这正是必须用 PERIOD 公式的原因。**两个
controller 都有 `I2C_HZ` 参数**,拍数由 controller 算好后以周期数传给
`i2c_master`(master 自己不做任何 Hz→拍换算,也不读全局宏)。TB 用
18+18 断言锁死默认路径,实测 120 帧 SCL 高段全部 == 18、位周期无 <36。

## 11. ENABLE 宏的真实语义

`CFG_ENABLE_ADS1115` / `CFG_ENABLE_MCP4725` 是 **driver default enable /
integration-ready 配置**,供 controller 的 ENABLE 参数与独立 TB 使用。
**把宏改成 1 并不能启用硬件**。真正启用必须同时完成:

1. `finger_piano_top` 增加 `adc_i2c_scl/sda`、`dac_i2c_scl/sda` 四个
   `inout` 端口;
2. 顶层实例化 `ads1115_ctrl` 与 `mcp4725_ctrl`(两个独立 i2c_master);
3. 用户逐脚确认后的 **4 个真实 UCF LOC**(禁止 MAP 自动分配当作确认)。

本阶段三者都不做:宏默认 0、顶层无端口、UCF 无 I²C LOC、综合网表
232 FF / 20 I/O 与 P1 之前完全一致(零资源膨胀)。

## 12. 仿真方法

```powershell
pwsh -File .\ise.ps1 sim    -Project finger_piano -Test i2c_master
pwsh -File .\ise.ps1 sim    -Project finger_piano -Test ads1115_ctrl
pwsh -File .\ise.ps1 sim    -Project finger_piano -Test mcp4725_ctrl
pwsh -File .\ise.ps1 verify -Project finger_piano    # 全量(综合+9 仿真+门禁)
```

- 判据是日志子串(`TB_xxx: PASS`),退出码 0 不算 PASS;
- DAC 吞吐用例**必须用真实 12 MHz + 333333**(不降频):120 样点按
  8 kHz(1500 拍)连续推送,断言 0 overrun、0 丢样、SCL 高段全部 18 拍;
- ISim 的 `pullup` 只模拟**逻辑上拉**(0/Z→1),**不能代表**真实 4.7 kΩ +
  总线电容的上升时间;I²C 边沿的模拟品质与实物不等价,这一点也写进了
  计划的风险表;
- 已知工具差异:XST 不接受 generate 块内的 `localparam`(ISim 接受),
  因此两个 controller 的常量全部位于模块作用域。

## 13. 实物调试方法(将来)

- 两条总线分别用逻辑分析仪(或两条通道)独立观察 I²C 波形,核对:
  地址字节、Fast Write 三字节、ACK 电平、SCL 高/低宽度(12 MHz 下
  18 拍 = 1.5 µs / 1.5 µs,约 333 kHz);
- ADS1115 先单通道验证(OS 轮询行为、负码输出),再开三通道轮询;
- MCP4725 先静态电压(写 0x000/0xFFF 量 VOUT≈0/VDD),再跑音频;
- 烧录与探测沿用工具链 `probe` / `program`(由用户明确要求)。

## 14. 当前状态(未启用清单)

| 项 | 状态 |
|---|---|
| `CFG_ENABLE_ADS1115` / `CFG_ENABLE_MCP4725` | **0**(默认关闭) |
| 顶层端口 | 无(未加四个 inout) |
| 顶层实例化 | 无 |
| UCF I²C LOC | 无(仅 BOARD TODO 注释,引脚待用户逐脚确认) |
| DDS | 无(P3) |
| ALERT/RDY、Hs-mode(3.4 MHz) | 未使用 |
| 综合影响 | 0(232 FF / 20 I/O 与 legacy 基线一致) |
| 板级验证 | NOT_TESTED(模拟链路、重构滤波、LM386 均未搭建) |

## 15. 7 键 RTL 是 legacy baseline

当前 `finger_piano_top` 仍是 7 路优先级编码的方波电子琴——这是**刻意保留
的软件基线**。真实硬件是 **3 个 FSR + 3 个 LM393 比较器组成 3-bit 编码**
(000 静音,001~111 = C4~B4)。上板前必须独立完成
"7-key priority encoder → 3-bit binary decoder" 迁移并重跑全量 verify;
该迁移不属于本 ADC/DAC 阶段,也不允许混进其提交。

## 16. 错误职责划分(为什么 master 只报 NACK)

`i2c_master` 是通用协议核心,**不知道当前字节是地址还是数据**,因此底层
只报告"NACK / 超时 / 协议内部错误"三种结果;**ADDR_NACK 与 DATA_NACK 的
细分由各 controller 根据自身 FSM 状态完成**(ads1115_ctrl:地址字节步映射
1,pointer/数据步映射 2;mcp4725_ctrl 同理)。错误码统一为:
`0 无 / 1 ADDR_NACK / 2 DATA_NACK / 3 master 超时 / 4 其它(含 ADC 转换
等待超时)`。master 收到写 NACK 时自动补 STOP 释放总线;controller 再补
一次 STOP 保证事务关闭。

DAC 的缓冲策略是**一项 pending 槽 + overrun 标志**,不是
latest-value-wins:DDS 的每个 8 kS/s 样点都有意义,新样点到来时 pending
占用则置 `dac_overrun` 并**拒绝**(不覆盖已挂起样点);正常 8 kS/s 下
0 丢样、0 overrun(吞吐 TB 实测 120/120)。出错帧丢弃该样点并报错,
由上层决定重发。
