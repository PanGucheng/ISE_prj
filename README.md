# 本机开发 + Win7 ISE 14.7

在本机 `D:\ISE_prj` 编辑工程，通过 `fpga-vm` 的 ISE 构建。无需在本机安装 ISE。依赖 PowerShell 7、ssh、sftp 和已有 SSH 密钥配置。

`fpga-vm` 默认登录远端 `PanGucheng` 账户，复用现有 `id_ed25519_fpga` 密钥，不依赖空密码登录。原 vmrun 目录中的历史测试文件保留，新构建写入 PanGucheng 的用户目录。

本机已确认安装 `C:\Program Files\PowerShell\7\pwsh.exe`，版本 7.6.5。如果新终端未识别 pwsh，可直接使用该绝对路径；不依赖 Codex 的缓存运行时。入口通过 `#Requires -Version 7.0` 拒绝旧版本 PowerShell。

## finger_piano 当前开发入口

手指钢琴（`projects/finger_piano`）的目标架构、五份开发计划的依赖顺序、扩展功能与 Agent 工作边界见：

- **[`doc/README.md`](doc/README.md)** —— 架构地图、P1~P5 计划索引、当前实施状态、事实来源优先级
- **[`projects/finger_piano/AGENTS.md`](projects/finger_piano/AGENTS.md)** —— 该项目专属规则：真实硬件是 3 传感器而不是 7 键、legacy baseline 不得改写、不得猜引脚、何时才允许 `program`

任务涉及 `finger_piano` 时，**先读这两个入口，再读具体计划文档**。

## 日常流程（Toolchain Freeze v1）

**只需要这五条命令。** 底层细节（iMPACT 批处理、`fuse`、SSH staging 目录、Digilent target 语法、ISF 擦除顺序）都由工具负责，使用课程设计时不需要理解它们。

```powershell
# 修改 RTL 之后：配置检查 + 静态检查 + 综合 + 全部仿真 + implement 门禁
.\ise.ps1 verify -Project finger_piano

# 生成 bitstream
.\ise.ps1 build  -Project finger_piano -Stage bitstream

# 检查下载线（只读）
.\ise.ps1 probe  -Project finger_piano

# 临时下载调试（掉电丢失，不写内部 Flash）
.\ise.ps1 program -Project finger_piano -Mode Jtag `
    -BitFile projects\finger_piano\artifacts\<构建编号>\results\design.bit `
    -ConfirmHardwareWrite

# 最终持久化（写入 Spartan-3AN 内部 ISF，上电自动配置）
.\ise.ps1 program -Project finger_piano -Mode Isf `
    -BitFile projects\finger_piano\artifacts\<构建编号>\results\design.bit `
    -ConfirmHardwareWrite
```

没有 `-ConfirmHardwareWrite` 时 `program` **只做预览**，不会写 FPGA，也不会写 ISF。
`program` 的结论里 `programmingVerified = VERIFIED` **不等于**设计在板上能用；板卡功能永远单独判定。

## 冻结的正式命令集合（不再新增烧录模式）

| 命令 | 作用 |
|---|---|
| `doctor` | 本机/远端环境与传输自检 |
| `new` | 新建工程骨架（器件与源文件需自行填写） |
| `check` | 只做配置与门禁检查，不构建 |
| `build` | 从新目录构建到 `synth` / `implement` / `bitstream` |
| `fetch` | 按构建编号补取远端结果 |
| `sim` | 运行 `project.json` 里的仿真用例 |
| `verify` | 主验收入口：配置+静态+综合+全部仿真+implement 门禁 |
| `report` | 只读汇总已有 artifacts（不重新构建，时序永不自动 PASS） |
| `probe` | **只读** JTAG 链检测 |
| `probe-diag` | 下载线 / Adept 层诊断实验工具 |
| `program -Mode Jtag` | 易失 FPGA 配置 |
| `program -Mode Isf` | Spartan-3AN 内部 ISF 持久化写入 |
| `board-check` | 板卡约束比对（缺少 `board.json` 时 `NOT_CONFIGURED`） |

工具链的完整冻结说明见 **`doc/ISE工具链最终状态.md`**（其中的第 12 节说明如何在 ISE 图形界面里打开工程副本）。

想在 ISE 14.7 GUI 里自己打开工程看代码时（可选，不影响工具链）：

```powershell
pwsh -File .\tools\make-gui-project.ps1 -Project finger_piano   # 生成 gui-project\<工程>.xise（GBK，中文注释不乱码）
pwsh -File .\tools\convert-encoding.ps1 -Path <文件或目录> -From Gbk -To Utf8   # 把 GUI 里改过的文件转回仓库编码
```

