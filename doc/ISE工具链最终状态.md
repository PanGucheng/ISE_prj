# ISE 工具链最终状态（Toolchain Freeze v1）

本文件是工程维护视角的冻结说明：**当前支持什么、怎么用、边界在哪、板卡上还没验证什么**。
不记录实验过程；实验历史见 `README.md` 与 `projects/finger_piano/README.md`。

冻结日期：2026-09-15。冻结时 `tools/test-tools.ps1` 全绿。

---

## 1. Supported commands（已冻结，不再新增烧录模式）

| 命令 | 类型 | 作用 |
|---|---|---|
| `doctor` | 环境 | 本机/远端环境与传输自检（`-TransferTest` 校验 SHA-256） |
| `new` | 工程 | 新建工程骨架（`device`/`sources` 等需自行填写） |
| `check` | 静态 | 只做配置与门禁检查，不构建 |
| `build` | 构建 | 从新目录构建到 `synth` / `implement` / `bitstream` |
| `fetch` | 构建 | 按构建编号补取远端结果 |
| `sim` | 仿真 | 运行 `project.json` 的 `simulations` 用例（可 `-Test <名称>`） |
| `verify` | 验收 | **主入口**：配置 + 静态检查 + 综合 + 全部仿真 + implement 门禁 |
| `report` | 报告 | 只读汇总已有 artifacts；时序永不自动 PASS |
| `probe` | 硬件（只读） | 打开下载线、识别 JTAG 链、读 IDCODE 并与工程器件核对 |
| `probe-diag` | 硬件（只读） | 下载线 / Adept 层分层诊断实验工具 |
| `program -Mode Jtag` | 硬件（写） | 易失 FPGA 配置 |
| `program -Mode Isf` | 硬件（写） | Spartan-3AN 内部 ISF 持久化写入 |
| `board-check` | 板卡 | 缺少 `board.json` 时 `NOT_CONFIGURED`，存在时 `NOT_IMPLEMENTED`（占位入口） |

`program` **只有** `-Mode Jtag` 与 `-Mode Isf` 两种，不得新增第三种烧录模式。

## 2. Environment

- 本机：`D:\ISE_prj`，PowerShell 7（入口 `#Requires -Version 7.0`），通过 `ssh fpga-vm` / `sftp` 操作远端。
- 远端：Win7 32 位，ISE 14.7，入口 `C:\Xilinx\14.7\ISE_DS\settings32.bat`，iMPACT `Release 14.7 - iMPACT P.20131013 (nt)`。
- 远端受管根：`C:\Users\PanGucheng\ise-builds`（工具只写这里，不改 ISE 安装、不改系统环境变量）。
- 本机产物根：`projects/<工程>/artifacts/`（`artifacts/` 与 `tools/.work/` 已被 `.gitignore` 排除）。
- `doctor` 是环境变化时的第一入口；连接失败先跑它。

## 3. Build workflow

```
check -Project <名> -Stage synth|implement|bitstream     # 先看门禁
build -Project <名> -Stage synth|implement|bitstream     # 每次从新目录完整执行
report -Project <名> -Latest                             # 只读汇总
```

- `implement` 需要 UCF 且 `constraintsReviewed=true`（人工确认字段，工具**不会**自动置 true）。
- 每次构建保留 `run.json`（配置快照 + 输入 SHA-256）、`inputs/`、`results/`、`summary.txt`。
- `summary.txt` 的 `Timing` 默认 `NEEDS_REVIEW`：**必须人工阅读 `timing.twr`** 才能给出时序结论。

## 4. Simulation workflow

```
sim    -Project <名> [-Test <用例名>]     # 单个或全部 enabled 用例
verify -Project <名>                      # 综合 + 静态 + 全部仿真 + implement 门禁
```

- 用例定义在 `project.json` 的 `simulations`（`name/top/sources/generics/timeoutSeconds/passPattern/failPattern`，可加 `enabled`）。
- 判据是日志出现 `passPattern`：**退出码 0 不算通过**；既无 PASS 也无 FAIL 视为 FAIL。
- generic 覆盖只在 `fuse` 阶段生效（每次参数组合重新 fuse）；testbench 绝不加入综合 `sources`。

## 5. JTAG workflow（易失）

```
probe   -Project <名>                     # 只读：下载线 + 链 + IDCODE 核对
program -Project <名> -Mode Jtag -BitFile <design.bit> -ConfirmHardwareWrite
```

生成的 iMPACT 脚本：

```
setMode -bs
setCable -target "digilent_plugin DEVICE=SN:210241672559 FREQUENCY=10000000"
identify
assignFile -p N -file <design.bit>
program -p N -onlyFpga
closeCable
quit
```

