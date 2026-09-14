# 本机源码与远程 ISE 工作规则

## 环境与入口

- 本机工作根目录是 `D:\ISE_prj`。工程在 `projects/<工程名>` 下，共用根目录的 `ise.ps1`。
- ISE 位于 Win7 32 位主机 `fpga-vm`，通过现有 SSH 密钥连接。环境入口是 `C:\Xilinx\14.7\ISE_DS\settings32.bat`。
- Codex 在本机运行，以 SSH 执行构建。不依赖 Win7 上的 Codex App Server。
- `fpga-vm` 默认账户为 `PanGucheng`，使用原有 `id_ed25519_fpga` 密钥；可用 `ssh fpga-vm whoami` 核对身份。旧 vmrun 构建目录保留，新构建使用 PanGucheng 账户目录。
- 开始工作时先读 README.md 和目标工程 project.json。首次使用、连接失败或环境变化时运行 `pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 doctor`。
- 优先使用工具入口，避免绕过配置手工构建。操作前明确工程；多个候选且用户未指定时询问。

## 配置与修改

- 在本机编辑源文件、UCF 和 project.json，远端仅作独立构建副本。
- 必须明确完整器件型号、顶层及有序源文件清单。不得猜测封装、速度等级、引脚、板卡时钟。
- `constraintsReviewed=true` 表示已确认约束意图；不得为绕过检查自动设为 true。需要实现时，先核对 UCF 的时钟、引脚及设计要求。
- 新工程模板故意留空器件和源文件；不能直接构建。已有 IP 的包含文件和网表需显式列入配置，不自动重新生成 CoreGen IP。
- 首期支持 ISE XST 的 Verilog/VHDL，不假设支持 SystemVerilog 或 VHDL-2008。源码包含关系和 VHDL 编译顺序由工程明确维护。
- 路径使用工程内 ASCII 相对路径，无空格；不得使用链接文件或越界路径。`includeFiles` 显式列出需要同步的头文件，`includeDirs` 只控制搜索路径。

## 构建与判定

- 先 `check -Project <名称> -Stage <阶段>`，再 `build`。阶段为 synth、implement、bitstream，每次从新目录完整执行到指定阶段。
- 保留构建编号、配置快照、输入 SHA-256、日志和结果。不要用上次构建的产物补齐本次缺失文件。
- 检查阶段返回码和预期输出；综合通过、工具流程完成、时序满足约束、板卡可用是不同结论。
- `summary.txt` 的时序默认是 NEEDS_REVIEW。必须实际阅读 timing.twr 中的约束结果与未约束路径后才能报告时序结论；无时序报告时不得声称通过。
- 连接中断不自动重启构建。先检查远端对应编号的 run.status 和日志，必要时 `fetch` 补取结果。
- 汇报工程、构建编号、执行阶段、通过/失败、关键错误和结果位置。失败时保留原始日志，说明下一步。
- `xc3s50an_smoke` 是已跑通的工具链测试，采用 xc3s50an-4-tqg144 和合成测试约束；不得把其自动分配的引脚或时钟假设直接套用于实际板卡。该工程 README.md 记录已完成构建与时序覆盖限制。

## 仿真与验收