生成时会额外把 `includeFiles`（如 `finger_piano_cfg.vh`）复制一份到工程根目录：
ISE 14.7 的层次解析器和 ISim/fuse 在 Simulation 视图下**不读** `Verilog Include
Directories`（那是 Synthesis Options / XST `-vlgincdir`），只默认搜索**工程目录**，
所以 `include "finger_piano_cfg.vh"` 需要在工程根就能找到，否则 GUI 里无法仿真。
该副本只存在于 VM 的只读视图工程里，仓库不受影响。改动 `finger_piano_cfg.vh` 后
需要重新运行本脚本。

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
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 probe       -Project finger_piano
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 probe-diag  -Project finger_piano -Iterations 8 -DiagSession Ssh
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 program -Project finger_piano -Mode Jtag -BitFile <path>
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 program -Project finger_piano -Mode Isf  -BitFile <path> -ConfirmHardwareWrite
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
    "failOnSynthesisWarnings": true,
    "synthesisWarningAllowlist": [
      { "id": "Xst:2677", "pattern": "Node <u_sys/u_pressure/u_capture/", "expected": 49 }
    ],
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
- `verification.failOnSynthesisWarnings`（可选）为 `true` 时，XST warning 数 > 0 会让 verify 的 synthesis 与 overall 判 FAIL；**不配置时保持旧行为**（只报告 warning 数，不影响结论）。`report` 永远是纯事实输出，不受该策略影响。
- `verification.synthesisWarningAllowlist`（可选，需与 `failOnSynthesisWarnings=true` 同用）是一份**人工审阅过**的 XST 精简告警白名单：`{ id, pattern, expected }`，`pattern` 是匹配 warning 正文的正则，`expected` 是该条在本设计上审阅确认的出现次数。verify 逐条分类原始 `synthesis.srp`（**不改写报告**）：命中白名单的算 allowed，其余 warning、新出现的路径/类别、或任一条 `expected` 计数发生变化都判 FAIL 并写入 `verification.json`。这是为「有意被综合器裁掉的仿真专用 debug/status 层级」准备的窄口径例外，不是全局静音，工具内没有工程名特例。
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
6. 超时：`timeoutSeconds`（默认 120 s）超时后终止本地 SSH 会话、尽力 kill 远程 exe、写回 `TIMEOUT` 并判 FAIL；fuse 阶段超时为 `max(300, timeoutSeconds)`，即至少 300 s。

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

只读取已有 artifacts，**不重新构建**。对构建 run 先逐项判定产物是否齐全：`results/` 目录、`synthesis.srp`、`synth.exitcode`、`run.status`、`design.ngc`（implement/bitstream run 还要求 `translate/map/par/timing/bitgen` 的退码与 `design.ngd`、`mapped.ncd`、`routed.ncd`、`timing.twr`、`design.bit`）。

- 工具流程 **COMPLETE 但关键产物缺失**（或 `results/`、`run.status` 缺失）→ 判 `NOT_AVAILABLE`，在控制台与 `report.json.artifacts.missingFiles` 里列出缺什么，并**以非零退出**；
- 工具流程本身 **FAILED** → 判 `AVAILABLE` + `synthesis: FAIL`（缺失文件是失败证据，不是数据缺失），退出码仍为 0，事实照常输出。

随后解析：工具流程状态、XST 退出码、ERROR/WARNING 数、latch 推断数、multi-source、寄存器数、I/O 数、`design.ngc` 是否存在；同时把机器可读结果写成该 run 目录下的 `report.json`（`-Json` 会额外打印到标准输出）。`RunId` 以 `sim-`/`verify-` 开头时改为汇报该仿真/验证 run；缺失 `sim.json`/`verification.json` 时明确输出 `NOT_AVAILABLE` 并以非零退出。

时序原则：`timing.twr` 不存在 → `NOT_RUN`；存在 → `NEEDS_REVIEW`，**report 永远不会自己给出 Timing PASS**；未约束路径与失败约束必须人工阅读 `timing.twr`。

### board-check（本轮仅预留）

```powershell
pwsh -File .\ise.ps1 board-check -Project finger_piano
```

没有 `projects/<工程>/board.json` 时输出 `BOARD_CHECK: NOT_CONFIGURED` 并列出还缺什么；`board.json` 已存在时输出 `BOARD_CHECK: NOT_IMPLEMENTED`。**不猜引脚、不改 UCF、不自动设置 `constraintsReviewed`。**（烧录已经实现，见 `program`；`board-check` 本身仍是占位入口。）