- 语义：**VOLATILE**，只配置 FPGA fabric，**不写内部 ISF**。
- 不加 `-v`：FPGA 回读校验需要 BitGen `-m` 的 `.msk`，否则报 `ERROR:Bitstream:2 ... design.msk does not exist`。
- 校验结论取自转录状态寄存器：`DONEIN=1` 且 `CRC error=0` → `CONFIG_STATUS_OK`。

## 6. ISF workflow（持久）

```
program -Project <名> -Mode Isf -BitFile <design.bit> -ConfirmHardwareWrite
```

生成的 iMPACT 脚本：

```
setMode -bs
setCable -target "digilent_plugin DEVICE=SN:210241672559 FREQUENCY=10000000"
identify
assignFile -p N -file <design.bit>
program -p N -e -v
closeCable
quit
```

- 语义：**NON-VOLATILE**，显式 `erase → program → verify`，上电自动配置。
- **擦除门禁**：转录必须先出现 `Erasing device...` 与 `Erasure completed successfully.`（且无 erase 失败行），之后才允许采信 `Programming Flash...` / `Programming completed successfully` / `Verification completed successfully`。
- **禁止**把 `program -p N -v` 恢复为正式 ISF 重写流程。
- 根因措辞（已冻结）：旧 ISF 流程在**重写非空 ISF 时没有显式执行擦除**；加入 `-e` 后 iMPACT 明确完成 `Erase → Program → Verify`，原先稳定出现的 page 0 verify failure 消失。**不得**写成「隐式 erase 没有擦净」。
- ISF 启动前置条件：`M[2:0] = 011`、`VCCAUX = 3.3 V`（JTAG 无法证明板上跳线）。

## 7. Programmer safety model

**本机静态检查（都在硬件事务之前）**

- `-ConfirmHardwareWrite`：**没有它就不写**（只打印 PREVIEW，且不生成/不执行写脚本）。
- bitstream header 与工程器件匹配、bitstream 非空、SHA-256 记录。
- 期望器件、期望 IDCODE（来自安装自带 BSDL）、JTAG position（配置或显式 `-Position`）。
- 下载线序列号固定并记录摘要。

**远端一次硬件事务（`hardware_transaction.cmd`）**

```
local static validation → 一次上传 → remote hardware transaction
    → 只读 preflight（打开下载线 + Added Device <part> + IDCODE）
    → 立即 program（两者之间无 SSH 往返 / 无 SFTP / 无本地解析 / 无数秒 sleep）
    → fetch result
```

- preflight 不通过 → `program.cmd` **绝不执行**。
- 事务用 `exit /b 2`（preflight 失败）/ `exit /b 3`（环境失败）表达**预期结果**，按 `run.status` 判定。

**判定与重试**

- `MODE VIOLATION`：Jtag 模式转录出现内部 Flash 编程迹象 → FAIL。
- `CABLE MISMATCH`：转录里的序列号与配置不符 → FAIL。
- `TIMEOUT` / `PROGRAM_STATE_UNKNOWN`：保留日志、非零退出、**不自动重烧**。
- 重试规则：**只有「完全没有 erase/program evidence 的 cable-open failure」才允许安全重试**（退避 150 ms，不是数秒）；`Erasing device` 一旦出现，此后无论成功失败都**禁止自动重写**。

**状态模型（六字段，固定）**

```
cableDetected / jtagChainDetected / deviceMatched / programmingCompleted / programmingVerified / userDesignFunctional
```

`programmingVerified = VERIFIED` **不等于** `userDesignFunctional = PASS`；工具永不打印 `BOARD PASS`。

## 8. Known cable behaviour

- 下载线：**Digilent JTAG-HS2**，`SN = 210241672559`，TCK 实测 **10000000 Hz**，`position = 1`。
- 正式 `probe`/`program` 一律使用显式 target；**`-p auto` 只允许出现在 `probe-diag`**，不得回到正式路径。
- 失败分层：`DIGILENT_ENUM_FAILED`（`no JTAG device was found`）/ `DIGILENT_OPEN_FAILED`（`failed to open device (DmgrOpenEx, erc = 3072)` = `ercConnectionFailed`）/ `CABLE_UNAVAILABLE`。
- **Windows PnP 里设备存在不等于 Adept 能打开**：不要再声称「下载线对虚拟机不可见」。
- 冷启动（静置后首次打开）可能失败，已由**事务内只读 preflight retry** 吸收；不需要继续研究 Session 0。

## 9. Proven hardware results

