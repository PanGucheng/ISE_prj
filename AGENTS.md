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

## 凭据与操作范围

- 复用 `ssh fpga-vm` 的本机密钥配置。不要要求用户重复提供密码，不向工程或日志写入密码、私钥内容。
- 常规源码修改和构建按用户任务授权执行；本工具没有烧录入口，不自动操作 JTAG。
- 构建仅写入远端 `C:\Users\PanGucheng\ise-builds` 下的受管目录，不改系统环境变量或现有 ISE 安装。
- 不自动删除构建目录；如用户要求清理，先解析并确认绝对路径在受管根目录内，禁止删除整个用户目录或越界路径。
- 工具和目录约定改变时同步更新 README.md、AGENTS.md。不要把密钥复制进版本库；忽略 artifacts 与 tools/.work。