## JTAG 探测与烧录（probe / program）

`probe` 是**只读**的；`program` 是**硬件写操作**，默认只预览，必须显式加 `-ConfirmHardwareWrite` 才会真正写入。

```powershell
pwsh -File .\ise.ps1 probe   -Project finger_piano
pwsh -File .\ise.ps1 program -Project finger_piano -Mode Jtag -BitFile .\design.bit     # 预览
pwsh -File .\ise.ps1 program -Project finger_piano -Mode Isf  -BitFile .\design.bit -ConfirmHardwareWrite
```

两个模式含义不同，不允许混用：

| 模式 | 含义 | 掉电后 | iMPACT 命令 |
|---|---|---|---|
| `-Mode Jtag` | 通过 JTAG 配置 FPGA 本体 | **VOLATILE**，掉电丢失 | `assignFile -p N -file x.bit` + `program -p N -onlyFpga` |
| `-Mode Isf` | 编程 Spartan-3AN **内部 In-System Flash（ISF）** | **NON-VOLATILE**，上电自动配置 | `assignFile -p N -file x.bit` + **`program -p N -e -v`** |

**这里的关键（全部由真机实测得到，2026-09-14，XC3S50AN）**：同一个 `assignFile` + `program`，加不加 `-onlyFpga` 是**两件完全不同的事**：

- **不加 `-onlyFpga`** → iMPACT 写**内部 ISF**（转录出现 `SPI access core not detected`、下载 `spartan3a/data/xc3s50an_spi.cor`、`Address ... is in sector/page ...`、`'1': Programming Flash...done`）。这就是 `-Mode Isf` 的路径。
- **加 `-onlyFpga`** → iMPACT 只配置 **FPGA 本体**（转录为 `'1': Programming device...` → `'1': Completed downloading bit file to device` → `'1': Programming completed successfully` → `Checking done pin....done`），**全程没有 SPI core、没有 Programming Flash、没有 sector/page**。这就是 `-Mode Jtag` 的路径。
- **`-onlyFpga` 与 `-v` 不能同时用**：FPGA 回读校验需要 BitGen `-m` 生成的 mask 文件，否则 `ERROR:Bitstream:2 - The input file ".../design.msk" does not exist`。因此 Jtag 模式**默认不加 `-v`**，Isf 模式**保留 `-v`**（它是 ISF 的 in-step 校验）。
- **`assignFileToAttachedFlash` / `program -spi` 不适用**：那条路是给**外挂** SPI/BPI PROM 用的（Xilinx 所谓 indirect SPI programming），对 3AN 会报 `ERROR:iMPACT - No attached device found at position '1'`。内部 ISF 不需要它。
- **不跑独立 `verify`**：实测 `verify -p 1` 与 `verify -p 1 -sram` 都会回 `'1': Verifying device...Verify failed on page 0.`——哪怕紧接在一次 iMPACT 自己已 `Verification completed successfully` 的写入之后。所以工具的校验结论取自 **program 转录本身**（`Verification completed successfully` → `VERIFIED`；出现 `Verify failed` → `FAIL`；仅 FPGA 配置且 `DONEIN=1 / CRC error=0` → `CONFIG_STATUS_OK`）。

**副产品**：FPGA 直接配置的转录会打印器件状态寄存器，工具把它解析出来（`run.json` 的 `configurationStatus`）并在摘要里显示，例如真机读到的 `MODE pins M[2:0] = 011`（内部 Master SPI 启动模式）、`DONEIN input from Done Pin = 1`、`CRC error = 0`、`VSEL pin 0/1/2 = 1/1/1`。这为「ISF 启动所需的 `M[2:0]=011`」提供了**来自硬件的证据**，而不是只靠跳线猜测。

### 正式烧录固定下载线（不再 `-p auto`）

```json
"programming": {
  "cableType": "digilent",
  "cableSerial": "210241672559",
  "cableFrequencyHz": 10000000,
  "position": 1
}
```

生成的 `setCable` 一律是显式目标：

```
setCable -target "digilent_plugin DEVICE=SN:210241672559 FREQUENCY=10000000"
```

- **`cableFrequencyHz` 必须来自真实转录**（本机 52 条成功转录一致给出 `JTAG Clock Frequency: 10000000 Hz`）。配置缺失时工具**直接报错停止**，`probe-diag` 也只会打印 `explicit SN test skipped: NO_MEASURED_CABLE_FREQUENCY`——**任何情况下都不默认 10000000**。
- **`-p auto` 只保留在 `probe-diag`**（诊断用）。正式 `probe` / `program` 不会再自动扫描下载线。
- 每次 program 的摘要都输出 cable identity：`Cable provider / Cable serial / Cable target / Cable frequency`，并附上**转录里实际出现的序列号**；若与配置不符 → `CABLE MISMATCH` 判 FAIL。

