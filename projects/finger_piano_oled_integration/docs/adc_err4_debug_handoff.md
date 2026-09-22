# ADC ERR=4：分析、诊断版本与板测交接

日期：2026-09-22。基于 `ea17679`；本次修改见 Git diff/后续提交。

## 1. 当前结论与范围

用户已完成硬件 A/B：同一套板卡、ADS1115、P31/P32 与 4.7 kΩ 上拉，独立 `finger_piano_periph_test` 可输出随压力变化的三通道 CSV；OLED 集成工程持续输出 `ADC ERR=4`。用户确认双方都在 100 kHz 时也发生过故障。因此不把总线速率、断线或器件损坏作为已确定根因，不重复基础接线排查。

**根因尚未确定。本次交付的是诊断改动与采集工具，不是已经完成板测的修复。**

已发现原 `ERR=4` 混合两种来源：

1. `ads1115_ctrl.S_W_CHK`：读回 Config 高字节的 OS 位仍为 0，且等待计数达到 24000 拍。
2. 命令完成时 `m_ecode != 0`，经过 `st_errcls` 将 master 协议/非预期错误也编码为 4。

原 UART 每次 `adc_error` 脉冲都排队打印，没有相同错误去重。因此毫秒级刷屏与重复失败、自动重新扫描相符，单凭刷屏频率不能判定是 UART 死循环，也不能判定 OS 超时。

## 2. 两个工程的实质差异

| 项目 | 独立外设工程 | OLED 集成工程 | 当前判断 |
|---|---|---|---|
| ADC 引脚与时钟 | P31/P32，12 MHz | 相同 | 约束未发现差异 |
| I²C 速率来源 | 顶层显式 `.I2C_HZ(100000)` | 通过 `CFG_ADC_I2C_SPEED` 默认参数 | 本次统一 100000；不是已证实根因 |
| 配置字 | C3E3/D3E3/E3E3 | 相同 | OS=1，single-shot，860 SPS，±4.096 V |
| 读写流程 | 写 Config、轮询 OS、读 Conversion、切通道 | 相同 | 均使用重复 START、最后字节 NACK |
| OS 超时 | 24000 拍、32 位递增计数 | 24000 拍、16 位饱和计数 | 阈值不变，需用现场证据确认是否走到此分支 |
| master 计数器 | phase/timeout 均 32 位 | 100 kHz 配置下 phase 7 位、timeout 13 位 | 参数范围可表示；尚未发现确定的截断错误 |
| ADC 数据消费 | UART 电压转换使用三通道结果与 valid | 压力出口无消费者，相关数据链被综合裁剪 | 是硬件网表差异，不能直接等同于裁剪有错 |
| 并行活动 | DAC 引脚高阻，无 OLED | ADC、DDS/DAC、OLED、UART 同时工作 | 软件调度、实现和接口时序均需区别验证 |
| 成功可观测性 | 连续 CSV | 当前只报告 ADC 错误，不报告正常帧 | 总工程无错误输出不等于 ADC 已正常采样 |

从两个 ADC RTL 的 diff 看，转换相关改动集中在等待计数器收窄/饱和；master 改动集中在计数器位宽和常量截取。当前证据不足以认定“优化必然导致故障”。后续若做回退，应只替换 ADC 路径的一项，避免连 DAC master 一起变更。

版本注意：用户未提供两份 A/B bitstream 的精确路径。发现集成构建 `20260922-162247-06ec931f` 的输入快照使用 333333 Hz，但这不否定用户另一次双方 100 kHz 的试验。下一位 agent 必须记录实际烧录文件与 SHA-256，不能拿工作区宏代替已烧录版本。

## 3. 已准备的诊断修改

只改集成工程，独立外设工程和主工程未改：

- 经用户同意，将 ADC 默认速率恢复为 100000 Hz，作为固定 A/B 条件。
- 错误码 1/2/3 不变；**4 仅表示 OS 等待超时，5 表示 master 协议/非预期错误**。UART 原有 3-bit 错误码路径可直接打印 `ADC ERR=5`，消息格式不变。
- 未延长超时、删除错误检测、改变重试策略或增加 UART 限流，避免掩盖故障。
- ADC TB 增加参数 `TB_I2C_HZ`、`TB_CONV_CYCLES`；加入 master 协议错误注入、码 5 判定及三通道恢复检查。
- 配置新增 `ads1115_ctrl_real_100000` 与 `ads1115_ctrl_real_333333`，模型转换等待 16000 拍，相当于 12 MHz 下约 1.333 ms。原默认模型只有 2000 拍，约 0.167 ms，不能代表真实转换等待。

这些是逻辑/协议仿真，不模拟 RC 上升沿、管脚传播延迟或模拟输入。不能从仿真通过推导板测通过。

