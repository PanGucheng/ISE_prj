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

更多入口（仿真与验收）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 sim    -Project finger_piano -Test note_encoder
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 sim    -Project finger_piano
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 verify -Project finger_piano
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 report -Project finger_piano -Latest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 report -Project finger_piano -RunId <构建编号> -Json
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 board-check -Project finger_piano
```

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

## 仿真与验收（sim / verify / report）

这三个入口把「手工拼 fuse + prj + run_all.tcl + 远程 CMD + SFTP + grep PASS」的流程固化进工具，修改 RTL/Testbench 后只需跑一次 `verify`。

### 仿真用例定义（project.json）

在工程 `project.json` 里新增 `simulations` 与 `verification` 两段。**旧工程没有这两段时 `doctor/new/check/build/fetch` 行为不变**，只有调用 `sim`/`verify` 时才要求 `simulations`。

```json
{
  "simulations": [
    {
      "name": "top_active_low",
      "top": "tb_finger_piano_top",
      "sources": ["sim/tb_finger_piano_top.v"],
      "generics": {"TB_KEY_ACTIVE_HIGH": "0"},
      "timeoutSeconds": 120,
      "passPattern": "TB_FINGER_PIANO_TOP: PASS",
      "failPattern": "TB_FINGER_PIANO_TOP: FAIL"
    }
  ],
  "verification": {
    "expectImplementationBlocked": true,
    "clockName": "clk",
    "resetNames": ["rst_n", "rst_n_sync"],
    "forbiddenEdgeSignals": ["clk_2m", "audio_out"]
  }
}
```

- `sources` 只列 testbench；综合 `sources` 仍只放可综合 RTL，**testbench 绝不进入综合**。
- `generics` 即 `fuse --generic_top "名字=值"`，只在编译（elaboration）阶段生效，因此每个参数组合都会重新 fuse。
- `passPattern`/`failPattern` 用字面量子串匹配转录日志；两者都是纯文本，不参与任何 shell 拼接。
- `verification.expectImplementationBlocked` 决定 implement 门禁的期望值：`true` 时「被阻止」才算 PASS，未来 UCF 补齐后改成 `false`，工具内没有工程名特例。
- `verification.clockName`/`resetNames` 定义唯一时钟域；`forbiddenEdgeSignals` 是**绝不允许出现在 `posedge`/`negedge` 上的信号**（不是「不允许出现」——`audio_out` 仍是合法输出网）。

### sim

```powershell
pwsh -File .\ise.ps1 sim -Project finger_piano -Test note_encoder   # 单个用例
pwsh -File .\ise.ps1 sim -Project finger_piano                      # 全部 enabled 用例
```

每个用例一个独立目录 `projects/<工程>/artifacts/sim-<时间戳>-<随机>/`：`inputs/`（源码+includeFiles+TB，含 SHA-256 清单）、`generated/`（`sim.prj`、`run_all.tcl`、`sim_fuse.cmd`、`sim_run.cmd`）、`results/`（下载回来的 `fuse.log`、`fuse.exitcode`、`simulation.log`、`simulation.exitcode`、`run.status`）、`run.json`、`sim.json`、`summary.txt`。

包装脚本刻意不叫 `fuse.cmd`/`run.cmd`：CMD 解析裸命令名时先搜当前目录，本地若有 `fuse.cmd` 就会遮蔽 `settings32.bat` 加到 PATH 上的 `fuse.exe`，脚本会递归调用自己直到 CMD 中止。

固化在工具里的 ISim 规则（不必再记）：

1. 远程脚本先 `call settings32.bat`——否则生成的仿真 exe 会静默退出，什么都不打印。
2. 运行必须用 `-tclbatch run_all.tcl`（内容为 `run all` + `exit`）——否则它只加载设计就退出，testbench 根本不执行。
3. `--generic_top` 属于 fuse，不传给运行阶段。
4. **退出码 0 不算通过**：日志必须出现 `passPattern`；出现 `failPattern` 判 FAIL；两者都没有（INCONCLUSIVE）也判 FAIL。
5. 每次运行前清掉旧的 `*.exitcode`/`*.status` 与旧 exe，且每轮使用新目录，不复用上一轮产物。
6. 超时：`timeoutSeconds`（默认 120 s，fuse 阶段固定上限 300 s）超时后终止本地 SSH 会话、尽力 kill 远程 exe、写回 `TIMEOUT` 并判 FAIL。

退出码：全部选中用例 PASS 才为 0；任一 FAIL 抛错退出 1（日志与 `sim.json` 保留）。

### verify

```powershell
pwsh -File .\ise.ps1 verify -Project finger_piano
```

依次执行：配置检查 → 静态检查 → `build -Stage synth` 并解析综合报告 → 运行全部 enabled 仿真 → implement 门禁判定 → 写出 `artifacts/verify-<时间戳>-<随机>/verification.json` 与 `summary.txt`，并打印

```
==================================================
ISE PROJECT VERIFICATION
Project : finger_piano
==================================================
Configuration / Static checks / Synthesis / Simulation / Implementation gate ...
Overall                   PASS
Stage                     PRE_BOARD
```

- implement 门禁按配置判定：`constraintsReviewed=false` 且 `expectImplementationBlocked=true` 时，「被阻止」记 **PASS**；如果期望开放却被阻止、或期望阻止却开放，都记 FAIL 并使整体非零退出。
- 静态检查（`Invoke-StaticChecks`）分级 INFO/WARNING/ERROR，覆盖：`for (genvar ...)`、SystemVerilog 关键字（`logic`/`always_ff`/`always_comb`/`typedef`/`enum`/`interface` 等）、非声明的时钟/复位边沿（唯一时钟域）、禁止边沿信号、UCF 在未审核状态下出现有效 `LOC`（ERROR）或其他有效约束（WARNING）、`constraintsReviewed` 是否为 JSON 布尔、project.json 引用的文件是否都存在。**注释里的关键字只记 INFO，不会被误判为违规。**
- 仿真段若工程没有声明任何用例，`Simulation` 显示 `NOT_CONFIGURED` 并在 notes 里说明（不算失败）。

### report

```powershell
pwsh -File .\ise.ps1 report -Project finger_piano -RunId 20260914-151945-182649b0
pwsh -File .\ise.ps1 report -Project finger_piano -Latest
pwsh -File .\ise.ps1 report -Project finger_piano -Latest -Json
```

只读取已有 artifacts，**不重新构建**。对构建 run 解析：工具流程状态、XST 退出码、ERROR/WARNING 数、latch 推断数、multi-source、寄存器数、I/O 数、`design.ngc` 是否存在；同时把机器可读结果写成该 run 目录下的 `report.json`（`-Json` 会额外打印到标准输出）。`RunId` 以 `sim-`/`verify-` 开头时改为汇报该仿真/验证 run；缺失 `sim.json`/`verification.json` 时明确输出 `NOT_AVAILABLE` 并以非零退出。

时序原则：`timing.twr` 不存在 → `NOT_RUN`；存在 → `NEEDS_REVIEW`，**report 永远不会自己给出 Timing PASS**；未约束路径与失败约束必须人工阅读 `timing.twr`。

### board-check（本轮仅预留）

```powershell
pwsh -File .\ise.ps1 board-check -Project finger_piano
```

没有 `projects/<工程>/board.json` 时输出 `BOARD_CHECK: NOT_CONFIGURED` 并列出还缺什么；`board.json` 已存在时输出 `BOARD_CHECK: NOT_IMPLEMENTED`。**不猜引脚、不改 UCF、不自动设置 `constraintsReviewed`，本轮不实现烧录。**

## 排错与验证范围

- Permission denied：检查本机 SSH 别名和 IdentityFile，先运行 ssh fpga-vm whoami。
- Missing input / device：补全工程配置，失败时尚未上传。
- 综合或实现失败：查看 results 内对应阶段日志及 synthesis.srp。
- 连接中断：保留构建编号与 connection-error.txt，先确认远端状态。
- 无有效时序报告：只能报告综合/工具执行情况，不能认定时序通过。

已用 `projects/xc3s50an_smoke` 完成 XC3S50AN 的真实综合、实现及 bit 文件生成（2026-09-13）。构建编号 `20260913-171049-6a6ab77b`，六阶段返回码均为 0；此测试验证了该器件的构建环境和本次运行所需许可。实际开发板尚未验证，其他器件的许可与构建仍需分别验证。详细结果见测试工程 README.md。

工具自测命令为 `pwsh -NoProfile -File .\tools\test-tools.ps1`，使用隔离目录和模拟 SSH/ISE 验证编排错误处理，不代表真实综合通过。真实传输及远端批处理启动验证使用 `doctor -TransferTest`，只调用 ISE 帮助命令，不综合、不烧录。

另一个独立工程是 `projects/finger_piano`（手指钢琴课设：7 键单音电子琴，Spartan-3AN XC3S50AN TQ144，外部有源晶振为唯一时钟）。其实施计划见 `doc/手指钢琴ISE工程实施计划.md`，工程结构、模块说明、UCF 填写清单、仿真步骤与验证记录见 `projects/finger_piano/README.md`。该工程当前已完成 XST 综合（0 errors / 0 warnings）与三个 testbench 的远端 ISim 仿真（五组用例，含输入极性与滤波旁路，全部 PASS），但**尚未填写引脚约束、未做 implement/bitstream、未上板、未实测频率**；晶振频率、速度等级与 TQ144 引脚仍待用户提供。