### 一次硬件事务：preflight 与写入之间没有空闲窗口

本机只做**静态**检查（工程配置、bitstream 头、SHA-256、期望器件、已确认的下载线序列号、`-ConfirmHardwareWrite`），然后**一次性上传**全部脚本与 bitstream，由远端**一个** `hardware_transaction.cmd` 完成：

```
hardware_transaction.cmd
  ├─ phase 1  impact -batch probe.cmd      （只读 preflight）
  │    要求同一组成功标记：Digilent 打开下载线 + Added Device <part> + <IDCODE>
  │    不通过 → goto preflight_retry（同一事务内立即重试，最多 4 次）
  │              仍不通过 → run.status=PREFLIGHT_FAILED，program.cmd 绝不执行
  └─ phase 2  impact -batch program.cmd    （紧接着，无 sleep / 无 SSH / 无 SFTP / 无本地解析）
```

实测动机：**下载线刚被打开过时可以稳定重开，静置几秒后再打开则容易出现
`failed to open device (DmgrOpenEx, erc = 3072)`（= `ercConnectionFailed`）**。因此
- 两个 iMPACT 调用之间**没有任何往返或等待**；
- 重试发生在**同一个远端事务内部**，且退避是 **150 ms 而不是几秒**；
- 只有「转录里完全没有写入迹象」时才允许重试（`programming.cableRetryAttempts`，默认 3）；一旦出现 `Programming device` / `Programming Flash` / `Completed downloading` / `Programmed successfully` / `Verifying` / `TIMEOUT` / SSH 中断，**绝不重试**；
- 事务用 `exit /b 2`（preflight 失败）与 `exit /b 3`（环境失败）表达**预期结果**，工具据 `run.status` 判定，不会误当成 `PROGRAM_STATE_UNKNOWN`。

### ISF 写入必须显式擦除并受门禁约束

`-Mode Isf` 使用 **`program -p N -e -v`**（`-e` = erase）。

> **根因（工程结论，措辞已冻结）**：旧 ISF 流程在**重写非空 ISF 时没有显式执行擦除**。加入 `-e` 后，iMPACT 明确完成 `Erase → Program → Verify`，原先稳定出现的 page 0 verify failure 消失。因此工程上将「缺少显式 erase」认定为本次 ISF 重写失败的根因。
> （不要写成「`program -v` 的隐式 erase 没有擦净」——没有直接证据证明旧流程真的执行过 erase。）

因此工具的判定加了**硬门禁**：
1. 必须出现 `Erasing device...`；
2. 必须出现 `Erasure completed successfully.`；
3. 且不得出现 erase 失败行。

**只有通过这三条，才会去采信 `Programming Flash...` / `Programming completed successfully` / `Verification completed successfully`。**
擦除阶段只要启动过，就视为「已经动过 Flash」→ **绝不自动重试写入**（`TIMEOUT`/`PROGRAM_STATE_UNKNOWN` 同样不重试）。摘要会明确输出 `Erase phase : seen / completed`。

### 下载线失败必须分层报告

```
DIGILENT_ENUM_FAILED   iMPACT 的 Digilent 插件报 "no JTAG device was found"
DIGILENT_OPEN_FAILED   枚举到了但 Adept 打不开：failed to open device (DmgrOpenEx, erc = 3072)
CABLE_UNAVAILABLE      iMPACT 回退到 Platform Cable/并口后仍失败
```

**「Windows 里设备存在」不能证明「Adept 能枚举/打开它」**：实测在失败前后 `wmic Win32_PnPEntity` 都显示 `USB\VID_0403&PID_6014\210241672559 Status=OK`。因此摘要明确写出这一层区别，不再声称「下载线对虚拟机不可见」。

### 结果状态模型（冻结）

文档与 `run.json` 一律使用这六个字段，不允许改名或合并：

```
cableDetected        PASS | DIGILENT_ENUM_FAILED | DIGILENT_OPEN_FAILED | CABLE_UNAVAILABLE | UNKNOWN | PENDING (checked inside the transaction)
jtagChainDetected    PASS | FAIL | INCONCLUSIVE | NOT_RUN
deviceMatched        PASS | FAIL | UNDETERMINED
programmingCompleted PASS | PASS_UNCONFIRMED | FAIL | TIMEOUT | PROGRAM_STATE_UNKNOWN | NOT_RUN
programmingVerified  VERIFIED | CONFIG_STATUS_OK | NOT_APPLICABLE | NOT_REPORTED | FAIL | TIMEOUT | NOT_RUN
userDesignFunctional NOT_TESTED
```