- 修改 RTL 或 Testbench 后的主验收入口是 `pwsh -File .\ise.ps1 verify -Project <名称>`：依次执行配置检查、静态检查、synth 综合、project.json 中全部 enabled 仿真、implement 门禁判定，并写出 `artifacts/verify-<id>/verification.json` 与控制台报告；任一项 FAIL 时退出码非零。
- 单个仿真用 `pwsh -File .\ise.ps1 sim -Project <名称> -Test <名称>`。用例定义在 project.json 的 `simulations` 段（`name/top/sources/generics/timeoutSeconds/passPattern/failPattern`，可加 `enabled`）；testbench 绝不加入综合 `sources`。
- sim 的判据是日志出现 `passPattern`：退出码 0 不算通过，既无 PASS 也无 FAIL 视为 FAIL；generic 覆盖只在 fuse 阶段生效，每次参数组合重新 fuse；超时会终止本地 SSH 会话并判 FAIL。
- `pwsh -File .\ise.ps1 report -Project <名称> (-RunId <id> | -Latest) [-Json]` 只读取已有 artifacts，不重新构建；`timing` 在有人实际阅读 timing.twr 之前只能是 `NOT_RUN`/`NEEDS_REVIEW`，不得据此声称时序通过。
- implement 是否应当被阻止由 project.json 的 `verification.expectImplementationBlocked` 决定（当前为 `true`）。verify 以此判定 EXPECTED BLOCK 是否 PASS，工具内不写工程名特例。
- `board-check` 目前只在缺少 `board.json` 时输出 `BOARD_CHECK: NOT_CONFIGURED`；不得猜测引脚，不得自动设置 `constraintsReviewed=true`，本轮不实现烧录。
- 工具自测 `pwsh -NoProfile -File .\tools\test-tools.ps1` 覆盖失败路径（fuse 失败、超时、无 PASS 模式、failPattern、门禁两个方向、report 缺文件、旧工程兼容），使用隔离目录与模拟远端，不代表真实综合或真实仿真。

## JTAG 探测与烧录

- `probe` 只读：枚举下载线、识别 JTAG 链、读 IDCODE 并与 project.json 的器件核对。下载线不可见时输出 `CABLE_NOT_FOUND` 与 “USB/JTAG cable is not visible inside fpga-vm”，**不得修改 VM 配置或自动 attach USB**，也不得伪造 PASS。
- `program` 是硬件写操作，**默认只预览**（PREVIEW ONLY：打印 cable/chain/device/position/bitstream/mode 后结束，不生成写脚本、不执行 program）。必须由用户明确要求并带 `-ConfirmHardwareWrite` 才真正写入。
- 两种模式含义不同、不得混用：`-Mode Jtag` = 通过 JTAG 直接配置 FPGA（VOLATILE，掉电丢失）；`-Mode Isf` = 编程 Spartan-3AN 内部 ISF（NON-VOLATILE，上电自动配置）。Isf 执行前必须提示 `M[2:0] = 011` 与 `VCCAUX = 3.3 V`（JTAG 无法证明板上跳线）。
- JTAG/ISF 编程用的是下载线的 TCK，与用户时钟无关；**烧录成功不等于设计工作正常**，`userDesignFunctional` 永远输出 `NOT_TESTED`，禁止打印 `BOARD PASS`。
- 每次 program 前必须自动 preflight（等价 probe + bit 文件存在且非空 + 器件匹配）；不假定 position=1，多器件未指定 `-Position` 时报 `ERROR: Multiple JTAG devices detected; specify -Position.`。
- verify 默认开启、禁止默认关闭；iMPACT 表示不适用时报 `NOT_APPLICABLE`，无结论时报 `NOT_REPORTED`，不得伪造 verify 通过。
- Jtag/Isf 使用不同超时；超时标 `TIMEOUT`、保留日志、非零退出且**不自动重烧**。SSH 在写入中断开 → `PROGRAM_STATE_UNKNOWN`，不得自动重试，先重新 `probe`、查远端 `run.status`、取回原日志再决定。
- iMPACT 退出码不可靠（同一次失败可能返回 0），判定一律解析转录日志；`setMode` 必须优先，`blankCheck` 等不得乱序调用。
- 工具只写远端受管目录，不改 ISE 安装；`constraintsReviewed` 始终保持人工确认，不得为了让工具产生 bitstream 而自动置 true。

## 凭据与操作范围

- 复用 `ssh fpga-vm` 的本机密钥配置。不要要求用户重复提供密码，不向工程或日志写入密码、私钥内容。
- 常规源码修改和构建按用户任务授权执行；本工具没有烧录入口，不自动操作 JTAG。
- 构建仅写入远端 `C:\Users\PanGucheng\ise-builds` 下的受管目录，不改系统环境变量或现有 ISE 安装。
- 不自动删除构建目录；如用户要求清理，先解析并确认绝对路径在受管根目录内，禁止删除整个用户目录或越界路径。
- 工具和目录约定改变时同步更新 README.md、AGENTS.md。不要把密钥复制进版本库；忽略 artifacts 与 tools/.work。