| 项 | 结果 | 证据 |
|---|---|---|
| 下载线识别 | PASS | `probe-20260915-002918-0200e4c2`：`xc3s50an` / `IDCODE 0x02610093` / `Match YES` |
| 易失 JTAG 配置 | PASS ×2 | `program-20260915-003257-7ef9c0de`、`program-20260915-003321-faf98f9b`：`Programming device`、`Completed downloading bit file to device`、`DONEIN=1`、`CRC error=0`、无 `Programming Flash` |
| ISF erase/program/verify | PASS | `program-20260915-083244-bf54acda`：`Erasing device...` → `Erasure completed successfully.` → `Programming Flash...done.` → `Programming completed successfully.` → `Verifying device...done.` → `Verification completed successfully.` → `Checking done pin....done.`（7 s） |
| ISF 器件类型 | X-FAB，1 Mbit | `readStatusRegister -p 1 -flash`：`Device Density Bits = 0011` |
| ISF 写保护 | 无 | `Sector Protection enabled = 0`，全部 sector `NOT SECURED` / `NOT LOCKED DOWN` |
| XCN14003 / AR59572 补丁 | 未安装，本例不需要 | `MYXILINX` / `ISE_XCN14003_patch` 均未设置，安装内无 `*patch*` 文件；器件为 X-FAB |

## 10. Remaining board-validation tasks

```
[x] RTL / synth / simulation / implementation / timing / bitstream
[x] JTAG volatile configuration
[x] ISF erase/program/verify
[ ] power-cycle persistent boot   = NOT_TESTED   # 成功写入后尚未断电验证
[ ] board functional test         = NOT_TESTED
[ ] sensor input test             = NOT_TESTED   # 压力传感器调理电路未搭建
[ ] audio output measurement      = NOT_TESTED   # 示波器/频率计测 P12
[ ] LM386 test                    = NOT_TESTED
[ ] speaker test                  = NOT_TESTED
[ ] complete finger-piano acceptance = NOT_TESTED
```

外围硬件尚未搭建，因此以上一律记录为 `NOT_TESTED`，**不得写成 FAIL**；也不得从烧录成功推导板卡功能正常。
`userDesignFunctional` 在工具输出中是固定值 `NOT_TESTED`。

## 11. 日常只需五条命令

```powershell
.\ise.ps1 verify -Project finger_piano
.\ise.ps1 build  -Project finger_piano -Stage bitstream
.\ise.ps1 probe  -Project finger_piano
.\ise.ps1 program -Project finger_piano -Mode Jtag -BitFile <design.bit> -ConfirmHardwareWrite
.\ise.ps1 program -Project finger_piano -Mode Isf  -BitFile <design.bit> -ConfirmHardwareWrite
```

使用课程设计时不需要理解：iMPACT 批处理脚本、`fuse`、SSH staging 目录、Digilent target 语法、ISF 擦除细节。

## 12. 可选的 GUI 工程副本（**不属于冻结命令集**）

冻结的 `ise.ps1` 命令集合保持十二个不变。如果需要在 **ISE 14.7 图形界面**里打开工程自己看/调试，用下面两个**独立辅助脚本**（它们只读仓库，只写 VM 上的一份「给人看的副本」）：

```powershell
# 生成可直接用 ISE 打开的人看副本（默认写成 GBK，供 ISE 编辑器正确显示中文）
pwsh -File .\tools\make-gui-project.ps1 -Project finger_piano
pwsh -File .\tools\make-gui-project.ps1 -Project finger_piano -Encoding Utf8   # 想保留 UTF-8 时

# 把 ISE 编辑器里改过的文件在编码之间转换（仓库 = UTF-8，GUI 副本 = GBK）
pwsh -File .\tools\convert-encoding.ps1 -Path <文件或目录> -From Gbk -To Utf8
pwsh -File .\tools\convert-encoding.ps1 -Path src -From Utf8 -To Gbk -DryRun
```

- 产物位置：`C:\Users\PanGucheng\ise-builds\<工程>\gui-project\<工程>.xise`（可用 `-RemotePath` 改）。工程里已含 `src/`、`constraints/`、`sim/`，器件/封装/速度、Verilog 包含目录与顶层模块都会设好；脚本生成后会回读 `.xise` 并打印这些属性。
- **编码规则（重要）**：仓库永远是 **UTF-8**；VM 副本是 **ANSI/GBK(936)**，因为 ISE 14.7 的 HDL 编辑器在中文 Windows 上按 ANSI 读文件，UTF-8 中文注释会显示成乱码（XST 综合不受影响）。**只在副本上转换，绝不改仓库。**
- **在 GUI 里改过的代码要搬回仓库时必须先转换编码**（`convert-encoding.ps1`），否则会造成新的乱码/编码污染。
- 重新生成会**用仓库内容覆盖这份副本**（含删除旧 `.xise` 后重建），所以 GUI 里的改动会丢——先转换、搬回去，再重新生成。
- 这份副本**不参与**工具链：构建、仿真、烧录仍以 `ise.ps1` 与仓库为准，GUI 里编译产生的中间文件只落在 `gui-project\` 内。
- 已知实现细节：ISE 只接受 `tqg144`（`tq144` 会被拒绝，脚本自动回退）；`project new` 不会覆盖已存在的工程文件，脚本会先删除再建。