- **`programmingVerified = VERIFIED` 不等于 `userDesignFunctional = PASS`。**前者只说明 iMPACT 转录里的擦除/编程/校验过程完成；后者需要板卡上真实的功能测量。
- 工具**永远**不会仅凭烧录结果打印 `BOARD PASS`；`userDesignFunctional` 的固定值是 `NOT_TESTED`。

### 已否定 / 已撤回的历史结论（HISTORICAL · SUPERSEDED）

以下结论都曾被写进文档，随后被真机实验否定。保留在此仅作追溯，**不得再作为依据**：

| 已否定结论 | 真机实验如何推翻 |
|---|---|
| “Spartan-3AN 经 iMPACT 批处理没有易失 SRAM 配置路径” | `program -p N -onlyFpga` 实测为**纯 FPGA fabric 配置**（`Programming device` → `Completed downloading bit file to device`，无 SPI/Flash 行），连续两次 PASS |
| “`-onlyFpga` 属于需要 `.msk` 的另一条流程，不是易失配置” | 只有 **`-onlyFpga` + `-v`** 才要求 BitGen 的 `.msk`；去掉 `-v` 即为正常易失配置 |
| “`assignFileToAttachedFlash` 是写内部 ISF 的路径” | 它是**外挂** PROM 的 indirect SPI 流程，对内部 ISF 报 `No attached device found at position '1'`；内部 ISF 用 `assignFile` + `program` |
| “`program -p N -v` 足以可靠重写 ISF” | 在**非空** ISF 上重写时恒定 `Verify failed on page 0`；改为 `program -p N -e -v` 后一次通过 |
| “USB/JTAG cable is not visible inside fpga-vm（`CABLE_NOT_FOUND`）” | 失败前后 Windows PnP 都显示设备 `Status=OK`；真实失败发生在 Adept 枚举/打开层 |
| “Session 0（SSH 服务会话）是下载线失败主因” | Session 0 与交互会话（Task Scheduler InteractiveToken）的 A/B 失败形态几乎镜像，不足以支持该结论；该假设已放弃（不再继续研究） |

**JTAG 编程使用下载线产生的 TCK，不依赖用户时钟。** 因此即使 12 MHz 有源晶振没插/没起振，只要 FPGA 供电、JTAG 与下载器正常，`probe`（链路识别）与 `program` 都应该能工作；反过来，烧录成功也**不代表**用户设计能跑（手指钢琴需要 12 MHz 时钟才能发声）。

### iMPACT batch 命令是实测得到的，不是猜的

本轮在真实 Win7/ISE 14.7 上做了如下探测，结论写进了工具：

| 实测项 | 结果 |
|---|---|
| `impact -batch <file>` | 可无 GUI 运行，输出重定向到日志 |
| `help`（在 batch 内） | 打印本安装支持的完整命令表，含 `assignfiletoattachedflash`、`attachflash`、`blankcheck`、`readidcode`、`checkidcode`、`erase`、`program`、`verify`、`setmode`、`setcable` 等 |
| `help -m program` / `-m verify` / `-m erase` / `-m identify` | 打印这些命令的权威语法（`-spi[<part>]`、`-spionly`、`-p|-position`、`-e|-erase`、`-v|-verify` 等）；其余命令 `help -c` 只回显名字 |
| 顺序要求 | 除 `setMode` 外一切命令都报 `ERROR:iMPACT:351 - setMode is required before this operation.`，所以脚本必须 `setMode` 优先 |
| `setMode -bs` / `-bscan` | 均被接受（RC=0）；`setMode` 空参 → `ERROR:iMPACT:339 - Mode string is required` |
| `setCable -p auto` | 通过 Digilent 插件枚举/打开下载器（实测枚举到 Digilent JTAG-HS2，SN 210241672559，TCK 10 MHz） |
| `assignFile -p N -file X`、`assignFileToAttachedFlash -p N -file X` | 语法均被接受（无链时只报 `ERROR:iMPACT:589 - No devices on chain, can't assign file`，未报参数错误）。**注意**：`assignFileToAttachedFlash` 只适用于**外挂** SPI/BPI PROM，用它写内部 ISF 会报 `No attached device found at position '1'`（见下方 HISTORICAL 说明） |
| `listUsbCables` | 只认 Xilinx Platform Cable USB，实测在有 Digilent 线时仍报“未检测到 Platform Cable”→ **不能**用作通用下载线探测 |
| `blankCheck`（未先 setMode） | iMPACT 直接崩溃（RC `-1073741819` = 0xC0000005），因此工具绝不乱序调用 |
| **退出码可信度** | **不可靠**：同一条失败的 `identify` 一次返回 0、一次返回 1。工具因此只把退出码当记录，判定一律解析转录日志 |
| **无下载线的转录** | iMPACT **不会**把「打不开下载线」写成 `ERROR:`：它打印 `Digilent Plugin: no JTAG device was found.` / `Cable autodetection failed.`，而 runner 的状态文件仍是 `COMPLETE`。工具因此显式识别这些行，否则会把它误判成「未确认的成功」 |
| **裸 `verify -p N` 无参照** | 没有先 `assignFile` 时 `verify -p N` 会报 `'1': Verifying device...Verify failed on page 0.` / `Verification Terminated`（实测）。所以 verify 脚本必须先把同一份 bitstream 指定给器件/Flash，工具并把 `Verify failed` 判为 FAIL 而不是「无结论」 |
| XC3S50AN IDCODE | `0x02610093`，取自本安装自带的 `spartan3a/data/xc3s50an_tq144_1532.bsd`（工具在 probe 时读取该 BSDL 作为期望值并留档） |