## 4. 本轮已执行与未执行

| 检查 | 结果/证据 |
|---|---|
| 修改前隔离测试，100 kHz + 16000 拍转换 | PASS，`sim-20260922-163405-5e57a35b`，位于 `tools/.work/adc_err4_20260922_163404` |
| 修改前隔离测试，333333 Hz + 16000 拍转换 | PASS，`sim-20260922-163412-fba83fb1`，同一隔离目录 |
| 修改后诊断 ADC 单测，100 kHz + 16000 拍转换，含码 5 注入及恢复 | PASS，`sim-20260922-163943-5dfc2888` |
| 串口采集脚本离线自测 | PASS，`tools/test-capture-adc-uart.ps1`；未打开串口 |
| 综合 | 流程 COMPLETE，`20260922-164020-6043106b`；不代表实现/时序/板测通过 |
| 全量 verify | **按用户要求中止**，`verify-20260922-164020-1fd45796`，不得作为完整 PASS；过程日志 `tools/.work/adc_diagnostic_verify.log` |
| 本次诊断版本 implement/bitstream | **NOT_RUN**，尚无可交付的新诊断 bitstream |
| 本次诊断版本 UART 实测/硬件烧录 | **NOT_RUN**，由用户交给另一个 agent 执行 |

verify 中止时最后启动的单项为 `sim-20260922-164244-cef4d0d3`（DDS pipeline 12 MHz）；本地编排进程已停止。若需要此项结果，先查该编号远端状态再 fetch，不盲目重启整轮。

## 5. 串口采集脚本

入口：仓库根目录 `tools/capture-adc-uart.ps1`。PowerShell 7 / .NET SerialPort，无第三方 Python 包。只接收串口；不发送命令、不烧录、不启用 DTR/RTS。打开串口的驱动行为仍取决于 USB 串口适配器。

```powershell
cd D:\ISE_prj
pwsh -NoProfile -File .\tools\capture-adc-uart.ps1 -ListPorts

# 先确定连接 FPGA P110 的串口；不要猜 COM18/COM19。
# 关闭 VOFA+ 或其他占用同一串口的程序。
pwsh -NoProfile -File .\tools\capture-adc-uart.ps1 `
  -Port COM19 -BaudRate 115200 -Seconds 30 -Label A_periph `
  -BitFile projects/finger_piano_periph_test/artifacts/<实际编号>/results/design.bit

pwsh -NoProfile -File .\tools\capture-adc-uart.ps1 `
  -Port COM19 -BaudRate 115200 -Seconds 30 -Label B_diag `
  -BitFile projects/finger_piano_oled_integration/artifacts/<实际编号>/results/design.bit

# 已有原始 UART 日志也可以离线统计，不打开串口。
pwsh -NoProfile -File .\tools\capture-adc-uart.ps1 -InputFile <原始文本文件> -Label replay
pwsh -NoProfile -File .\tools\test-capture-adc-uart.ps1
```

每次输出到独立 `artifacts/uart-*`：

- `raw.txt`：收到的原始文本，保留行结束符和末尾残行。
- `lines.jsonl`：每行到达时的主机 UTC、相对时间、类别、错误码、CSV 数值。时间是主机接收时间，不是 FPGA 内部事件时间。
- `summary.json`：文件 SHA-256、串口设置、完整/残行数、错误码分布、错误行/秒、CSV 每通道最小/最大值、I/O 异常。

`-BitFile` 是操作者提供的文件身份记录，脚本无法从 UART 确认 FPGA 实际装载的是它。应同时保留 program 日志。脚本不会把 READY、OLED OK、串口安静或仅有 NOTE 当作 ADC 成功；`NO_ADC_DATA_OBSERVED` 不代表 ADC 一定失败，也不代表成功。

## 6. 给下一位调测 agent 的执行任务

请按顺序完成，不需要先重新跑全量 verify（用户已明确要求本轮停止全量测试）。

