# 本机开发 + Win7 ISE 14.7

在本机 `D:\ISE_prj` 编辑工程，通过 `fpga-vm` 的 ISE 构建。无需在本机安装 ISE。依赖 PowerShell 7、ssh、sftp 和已有 SSH 密钥配置。

`fpga-vm` 默认登录远端 `PanGucheng` 账户，复用现有 `id_ed25519_fpga` 密钥，不依赖空密码登录。原 vmrun 目录中的历史测试文件保留，新构建写入 PanGucheng 的用户目录。

本机已确认安装 `C:\Program Files\PowerShell\7\pwsh.exe`，版本 7.6.5。如果新终端未识别 pwsh，可直接使用该绝对路径；不依赖 Codex 的缓存运行时。入口通过 `#Requires -Version 7.0` 拒绝旧版本 PowerShell。

## 使用

在 PowerShell 中运行：

```powershell
cd D:\ISE_prj
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 doctor
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 doctor -TransferTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 new -Project demo
```

`-ExecutionPolicy Bypass` 只作用于该进程，不修改系统执行策略。`-TransferTest` 上传并下载一个小文件并比较 SHA-256，保留测试目录供检查。

填写 `projects/demo/project.json`，把源码放入 src，把 UCF 放入 constraints。配置示例仅展示格式，器件、顶层和约束必须按实际工程填写：

```json
{
  "device": "xc6slx9-2-tqg144",
  "top": "top",
  "sources": [{"path":"src/top.v", "language":"verilog", "library":"work"}],
  "includeDirs": [],
  "includeFiles": [],
  "defines": [],
  "netlists": [],
  "ucf": "constraints/top.ucf",
  "constraintsReviewed": false,
  "optimization": "Speed",
  "optimizationLevel": 1
}
```

支持 XST 的 Verilog 和 VHDL（language 为 `verilog` 或 `vhdl`），不支持把 SystemVerilog/VHDL-2008 当作普通输入。VHDL 按 sources 顺序编译，library 通常为 work。

includeDirs 是 Verilog 头文件搜索目录，includeFiles 必须显式列出同步的头文件。netlists 列出已有 IP 网表，工具为其父目录生成 ngdbuild 搜索参数。不扫描整个源码目录，不自动生成 IP。优化目标为 Speed/Area，级别为 1/2。

文件路径限定为工程内 ASCII 相对路径，使用 `/`、无空格；不支持链接文件。宏支持 NAME 或 NAME=简单字母数字值。复杂宏应放在显式同步的头文件中。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 check -Project demo -Stage synth
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 build -Project demo -Stage synth
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 build -Project demo -Stage implement
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 build -Project demo -Stage bitstream
```

实现需要提供 UCF 并在核对时钟、引脚与时序意图后将 constraintsReviewed 设为 true。该字段是人工确认，不代替工具时序分析。默认阶段是 bitstream。

## 构建与结果

远端根目录为 `C:\Users\PanGucheng\ise-builds`。每次在独立的“工程名/构建编号”目录运行，按 xst、ngdbuild、map、par、trce、bitgen 顺序执行到目标阶段。首次综合将实际验证对应器件的许可证；doctor 的帮助检查不验证许可证。

本机结果位于 `projects/<工程名>/artifacts/<构建编号>`：

- run.json：配置快照、输入哈希、阶段、状态。
- inputs：实际上传的源码副本和生成的命令脚本。
- results：远端日志、报告、实际生成的网表和 bit 文件。
- summary.txt：工具完成状态及需要人工检查的时序提示。

当前时序结论保守标记为 NEEDS_REVIEW。检查 timing.twr 的失败约束、未约束路径及实际覆盖范围；生成 bit 不等于时序通过或板卡验证通过。没有仿真或烧录入口。

网络中断后不要立即重复构建。通过 SSH 查看对应目录的 out/run.status 与日志，再补取：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 fetch -Project demo -RunId 20260913-120000-1234abcd
```

每次下载使用新目录，旧 results 移到 previous-*，防止文件混用。远端及本机历史目录均不自动清理。工具不自动初始化 Git 仓库。

## 排错与验证范围

- Permission denied：检查本机 SSH 别名和 IdentityFile，先运行 ssh fpga-vm whoami。
- Missing input / device：补全工程配置，失败时尚未上传。
- 综合或实现失败：查看 results 内对应阶段日志及 synthesis.srp。
- 连接中断：保留构建编号与 connection-error.txt，先确认远端状态。
- 无有效时序报告：只能报告综合/工具执行情况，不能认定时序通过。

已用 `projects/xc3s50an_smoke` 完成 XC3S50AN 的真实综合、实现及 bit 文件生成（2026-09-13）。构建编号 `20260913-171049-6a6ab77b`，六阶段返回码均为 0；此测试验证了该器件的构建环境和本次运行所需许可。实际开发板尚未验证，其他器件的许可与构建仍需分别验证。详细结果见测试工程 README.md。

工具自测命令为 `pwsh -NoProfile -File .\tools\test-tools.ps1`，使用隔离目录和模拟 SSH/ISE 验证编排错误处理，不代表真实综合通过。真实传输及远端批处理启动验证使用 `doctor -TransferTest`，只调用 ISE 帮助命令，不综合、不烧录。

另一个独立工程是 `projects/finger_piano`（手指钢琴课设：7 键单音电子琴，Spartan-3AN XC3S50AN TQ144，外部有源晶振为唯一时钟）。其实施计划见 `doc/手指钢琴ISE工程实施计划.md`，工程结构、模块说明、UCF 填写清单、仿真步骤与验证记录见 `projects/finger_piano/README.md`。该工程当前已完成 XST 综合（0 errors / 0 warnings）与三个 testbench 的远端 ISim 仿真（五组用例，含输入极性与滤波旁路，全部 PASS），但**尚未填写引脚约束、未做 implement/bitstream、未上板、未实测频率**；晶振频率、速度等级与 TQ144 引脚仍待用户提供。