### probe 的输出与判定

```
ISE PROGRAMMER PROBE

iMPACT          PASS
Cable           PASS | CABLE_NOT_FOUND | UNKNOWN
JTAG chain      PASS | FAIL | INCONCLUSIVE | NOT_RUN

Position 1:
  Device        <器件名或 UNKNOWN>
  IDCODE        0x........

Expected        xc3s50an
Match           YES | NO | UNDETERMINED
Result          PASS | FAIL
```

- 下载线不可用时按**分层**状态报告（`DIGILENT_ENUM_FAILED` / `DIGILENT_OPEN_FAILED` / `CABLE_UNAVAILABLE`），**不修改 VM 配置、不自动 USB attach**，只报告。
  > **HISTORICAL / 已废弃**：早期输出 `CABLE_NOT_FOUND` 与 “USB/JTAG cable is not visible inside fpga-vm”。该措辞已被真机实验否定（设备在 Windows 里存在且状态正常时，Adept 层仍可能打不开），不再使用。
- 只有「下载线 PASS + 链 PASS + 器件匹配」才 PASS；解析不出器件时是 `UNDETERMINED`/`FAIL`，**绝不伪造成 PASS**。
- probe 会下载对应 BSDL 到 `artifacts/probe-*/inputs/fpga.bsd` 作为期望 IDCODE 的依据与留档。
- 本 ISE 版本的 `identify` 只打印器件名、**不打印 32 位 IDCODE**；工具因此额外执行 `readIdcode -p 1`，其输出形如 `'1': IDCODE is '02610093' (in hex)`（工具同时能解析十六进制与 32 位二进制两种写法，并把 IDCODE 归到对应 position）。
- **实测（2026-09-14 20:26，板卡供电后）**：`probe` **PASS** —— `Cable PASS`、`JTAG chain PASS`、Position 1 = `xc3s50an`、`IDCODE 0x02610093`（与本安装 `spartan3a/data/xc3s50an_tq144_1532.bsd` 的期望值完全一致）、`Match YES`。
- **已知环境问题**：fpga-vm 的 USB 透传不稳定，连续多次运行常出现 `Digilent Plugin: no JTAG device was found`（实测约一半概率），稍等或重试即可；这是 VM/USB 侧问题，与工具和板卡无关。

### program 的安全与状态模型

