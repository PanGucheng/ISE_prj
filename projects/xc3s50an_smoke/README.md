# XC3S50AN 工具链测试工程

用于验证本机 PowerShell 7 → SSH/SFTP → Win7 ISE 14.7 → 结果取回的完整流程。

- 器件：xc3s50an-4-tqg144，已从远端 partgen 器件库核对可用；这是测试选型。
- 顶层：counter_top，8 位同步计数器，配置初值为 0。
- 测试约束：50 MHz / 20 ns 时钟，输出相对时钟最大 10 ns；LVCMOS33。
- 没有外部数据输入，输出为计数值。时钟和输出管脚由工具分配，无实际板卡映射。
- constraintsReviewed=true 仅表示以上合成测试意图已明确，不表示板卡引脚已确认。
- 仅构建测试，不烧录。使用到开发板前必须核对实际封装、速度、时钟、电压和 LOC 引脚，并重新实现。

在根目录执行：

```powershell
pwsh -File .\ise.ps1 check -Project xc3s50an_smoke -Stage bitstream
pwsh -File .\ise.ps1 build -Project xc3s50an_smoke -Stage bitstream
```

## 已完成的真实构建验证

2026-09-13，最终构建编号：`20260913-171049-6a6ab77b`。

- 远端：fpga-vm / PanGucheng；ISE 14.7 P.20131013 (nt)。
- xst、ngdbuild、map、par、trce、bitgen 均成功，六个 *.exitcode 文件均为 0。
- 产物：`artifacts/20260913-171049-6a6ab77b/results/design.bit`，54,738 字节。
- 综合、映射、布局布线日志无错误或警告；Bitgen DRC 为 0 错误、0 警告。
- 已施加的时序约束全部满足：20 ns 时钟周期，实际最小周期 3.504 ns，周期裕量 16.496 ns；10 ns 输出要求下报告值为 8.133 ns。时序错误为 0。
- 未约束路径报告仍列出 8 条 clk PAD 到寄存器 CLK 的时钟分配路径，最大延迟 2.441 ns。不能据此声称不存在未约束路径；测试通过结论限定为工具链完成及已施加约束满足。
- 资源：8 个触发器、4 个 Slice、总计 8 个 4 输入 LUT、9 个 IOB、1 个 BUFGMUX。
- 该测试未进行行为仿真或实板烧录，不构成硬件功能验证。

首轮真实运行发现 CMD 将紧邻重定向符的退出码数字当作文件描述符，造成 exitcode 文件为空；公共工具已加空格修复，上述最终运行确认所有阶段退出码记录正确。首轮目录保留以供追溯。
