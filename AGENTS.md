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
- `verification.failOnSynthesisWarnings=true` 时 XST warning 会判 FAIL。若某工程确实存在“有意被综合器裁掉、无硬件消费方”的仿真专用层级，只允许用 `verification.synthesisWarningAllowlist`（逐条 `id`+`pattern`+`expected` 计数、人工审阅）做窄口径例外：verify 逐条分类原始 `synthesis.srp`（报告不改写），任何未命中条目、新路径/类别、或计数漂移仍判 FAIL。**禁止**用 `XIL_XST_HIDEMESSAGES`、全局静音、`KEEP`/`DONT_TOUCH` 或假消费者去绕过；不得为通过检查把 `failOnSynthesisWarnings` 改成 `false`。工具内不写工程名特例。
- 单个仿真用 `pwsh -File .\ise.ps1 sim -Project <名称> -Test <名称>`。用例定义在 project.json 的 `simulations` 段（`name/top/sources/generics/timeoutSeconds/passPattern/failPattern`，可加 `enabled`）；testbench 绝不加入综合 `sources`。
- sim 的判据是日志出现 `passPattern`：退出码 0 不算通过，既无 PASS 也无 FAIL 视为 FAIL；generic 覆盖只在 fuse 阶段生效，每次参数组合重新 fuse；超时会终止本地 SSH 会话并判 FAIL。
- `pwsh -File .\ise.ps1 report -Project <名称> (-RunId <id> | -Latest) [-Json]` 只读取已有 artifacts，不重新构建；`timing` 在有人实际阅读 timing.twr 之前只能是 `NOT_RUN`/`NEEDS_REVIEW`，不得据此声称时序通过。
- implement 是否应当被阻止**只以目标工程当前 `project.json` 的 `verification.expectImplementationBlocked` 为准**。该字段随工程进展变化（`finger_piano` 已由 `true` 改为 `false`），Agent **每次工作前必须重新读取该字段**，不得在本文件中依赖硬编码的「当前值」。verify 以此判定 EXPECTED BLOCK 是否 PASS，工具内不写工程名特例。
- `board-check` 目前只在缺少 `board.json` 时输出 `BOARD_CHECK: NOT_CONFIGURED`，存在时输出 `BOARD_CHECK: NOT_IMPLEMENTED`；不得猜测引脚，不得自动设置 `constraintsReviewed=true`。（烧录已实现，见 `program`；`board-check` 仍是占位入口。）
- 工具自测 `pwsh -NoProfile -File .\tools\test-tools.ps1` 覆盖失败路径（fuse 失败、超时、无 PASS 模式、failPattern、门禁两个方向、report 缺文件、旧工程兼容），使用隔离目录与模拟远端，不代表真实综合或真实仿真。

## 工具链冻结（Toolchain Freeze v1）

- **正式命令集合已冻结，不再增加烧录模式**：`doctor / new / check / build / fetch / sim / verify / report / probe / probe-diag / program / board-check`。`program` 只有 `-Mode Jtag`（易失）与 `-Mode Isf`（持久）两种，不得新增第三种。
- **Spartan-3AN 语义（真机验证过，不得改动）**：
  - `-Mode Jtag` = `assignFile` + **`program -p N -onlyFpga`** → VOLATILE，只配置 FPGA fabric，不写内部 ISF，**不加 `-v`**。
  - `-Mode Isf` = `assignFile` + **`program -p N -e -v`** → NON-VOLATILE，显式 erase → program → verify。
  - **禁止**把 `program -p N -v` 恢复为正式 ISF 重写流程。
- **ISF 失败根因的措辞已冻结**：只能写「旧 ISF 流程在重写非空 ISF 时没有显式执行擦除；加入 `-e` 后 iMPACT 明确完成 Erase → Program → Verify，原先稳定出现的 page 0 verify failure 消失，因此工程上将『缺少显式 erase』认定为根因」。**不得**写成「隐式 erase 没有擦净」（没有证据证明旧流程执行过 erase）。
- **下载线配置固定**：Digilent JTAG-HS2、`SN = 210241672559`、`TCK = 10000000 Hz`、`position = 1`；正式 `probe`/`program` 必须用显式 target，`-p auto` 只允许出现在 `probe-diag`。
- **hardware transaction 架构保留**：local static validation → 一次上传 → remote hardware transaction → 只读 preflight → 立即 program → fetch。两段之间不得插入 SSH 往返 / SFTP / 本地解析 / 数秒 sleep。Adept 冷启动 `DmgrOpenEx erc=3072` 已由事务内只读 preflight retry 吸收，**不需要继续研究 Session 0**。
- **本轮冻结期间禁止**：改 RTL 功能、改引脚、重写 ISF、调 Windows USB 电源策略、再做 Session 0 A/B、再做几十次 probe 统计、GUI 自动化、新增 programmer backend。
- **冻结命令集之外的辅助脚本（存在，但不是 `ise.ps1` 命令）**：`tools/make-gui-project.ps1` 在 VM 上生成一份**只给人看的** ISE Project Navigator 工程（`...\<工程>\gui-project\<工程>.xise`，含 src/constraints/sim，默认写成 GBK 供 ISE 编辑器正确显示中文）；`tools/convert-encoding.ps1` 做 UTF-8 ↔ GBK 转换。相关 helper 在 `tools/ise-gui-project.ps1`（被 `ise-tools.ps1` dot-source，仅供上述脚本与自测使用）。
  **编码规则**：仓库永远是 UTF-8；只允许把 VM 上的 GUI 副本转成 GBK。在 GUI 里改过的文件搬回仓库前必须先 `convert-encoding.ps1` 转回 UTF-8。重新生成会用仓库覆盖副本（先删旧 `.xise` 再建）。