- 强制 preflight：每次 `program` 先自动做一次与 `probe` 等价的只读检查（iMPACT 可执行、下载线、链、目标 position、器件系列匹配、bit 文件存在且非空）。
- `-Position`：**不假定 position=1**。链上恰好一个器件才自动选 1；多于一个器件而未指定 → `ERROR: Multiple JTAG devices detected; specify -Position.`。
- bit 文件：解析 `.bit` 头部并与 JTAG 实物对照，支持两种真实格式——iMPACT/promgen 的文本头（`Target Device/Package/Speed`）与 **bitgen 实际写出的紧凑头**（`<a|b|c|d><长度高字节><长度低字节><数据>0x00`，`a`=设计名、`b`=器件、`c`=日期、`d`=时间；例如真实 `design.bit` 的 `b` 字段为 `3s50antqg144`，归一化为 `xc3s50antqg144`）。比较时只做「去掉 `xc` 前缀 / 补齐 `xc` 前缀」的等价，**不发明**软件包等价规则（`tq144` 不等于 `tqg144`）；bitgen 头里没有速度等级，工具就报 `speed not in header`，**不猜**。两种头都解析不出来时明确写 `NOT_PARSED` 并依赖 iMPACT 自身的器件兼容检查。
- 无 `-ConfirmHardwareWrite` → `PREVIEW ONLY`：打印 cable / chain / device / position / bitstream / mode 后立即结束，**不下载写脚本、不执行 program**（连 `program.cmd` 都不会生成）。
- 超时：`Jtag` 与 `Isf` 用不同超时（默认 300 s / 600 s，probe 120 s，verify 300 s，可在 project.json 的 `programming` 段覆盖）。超时 → 非零退出、保留日志、标记 `TIMEOUT`，**不自动重烧**。
- SSH 在写入过程中断开 → `PROGRAM_STATE_UNKNOWN`：因为无法确定第一次写操作进行到哪一步，工具**不会自动重试**，并要求先重新 `probe`、查看远端 `run.status`、取回原日志，再决定是否重烧。
- 状态严格分开，前五项由工具判断，最后一项永远是 `NOT_TESTED`：

```
cableDetected        PASS / CABLE_NOT_FOUND / UNKNOWN
jtagChainDetected    PASS / FAIL / INCONCLUSIVE / NOT_RUN
deviceMatched        PASS / FAIL / UNDETERMINED
programmingCompleted PASS / PASS_UNCONFIRMED / FAIL / TIMEOUT / PROGRAM_STATE_UNKNOWN / NOT_RUN
programmingVerified  VERIFIED / NOT_APPLICABLE / NOT_REPORTED / FAIL / TIMEOUT / NOT_RUN
userDesignFunctional NOT_TESTED
```

**Verify 默认开启，禁止默认关闭。** JTAG 直配若 iMPACT 表示 verify 不适用，工具据日志报 `NOT_APPLICABLE`；日志没给结论就报 `NOT_REPORTED`；**任何情况下都不伪造 verify 通过**。烧录成功也不会打印 `BOARD PASS`。

`-Mode Isf` 在执行前一定会打印持久启动的硬件前置条件（JTAG 无法证明板上跳线是否正确）：

```
Persistent boot requirements:
  Internal Master SPI mode M[2:0] = 011
  VCCAUX = 3.3 V
```

### 产物与配置

每次操作一个独立目录 `projects/<工程>/artifacts/{probe,program}-<时间戳>-<随机>/`：`run.json`（operation/project/mode/device/position/bitFile/bitFileSha256/result/时间戳等，**不含任何凭据**）、`inputs/`（bit 文件与 BSDL 副本）、`generated/`（`probe.cmd`、`program.cmd`、`verify.cmd`、`run_*.cmd`、`probe.expected.txt`）、`results/`（各步 `*.log`、`*.exitcode`、`*.status`）、`summary.txt`。`artifacts/` 仍被 `.gitignore` 排除。

可选配置（`project.json`）：

```json
"programming": {
  "cablePort": "auto",
  "probeTimeoutSeconds": 120,
  "jtagTimeoutSeconds": 300,
  "isfTimeoutSeconds": 600,
  "verifyTimeoutSeconds": 300
}
```

### 真实硬件观察（2026-09-14 当天，未做任何写入）

> **HISTORICAL**：本节是 09-14 当天的原始观察，其中出现的 `CABLE_NOT_FOUND` 是旧工具当时的粗粒度结论。后续实测已把下载线失败细分为 `DIGILENT_ENUM_FAILED`（`no JTAG device was found`）/ `DIGILENT_OPEN_FAILED`（`failed to open device (DmgrOpenEx, erc = 3072)` = `ercConnectionFailed`）/ `CABLE_UNAVAILABLE`，并确认「Windows PnP 里设备存在 **不等于** Adept 能打开」。因此**不再使用「下载线对虚拟机不可见」这一表述**，Adept 层失败也不得说成虚拟机看不见设备。