1. **冻结输入。** 读取当前 Git diff、两个 project.json 和本文件，确认本次码 4/5 分流改动存在、ADC 为 100000、UCF 未变。记录 A/B 实际 bitstream 路径、输入快照和 SHA-256。确认 COM 口、115200 8N1、P110→串口 RXD 与共地；不要更改已确认的电气接线。
2. **A：采集正常参照。** 使用用户已验证可输出 CSV 的外设工程 bitstream，采集 30 秒；前 10 秒释放传感器，随后分别按压 CH0/1/2，记录动作时间。保存 CSV 帧数、三通道变化、错误数。优先复用已有 bitstream，不重建成功参照。
3. **B0：保留原故障证据。** 用户仍有原故障 bitstream 时，采集 30 秒，确认 ERR=4 分布和实际速率快照。此旧文件的 4 仍有歧义，不拿它套新定义。
4. **B1：构建诊断版本。** 本次尚无新 bitstream。可先跑短单测 `sim -Project finger_piano_oled_integration -Test ads1115_ctrl_real_333333`；然后 `check -Project finger_piano_oled_integration -Stage bitstream`，再 `build -Project finger_piano_oled_integration -Stage bitstream`。检查返回码、MAP 资源、告警和实际 timing.twr。最近 UART 版本曾达 662/704 Slices，不把资源优化阶段的 500 当作现在值。不放松 warning allowlist 或约束以过门禁。
5. **经用户明确授权后**，用正式 `program -Mode Jtag ... -ConfirmHardwareWrite` 做易失写入；保持显式 cable/position 与事务内 preflight。不自动写 ISF，不沿用其他任务的一次性烧录授权。已有用户在该任务中明确授权时遵从其授权范围，不重复询问。
6. **采集 B1 并分流。** 保存 30 秒串口，先读主导错误码，再决定下一项。不要同时改时钟、OS 超时、I²C 速率和计数器。

| B1 输出 | 可以得出的结论 | 下一项精确测试 |
|---|---|---|
| `ADC ERR=4` | 实际进入 OS 超时分支 | 用逻辑分析仪或受控 UART 快照读出最近 Config 高字节、通道、wait_cnt；检查是否发送 C3E3/D3E3/E3E3，轮询 pointer=01，MSB OS 是否由 0→1。区分“器件未就绪”和“FPGA 读错/读旧值” |
| `ADC ERR=5` | master 返回协议/非预期错误，不是 OS 超时 | 在错误进入 S_ERR_STOP 前记录 controller state、m_cmd、m_ecode、issued/saw_busy、master xact；定位重复 START、无事务读写/STOP或命令完成握手问题 |
| 码 1/2/3 | 对应地址 NACK/数据 NACK/master watchdog | 结合事务字节位置和 SCL/SDA 波形检查，不再称为 OS 超时 |
| 没有 ADC 错误 | 只说明未收到错误行 | 必须另看成功帧脉冲/计数或实际 ADC 数据，不能宣告已修复 |

7. **有证据后再做单变量对照。** 若指向计数器/实现差异，先仅将 ADC 等待计数器改回参照的 32 位增量形式；下一份才只将 ADC 所用 master 的计数器改为参照位宽。不能直接覆盖公共 `i2c_master.v` 导致 DAC 一并变化。若指向并行活动，分开测试关闭 OLED、关闭 DAC，但这些只能作为诊断版本，不能以永久禁用外围功能宣告修复。
8. **回传材料。** 每个版本的 Git diff/commit、verify/单测/构建编号、bit SHA、program 日志、UART 三件套、按压时间、关键波形及最短结论。只有形成可复现的失败→修复→恢复正常采样证据后，才建议最终完整回归与正式合入。

更详细的硬件 trace 会增加寄存器和恢复原本被裁剪的位，从而改变面积及布局。记录这种观察效应，不把加 trace 后偶然正常直接当作根因修复。

## 7. 根因确认与闭环验证（2026-09-22 解决）

1. **确切根因**：
   在 `ads1115_ctrl.v` 中，优化项 O2b 引入了 `OS_WAIT_CYCLES[WAIT_BITS-1:0]`。在 ISE 14.7 XST 综合器中，对 `integer` 常量参数执行带参数边界的位切片计算异常，结果恒为 0，导致 `wait_timeout` 在 cycle 0 恒为 1'b1。首次读取 OS 位为 0 时未经等待立即误报超时退出（ERR=4）。
2. **修复措施**：
   移除参数切片，固定 `wait_cnt` 为 16-bit 寄存器，采用常量直接比较 `(wait_cnt >= OS_WAIT_CYCLES)`。
3. **成功可观测性（Option B 闭环）**：
   将三通道原始数据与 sample_valid 经 `finger_piano_stage2_top` 接入顶层，以紧凑状态机每 500 ms 串口上报 `ADC OK CH0=0xXXXX CH1=0xXXXX CH2=0xXXXX\r\n`。
4. **资源与实现**：
   消除顶层冗余寄存器并精简状态机，占用 702/704 Slices (99%)，时序 Slack +70.999 ns。构建编号：`20260922-202944-3b5f28a9` (Bit SHA-256: `9AFD94BA...`)。
5. **板级真机证据**：
   COM20 采集证据 `artifacts/uart-20260922-203101-live_adc_ok-9347e4bf`：
   `ADC ERR=4` 降至 0 次（0.0 错误/秒）；
   收到 14 帧实时三通道转换数据（CH0~2.86V, CH1~2.87V, CH2~3.40V），噪声微波动符合真实物理采样，确认根因彻底消除。