## JTAG 探测与烧录

- `probe` 只读：按配置的显式序列号打开下载线、识别 JTAG 链、读 IDCODE 并与 project.json 的器件核对。失败时按分层状态报告（见下），**不得修改 VM 配置或自动 attach USB**，也不得伪造 PASS，更不得把 Adept 层失败说成「下载线对虚拟机不可见」。
- `program` 是硬件写操作，**默认只预览**（PREVIEW ONLY：打印 cable/chain/device/position/bitstream/mode 后结束，不生成写脚本、不执行 program）。必须由用户明确要求并带 `-ConfirmHardwareWrite` 才真正写入。
- 两种模式含义不同、不得混用：`-Mode Jtag` = 通过 JTAG 配置 FPGA 本体（VOLATILE），`program -p N -onlyFpga`；`-Mode Isf` = 编程 Spartan-3AN 内部 ISF（NON-VOLATILE，上电自动配置），**`program -p N -e -v`**。Isf 执行前必须提示 `M[2:0] = 011` 与 `VCCAUX = 3.3 V`。
- **ISF 的擦除阶段是硬门禁**：不带 `-e` 的 `program -v` 实测会打印 `Programming completed successfully` 却随后 `Verify failed on page 0`（写入自称成功、内容错误）。因此 `-Mode Isf` 必须用 `-e`，且必须在转录中看到 `Erasing device...` 与 `Erasure completed successfully.`（且无 erase 失败行）之后，才允许采信 `Programming Flash...`/`Programming completed successfully`/`Verification completed successfully`。擦除一旦启动即视为已动 Flash → **绝不自动重试写入**。
- **实测结论（ISE 14.7 + XC3S50AN）**：同一个 `assignFile` + `program` 因 `-onlyFpga` 而含义不同——不加它是写**内部 ISF**（转录出现 `SPI access core`、`Programming Flash`、sector/page），加它是**只配置 FPGA 本体**（`Programming device` → `Completed downloading bit file to device`，无任何 SPI/Flash 行）。因此：Jtag 模式必须带 `-onlyFpga` 且**不加 `-v`**（FPGA 回读校验需要 BitGen `-m` 的 `.msk`，否则报 `ERROR:Bitstream:2 ... design.msk does not exist`）；Isf 模式用 **`-e -v`** 作为显式擦除 + in-step 校验。`assignFileToAttachedFlash`/`-spi` 属于**外挂** PROM 的 indirect SPI 流程，对内部 ISF 会报 `No attached device found at position '1'`，不得使用。
- **已撤回的历史结论（不得再作为依据）**：「Spartan-3AN 没有易失 SRAM 配置路径」（被 `-onlyFpga` 推翻）、「`-onlyFpga` 需要 `.msk` 所以不是易失配置」（只有 `-onlyFpga + -v` 才需要 `.msk`）、「`assignFileToAttachedFlash` 用于内部 ISF」（被 `No attached device found` 推翻）、「`program -v` 足以可靠重写 ISF」（被 page 0 verify failure 推翻）、「下载线对虚拟机不可见 / `CABLE_NOT_FOUND`」（被 PnP 实测推翻）、「Session 0 是主因」（被会话 A/B 推翻）。
- **结果状态模型固定为六个字段**：`cableDetected` / `jtagChainDetected` / `deviceMatched` / `programmingCompleted` / `programmingVerified` / `userDesignFunctional`。`programmingVerified = VERIFIED` **不等于** `userDesignFunctional = PASS`；后者需要板卡功能测量，工具固定输出 `NOT_TESTED`，永不打印 `BOARD PASS`。
- **不跑独立 `verify`**：实测 `verify -p N` 与 `verify -p N -sram` 均回 `Verify failed on page 0`（即使紧接在一次 iMPACT 已自行 `Verification completed successfully` 的写入之后），其结论不可信。校验结论一律取自 program 转录：`Verification completed successfully` → `VERIFIED`；出现 `Verify failed` → `FAIL`；FPGA 配置且 `DONEIN=1`/`CRC error=0` → `CONFIG_STATUS_OK`。转录里的器件状态寄存器（`M[2:0]`、`DONEIN`、`CRC error`、`VSEL`）必须解析并在摘要中显示。
- Jtag 模式的转录里若出现任何内部 Flash 编程迹象，判 FAIL 并标注 `MODE VIOLATION`（易失语义被破坏、非易失 Flash 已被改动）。
- **正式 probe / program 必须固定下载线**：`programming.cableType/cableSerial/cableFrequencyHz` → `setCable -target "digilent_plugin DEVICE=SN:<sn> FREQUENCY=<measured>"`。`cableFrequencyHz` 只能来自真实转录，缺失就报错停止，**永不默认 10000000**。`-p auto` 只允许出现在 `probe-diag`。摘要必须打印 cable provider/serial/target/frequency 与转录中实际出现的序列号，不符即 `CABLE MISMATCH` 判 FAIL。
- **一次硬件事务**：本机只做静态检查（工程配置、bit 头、SHA-256、期望器件、已确认序列号、`-ConfirmHardwareWrite`），一次性上传脚本与 bitstream，然后由远端**一个** `hardware_transaction.cmd` 完成「只读 preflight → 立即写入」。两个 iMPACT 调用之间**不得有 sleep / SSH / SFTP / 本地解析**；preflight 不通过时 `program.cmd` 绝不执行。实测动机：下载线刚打开过时可稳定重开，静置数秒后易出现 `failed to open device (DmgrOpenEx, erc = 3072)`（`ercConnectionFailed`）。
- 重试只允许发生在「转录里完全没有写入迹象」时（`programming.cableRetryAttempts`），退避 **150 ms 而非数秒**；出现 `Programming device`/`Programming Flash`/`Completed downloading`/`Programmed successfully`/`Verifying`/`TIMEOUT`/SSH 中断后**绝不重试**。事务用 `exit /b 2`（preflight 失败）与 `exit /b 3`（环境失败）表达预期结果，按 `run.status` 判定，不得误报 `PROGRAM_STATE_UNKNOWN`。
- 下载线失败必须分层：`DIGILENT_ENUM_FAILED`（`no JTAG device was found`）/ `DIGILENT_OPEN_FAILED`（`failed to open device (DmgrOpenEx, erc = 3072)`）/ `CABLE_UNAVAILABLE`。**Windows PnP 里设备存在不等于 Adept 能打开**，不得声称「下载线对虚拟机不可见」。
- JTAG/ISF 编程用的是下载线的 TCK，与用户时钟无关；**烧录成功不等于设计工作正常**，`userDesignFunctional` 永远输出 `NOT_TESTED`，禁止打印 `BOARD PASS`。
- 每次 program 前必须自动 preflight（等价 probe + bit 文件存在且非空 + 器件匹配）；不假定 position=1，多器件未指定 `-Position` 时报 `ERROR: Multiple JTAG devices detected; specify -Position.`。
- 不运行独立的 `verify` 步骤（其结论不可信，见上）；`programmingVerified` 只能取自 program 转录的证据：有校验结论就如实报 `VERIFIED`/`FAIL`，只有 FPGA 配置状态可依据时报 `CONFIG_STATUS_OK`，PASS 但无任何校验证据时报 `NOT_APPLICABLE`，不得伪造 verify 通过。
- Jtag/Isf 使用不同超时；超时标 `TIMEOUT`、保留日志、非零退出且**不自动重烧**。SSH 在写入中断开 → `PROGRAM_STATE_UNKNOWN`，不得自动重试，先重新 `probe`、查远端 `run.status`、取回原日志再决定。
- iMPACT 退出码不可靠（同一次失败可能返回 0），判定一律解析转录日志；`setMode` 必须优先，`blankCheck` 等不得乱序调用。iMPACT **不会**把「打不开下载线」写成 `ERROR:`（只打印 `no JTAG device was found` / `Cable autodetection failed`，而状态文件仍为 `COMPLETE`），必须显式识别，否则会误报成「未确认的成功」。
- 工具只写远端受管目录，不改 ISE 安装；`constraintsReviewed` 始终保持人工确认，不得为了让工具产生 bitstream 而自动置 true。