- 16:19 手工探测时，Digilent JTAG-HS2 **可见**（`found 1 device(s)`），但 `identify` 报 iMPACT 的硬件配置错误（链未识别）。
- 16:27 / 16:28 通过工具再探测两次，Digilent 插件报 `no JTAG device was found`，即**下载线在两次之间从 fpga-vm 中消失**（USB 透传/硬件状态问题，非工具差异；用同一份脚本手工复跑得到同样结果）。
- **20:26 / 20:29 `probe` 真实 PASS**：`Cable PASS`、`JTAG chain PASS`、Position 1 = `xc3s50an`、`IDCODE 0x02610093`、`Match YES`（run `probe-20260914-202618-d161523e`、`probe-20260914-202941-bbbebd63`）。
- **20:48 起下载线又不可见**（`probe-20260914-204823-414a4508`、`probe-20260914-205006-a9df9206` 均为 `CABLE_NOT_FOUND`），同一时段 `program -Mode Jtag` 的 preflight 因此判失败并明确输出 `nothing was written`。这与上面的 USB 透传不稳定一致，属环境问题。
- **（HISTORICAL，仅描述 09-14 当天）当天没有执行过任何 `program` 写入**：`program` 在 `-ConfirmHardwareWrite` 之外只做 PREVIEW（本次 preflight 未过时甚至连 PREVIEW 段落都不会生成写脚本）。**该状态已被 09-15 的真机写入取代**：`-Mode Jtag` 连续两次 PASS、`-Mode Isf`（`program -p 1 -e -v`）一次通过，见上文「ISF 写入必须显式擦除」与 `projects/finger_piano/README.md` §13 第七轮。
- 真实 `design.bit`（finger_piano，54 738 字节）验证了 bitgen 头解析：`bitstream target : xc3s50antqg144 (header: BITGEN; package not in header; speed not in header)   match: YES`。

## 排错与验证范围

- Permission denied：检查本机 SSH 别名和 IdentityFile，先运行 ssh fpga-vm whoami。
- Missing input / device：补全工程配置，失败时尚未上传。
- 综合或实现失败：查看 results 内对应阶段日志及 synthesis.srp。
- 连接中断：保留构建编号与 connection-error.txt，先确认远端状态。
- 无有效时序报告：只能报告综合/工具执行情况，不能认定时序通过。

已用 `projects/xc3s50an_smoke` 完成 XC3S50AN 的真实综合、实现及 bit 文件生成（2026-09-13）。构建编号 `20260913-171049-6a6ab77b`，六阶段返回码均为 0；此测试验证了该器件的构建环境和本次运行所需许可。实际开发板尚未验证，其他器件的许可与构建仍需分别验证。详细结果见测试工程 README.md。

工具自测命令为 `pwsh -NoProfile -File .\tools\test-tools.ps1`，使用隔离目录和模拟 SSH/ISE 验证编排错误处理，不代表真实综合通过。真实传输及远端批处理启动验证使用 `doctor -TransferTest`，只调用 ISE 帮助命令，不综合、不烧录。

另一个独立工程是 `projects/finger_piano`（手指钢琴课设：7 键单音电子琴，Spartan-3AN XC3S50AN TQ144，板上 P57 的 **12 MHz** 有源晶振为唯一时钟）。第一阶段的实施计划已归档到 `doc/archive/手指钢琴ISE工程实施计划.md`，第二阶段的 4 份分阶段计划（3-bit LM393 编码输入、DDS 正弦音频发生器、DDS→MCP4725 数字音频链路集成、ADS1115 压力数据处理与标定）与可选外设计划（ADS1115/MCP4725）见 `doc/` 目录，工程结构、模块说明、引脚分配、仿真步骤与验证记录见 `projects/finger_piano/README.md`。该工程当前已完成 XST 综合（0 errors / 0 warnings）、三个 testbench 的六个远端 ISim 用例（默认、极性两种取值、滤波旁路、12 MHz 频率算术，全部 PASS）、静态检查、**带真实引脚约束（P57/P3/P4–P11/P12/P13–P21/P24–P27，LVCMOS33）的实现与 bitstream 生成**（run `20260914-204555-24cabc5e`，MAP/PAR/bitgen 均 0 errors / 0 warnings，`design.bit` 54 738 字节）；`TS_clk = PERIOD 83.33 ns` 实测 **0 timing errors、最差 slack 70.697 ns**（该结论来自本人阅读 `timing.twr`；UCF 没有 `OFFSET IN/OUT`，因此板级 I/O 时序未认证，工具 `summary.txt` 仍为 `NEEDS_REVIEW`）。**烧录已真机跑通**：`-Mode Jtag`（易失）连续两次 PASS（`program-20260915-003257-7ef9c0de`、`program-20260915-003321-faf98f9b`），`-Mode Isf`（非易失，`program -p 1 -e -v`）一次通过（`program-20260915-083244-bf54acda`，`Erase → Program → Verify` 全部成功）；但**板卡功能仍未验证**——未做断电保持启动测试、未实测音高（`userDesignFunctional` 固定为 `NOT_TESTED`，工具永不打印 `BOARD PASS`）。芯片速度等级仍为占位 `-4`，待用户按丝印确认。