## 凭据与操作范围

- 复用 `ssh fpga-vm` 的本机密钥配置。不要要求用户重复提供密码，不向工程或日志写入密码、私钥内容。
- 常规源码修改和构建按用户任务授权执行；JTAG 写入必须由用户明确要求并带 `-ConfirmHardwareWrite`，工具自身不做隐式烧录。
- **每个阶段完成后自行提交并推送**：一份计划的一小步做完、判定通过（单测出现 `PASS`，或完整 `verify` 全绿）后，Agent 直接 `git commit` + `git push origin main`，**不需要逐次征询**；一个阶段一个 commit，**不得把失败的测试或未验证的状态推上去**。本条只覆盖源码、测试与文档；**硬件写入仍必须由用户明确要求**并带 `-ConfirmHardwareWrite`。（项目侧细则见 `projects/finger_piano/AGENTS.md` 的「每完成一个阶段：自行提交并推送」。）
- 构建仅写入远端 `C:\Users\PanGucheng\ise-builds` 下的受管目录，不改系统环境变量或现有 ISE 安装。
- 不自动删除构建目录；如用户要求清理，先解析并确认绝对路径在受管根目录内，禁止删除整个用户目录或越界路径。
- 工具和目录约定改变时同步更新 README.md、AGENTS.md。不要把密钥复制进版本库；忽略 artifacts 与 tools/.work。
