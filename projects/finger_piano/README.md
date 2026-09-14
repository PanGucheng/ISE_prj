# 手指钢琴（Finger Piano）——Spartan-3AN XC3S50AN 课设工程

7 路数字输入的单音电子琴：`key_in[6:0]` 分别对应唱名 1~7（第四八度 C4~B4），FPGA 输出 50% 占空比方波 `audio_out` 驱动 LM386 功放。无按键时输出恒 0。

- 器件：`xc3s50an-4-tqg144`（**TODO：速度等级 `-4` 为暂定占位，必须以芯片丝印为准核对后修改 `project.json` 与本节**）
- 工具：Xilinx ISE 14.7（远端 Win7 `fpga-vm`），Verilog-2001，XST 综合
- 顶层：`finger_piano_top`
- 时钟：外部有源晶振作为**唯一**系统时钟；全工程只有一个时钟域 `clk`，无门控时钟、无逻辑产生的第二时钟

## 1. 顶层端口

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk` | in | 1 | 外部有源晶振，唯一系统时钟 |
| `rst_n` | in | 1 | 低有效复位；内部经 `reset_sync` 异步拉低、同步释放为 `rst_n_sync` |
| `key_in[6:0]` | in | 7 | 压力传感器调理+电平判决后的 0/1 数字输入，`key_in[0]`=唱名 1 … `key_in[6]`=唱名 7 |
| `audio_out` | out | 1 | 矩形波音频输出，接 LM386 |
| `key_debug[6:0]` | out | 7 | 调试：极性归一化+同步+滤波**之后**的按键状态 |
| `note_debug[2:0]` | out | 3 | 调试：当前音符编码，0=无音符，1~7=C4~B4 |

按键极性由 `` `KEY_ACTIVE_HIGH `` 选择（默认 1=按下为高），归一化只在顶层做一次（`key_normalized`），后续链路统一使用归一化后的信号。

## 2. 目录结构

```
projects/finger_piano/
  project.json                     ISE 工具链配置（sources / includeDirs / includeFiles / ucf）
  src/
    finger_piano_cfg.vh            ★ 配置真值源：SYS_CLK_HZ 等 6 个宏，全工程唯一
    reset_sync.v                   异步拉低、同步释放的复位同步器
    key_sync.v                     7 路输入两级触发器同步
    key_filter.v                   参数化数字稳定滤波（默认 10 ms，可关闭）
    note_encoder.v                 7 路→note_code[2:0]，固定优先级 1>2>…>7
    tone_generator.v               同步计数器 + terminal count 生成方波
    finger_piano_top.v             顶层：极性归一化与模块互联
  constraints/
    finger_piano.ucf               模板（只有注释与 TODO，无任何 LOC/IOSTANDARD/TIMESPEC）
  sim/
    tb_note_encoder.v              编码器优先级测试
    tb_tone_generator.v            七音频率/静音/相位重启测试
    tb_finger_piano_top.v          顶层：同步+滤波窗口判据、小星星序列、极性
  README.md
  frequency_table.md               半周期计数值与理论频率误差
```

`sim/` 下的 testbench **不在** `project.json` 的 `sources` 里，因此永远不会进入 XST 综合；`src/finger_piano_cfg.vh` 通过 `includeFiles` 同步、通过 `includeDirs: ["src"]`（XST `-vlgincdir`）被 `` `include `` 找到。

## 3. 模块关系

```
                 +-------------+
   rst_n ------> | reset_sync  | --> rst_n_sync ------+---------------------+
                 +-------------+                      |                     |
                                                      v                     v
 key_in[6:0] --> [极性归一化] --> key_sync --> key_filter --> note_encoder --> tone_generator --> audio_out
                 key_normalized   (2 级 FF)   (10ms 稳定)    (优先级编码)     (同步计数/TC)
                                        |                        |
                                        +--> key_debug[6:0]      +--> note_debug[2:0]
```

1. **极性归一化**：`assign key_normalized = KEY_ACTIVE_HIGH ? key_in : ~key_in;`（全工程唯一反相处）。
2. **`key_sync`**：两级触发器，消除外部输入相对 `clk` 的亚稳态。
3. **`key_filter`**：对每路按键独立计数，输入电平持续偏离当前稳定值达到 `STABLE_CYCLES` 才更新输出；短毛刺被完全拒绝。`KEY_FILTER_ENABLE=0` 时综合为纯直通（`assign`），不产生任何计数器。
4. **`note_encoder`**：纯组合优先级编码，`key_stable[0]` 最高优先（1 > 2 > 3 > 4 > 5 > 6 > 7），无按键输出 0。
5. **`tone_generator`**：对 `SYS_CLK_HZ` 做同步计数，半周期到达 terminal count 时翻转 `audio_out`；`note_code==0` 时输出 0 并清零计数；音符变化时相位重启（计数清零、输出清零），使演奏与仿真行为可预测。全程只有 `posedge clk`，没有用任何分频器输出当时钟。

## 4. 配置方法

**所有全局配置只改一个文件**：`src/finger_piano_cfg.vh`。

| 宏 | 默认 | 含义 |
|---|---|---|
| `` `SYS_CLK_HZ `` | `50000000` | **板上实际有源晶振频率，必须核对后修改**；所有时序常量都由它推导 |
| `` `KEY_STABLE_MS `` | `10` | 按键数字稳定滤波时间（ms），默认 10 ms |
| `` `KEY_FILTER_ENABLE `` | `1` | `1` 开启滤波；`0` 关闭（纯直通，零资源） |
| `` `KEY_ACTIVE_HIGH `` | `1` | `1`=按下为高；`0`=按下为低（外部比较器输出极性） |
| `` `FP_FILTER_CNT_WIDTH `` | `24` | 滤波计数器位宽 |
| `` `FP_TONE_CNT_WIDTH `` | `24` | 音频半周期计数器位宽 |

- **禁止**把具体频率写进其它模块：其他 RTL 只通过 `parameter SYS_CLK_HZ = `SYS_CLK_HZ` 取默认值，并由顶层参数向下覆盖。改频后 `frequency_table.md` 的表格需按同公式重算（见该文件）。
- UCF 中 `TIMESPEC PERIOD` 的 ns 值必须与 `` `SYS_CLK_HZ `` 一致：`PERIOD_ns = 1000 / SYS_CLK_MHz`。
- 仿真时不需要改动本文件：testbench 用参数覆盖（`#(.SYS_CLK_HZ(...))`）把系统时钟降到 1 MHz 以缩短仿真时间。

## 5. 与课程资料“2 MHz 分频”的对应关系

> 课程资料使用 2 MHz 时基分频作为基础实现提示。本工程为避免由普通逻辑产生新的内部时钟域，统一采用外部有源晶振作为唯一系统时钟，并通过同步计数器或 clock-enable 实现等效分频。若实际系统晶振可整数分频得到 2 MHz，可产生 `ce_2m` 单周期时钟使能，但不将其作为独立时钟驱动时序逻辑。

即：**不允许**出现 `always @(posedge clk_2m)` 这类第二时钟域，也不允许把 `audio_out` 当时钟。本阶段没有实现 `ce_2m`（`tone_generator` 直接从 `SYS_CLK_HZ` 计数，功能等价且不需要中间时基）；阶段二若需要 2 MHz 时基，只允许以单周期使能 `ce_2m` 的形式接入。

## 6. 频率精度

七个音符的半周期计数值、理论输出频率和误差见 `frequency_table.md`。在默认占位的 50 MHz 下，全部音符误差绝对值 ≤ 0.011%，远优于 1% 的课程要求；误差来源是半周期计数的整数取整，与晶振自身精度无关（晶振误差另计）。

## 7. UCF 填写指南（`constraints/finger_piano.ucf`）

模板文件目前**全部是注释**：没有 `LOC`、没有 `IOSTANDARD`、没有 `TIMESPEC`，因为实际 TQ144 最小系统板原理图尚未提供。**不得凭空填引脚。** 需要填写的条目：

| 待填 | UCF 对象名 | 备注 |
|---|---|---|
| 系统时钟 | `NET "clk"` | LOC + IOSTANDARD；必须是全局时钟引脚（`GCLK`） |
| 复位 | `NET "rst_n"` | LOC + IOSTANDARD；确认低有效、外部有上拉/RC |
| 7 路按键 | `NET "key_in<0>"` … `NET "key_in<6>"` | 逐位 LOC；注意总线位序与传感器通道的对应 |
| 音频输出 | `NET "audio_out"` | LOC；接 LM386 输入 |
| 调试输出 | `NET "key_debug<0..6>"`、`NET "note_debug<0..2>"` | 未使用的必须删除端口，否则必须在最终 bitstream 前补 LOC |
| 时钟周期 | `TIMESPEC "TS_clk" = PERIOD "clk_group" X ns HIGH 50%` | `X = 1000 / SYS_CLK_HZ(MHz)`，与实际晶振一致；配合 `NET "clk" TNM_NET = "clk_group";` |

命名规则：Verilog 向量端口在 UCF 中写成 `名字<下标>`，例如 `key_in<0>`。

## 8. 允许把 `constraintsReviewed` 改为 `true` 的前置条件

`constraintsReviewed=true` 是人工确认，不是工具时序结论。**只有同时满足以下全部条件**才允许修改 `project.json`：

```
[ ] clk LOC 已按原理图核对
[ ] clk IOSTANDARD 已核对（并与所在 I/O Bank 电压一致）
[ ] rst_n LOC 与电气条件（上拉/RC/极性）已核对
[ ] key_in[0..6] LOC 全部核对，位序与传感器通道一致
[ ] audio_out LOC 已核对
[ ] 所有保留的 debug 顶层端口（key_debug[6:0]、note_debug[2:0]）LOC 已核对，
    或已从最终上板顶层中删除
[ ] I/O Bank 电压与全部 IOSTANDARD 匹配
[ ] UCF 中 PERIOD 与实际有源晶振频率一致，且与 src/finger_piano_cfg.vh 相同
```

在此之前 `pwsh -File .\ise.ps1 check -Project finger_piano -Stage implement` **按设计失败**，这是预期行为，不是缺陷。debug 端口共 10 根，绝不允许在最终 bitstream 中处于“未约束、由工具自动分配”的状态。

## 9. 仿真步骤

`sim/` 下三个 testbench 都可独立运行，判据是最后打印的 `PASS` 行。

### 9.1 ISE 内置 ISim（图形界面）

1. 在 ISE Project Navigator 新建工程，器件选 `xc3s50an-4-tqg144`；
2. 加入 `src/` 下 6 个 `.v`（`.vh` 加到 include 路径：`Project → Properties → Verilog Include Directories` 填 `src`）；
3. 加入 `sim/` 下要跑的 testbench，顶层设为该 testbench，综合工具选 `ISim`；
4. 设置仿真参数（如需要）：`tb_finger_piano_top` 的 `TB_SYS_CLK_HZ`/`TB_STABLE_MS`/`TB_KEY_ACTIVE_HIGH`；
5. Run Behavioral Simulation，在 Tcl Console 查看 `PASS/FAIL` 行。

### 9.2 ISim 命令行（本工程实际验证使用的方式）

远端 `fpga-vm` 的 ISE 14.7 安装**没有** `isim.exe`，但有命令行编译器 `fuse.exe`（`ISE_DS\ISE\bin\nt\fuse.exe`），用它可以无 GUI 编译出仿真可执行文件：

```cmd
call C:\Xilinx\14.7\ISE_DS\settings32.bat
cd /d <工作目录>
fuse -prj sim_tone_generator.prj -top tb_tone_generator -i src -o tb_tone_generator.exe
tb_tone_generator.exe -tclbatch run_all.tcl -log ..\out\sim_tone_generator.isim.log
```

其中 `run_all.tcl` 只有两行：

```tcl
run all
exit
```

**三个已验证的关键点（本次实测踩过的坑，务必照做）：**

1. **必须在 `call settings32.bat` 之后运行 exe。** 该安装的仿真可执行文件依赖 ISE 的环境变量与 DLL 搜索路径；在干净 shell 里直接运行会**静默退出**——不打印任何内容，也不生成 `isim.log`，看起来像“什么都没发生”。
2. **必须用 `-tclbatch`。** 生成的 exe 是交互式 Tcl 驱动的仿真器：不加 `-tclbatch` 时它加载完设计就等命令，stdin 一结束便以 `# exit 0` 退出，**testbench 的 `initial` 块根本不会执行**（日志里只有启动横幅）。
3. **`--generic_top` 属于 `fuse`，不属于运行期的 exe。** Verilog 参数在编译（elaboration）阶段定值，所以低有效极性用例必须重新 `fuse` 一次，不能只在运行时加参数。

其中 prj 文件每行一个源文件，例如：

```
verilog work "src/reset_sync.v"
verilog work "src/key_sync.v"
verilog work "src/key_filter.v"
verilog work "src/note_encoder.v"
verilog work "src/tone_generator.v"
verilog work "src/finger_piano_top.v"
verilog work "sim/tb_tone_generator.v"
```

`-i src` 让 `` `include "finger_piano_cfg.vh" `` 能被找到。极性用例（低有效输入）用 `fuse` 的顶层参数覆盖重新编译一次，再以同样方式运行：

```cmd
fuse -prj sim_finger_piano_top.prj -top tb_finger_piano_top -i src -o tb_top_al.exe --generic_top "TB_KEY_ACTIVE_HIGH=0"
tb_top_al.exe -tclbatch run_all.tcl -log ..\out\sim_top_al.isim.log
```

另外两个注意点：

- Windows CMD 下把退出码紧贴重定向符会引发解析问题（`echo %RC%>f.txt` 里的数字会被当成文件描述符），记录退出码时数字与 `>` 之间要留空格。
- 该 Win7 主机的 ISim 运行在 ANSI(GBK) 代码页下，**经过 task 参数传递的非 ASCII 文本会在日志里变成乱码**（`$display` 里的中文字面量反而正常）。因此三个 testbench 的**诊断文本一律使用 ASCII**，以保证运行日志可直接阅读与检索；中文说明保留在本文档与源码注释中。相应地，testbench 不使用中文 task 标签。

## 10. ISE 综合与实现（本工具流程）

在仓库根目录执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 check  -Project finger_piano -Stage synth
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 build  -Project finger_piano -Stage synth
```

实现与 bitstream 需要先完成第 8 节的前置清单：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 check  -Project finger_piano -Stage implement
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 build  -Project finger_piano -Stage bitstream
```

本机结果在 `projects/finger_piano/artifacts/<构建编号>/`：`run.json`（配置快照+输入 SHA-256）、`inputs/`（上传的源码与生成的 XST/CMD 脚本）、`results/`（远端日志、`synthesis.srp`、网表）、`summary.txt`。`summary.txt` 的时序结论默认是 `NEEDS_REVIEW`，必须实际阅读 `timing.twr` 才能给出时序判断；生成 bit 不等于时序通过或板卡验证通过。

## 11. 静态合规规则（自查清单）

- 全工程只有一个时钟域：时序 `always` 的边沿只允许 `posedge clk`；异步复位边沿只允许 `negedge rst_n`（仅 `reset_sync.v` 使用外部 `rst_n`）或 `negedge rst_n_sync`。
- 无门控时钟、无 `clk_2m`、无 `BUFG` 手工插入、不把 `audio_out` 当时钟。
- 组合逻辑全部完整赋值，无锁存器（XST 报告中不得出现 latch 推断）。
- Verilog-2001：不使用 `logic`/`always_ff`/`always_comb`/`enum`/`typedef`/`$clog2`/`automatic` 等特性；generate 使用独立 `genvar i;` 声明，不写 `for (genvar i = ...)`。
- 具体时钟频率字面量只允许出现在 `src/finger_piano_cfg.vh`（testbench 的仿真参数除外）。

## 12. 已知限制与阶段二扩展点

**本阶段明确不实现**：ADC、DDS、显示屏/数码管、PWM 音量、和弦、UART、DCM/PLL、自动演奏器（小星星只是 testbench 输入序列）。**未做板卡验证**：没有引脚约束、没有烧录、没有实测频率。

后续扩展的接入位置：

- **显示当前音符/频率**：`note_debug` 已给出音符编码，直接接显示驱动模块；若显示需要刷新时基，用单周期使能 `ce_*` 而非新时钟。
- **PWM 音量**：在 `tone_generator` 输出之后插入 `pwm_volume`（同 `clk` 域），用高速计数器调制占空比；`audio_out` 语义不变。
- **DDS 正弦波**：把 `tone_generator` 的“半周期翻转”替换为相位累加器 + 正弦查找表（可用 `ip/` 下的分布式 ROM 或 Block RAM）；`SYS_CLK_HZ` 与相位增量仍由同一参数推导。

## 13. 验证记录

**本轮（第一阶段）验证结果：**

#### 综合（ISE 14.7 XST，远端 `fpga-vm` / PanGucheng）

- 构建编号：`20260914-144319-0599e47e`，阶段 `synth`，`xst` 退出码 0，工具流程 `COMPLETE`。
- `synthesis.srp`：**0 errors / 0 warnings / 0 infos**、`No errors in compilation`；无 latch 推断、无多驱动告警。
- 资源（`Final Register Report`）：231 个触发器、20 个 I/O。219 个来自 RTL 本身，另有 7 个 `stable_q` 因扇出被 XST 复制 12 次。实现/布局布线资源与时序结论**尚未产生**。
- 产物：`artifacts/20260914-144319-0599e47e/results/design.ngc`。
- 早前一次构建 `20260914-144156-edb3def6` **失败**（`HDLCompilers:28 ... has not been declared`，原因是两个位宽宏在使用处漏写反引号），修复后重跑通过；该失败目录保留以供追溯。
- `check -Project finger_piano -Stage implement` **按设计失败**（`Implementation needs a UCF and constraintsReviewed=true...`），证明没有绕过约束确认机制。
- 时序：本阶段未做实现，**不存在有效时序报告**，因此不声称时序通过；`summary.txt` 保持 `NEEDS_REVIEW`。

#### 仿真（远端 ISim / `fuse`，一次性 scratch 目录，不占用工具链入口）

仿真系统时钟参数取 1 MHz（仅为缩短运行时间，与板上晶振无关）。三个 testbench 各编译并运行一次，另加一次低有效极性复跑：

| 用例 | fuse 退出码 | 运行退出码 | 结果 |
|---|---|---|---|
| `tb_note_encoder` | 0 | 0 | PASS（checks=15, errors=0） |
| `tb_tone_generator` | 0 | 0 | PASS（checks=11, errors=0, sim_time=467296 ns） |
| `tb_finger_piano_top`（`KEY_ACTIVE_HIGH=1`） | 0 | 0 | PASS（checks=129, errors=0, sim_time=4527866 ns） |
| `tb_finger_piano_top`（`KEY_ACTIVE_HIGH=0`） | 0 | 0 | PASS（checks=129, errors=0, sim_time=4527866 ns） |

关键证据（均取自运行日志，日志已验证为纯 ASCII）：

- **同步 + 滤波窗口判据**（7 个音符逐一验证，不写死“恰好第 1000 周期”）：按键后第 999 个周期 `note_debug` 仍为 0（`window-low(999 cycles) must still be silent`），第 1008 个周期已经有效（`window-high(1008 cycles) must be valid`）。
- **毛刺拒绝**：300 周期脉冲（< 1000 周期稳定门限）之后 `note_debug`、`key_debug`、`audio_out` 均无变化。
- **七个音符频率**（1 MHz 仿真时钟下实测半周期计数，再与实数标称频率比较）：C4 1911 → 261.6431 Hz（+0.0088%）、D4 1702 → 293.7720 Hz（+0.0347%）、E4 1517 → 329.5979 Hz（−0.0097%）、F4 1432 → 349.1620 Hz（−0.0195%）、G4 1276 → 391.8495 Hz（−0.0358%）、A4 1136 → 440.1408 Hz（+0.0320%）、B4 1012 → 494.0711 Hz（+0.0387%）；最大误差 **0.0387% < 1%**。50 MHz 实际时钟下的理论误差见 `frequency_table.md`（≤0.011%）。
- **小星星序列**：14 个音全部按 `note_debug` 逐一核对，且每个音之后都观察到 `note_debug` 回到 0；其中 **6 个重复音符**（1、5、6、4、3、2）确认经历了 `key_stable` 的 `1 -> 0 -> 1`，即确实是两次独立按键，而不是被数字滤波并成一次长按。
- **输入极性**：`KEY_ACTIVE_HIGH` 为 1 与 0 两种配置下检查数与结论完全一致（均 129 checks / 0 errors）。
- 运行位置：远端 `C:\Users\PanGucheng\ise-builds\_sim\finger_piano\sim-20260914-144318`；本机日志副本 `tools/.work/sim-finger-piano-20260914-144318/received/`（`tools/.work` 已被 `.gitignore` 排除，不进入版本库）。

#### 仍待用户提供（这些是后续步骤的阻塞项）

- **实际有源晶振频率** → 修改 `src/finger_piano_cfg.vh` 的 `` `SYS_CLK_HZ ``，按 `frequency_table.md` 第 4 节重算表格，并重新综合。
- **芯片丝印速度等级** → 确认 `-4` 或改为 `-5`（改 `project.json` 一处字段）。
- **TQ144 最小系统板原理图引脚** → 填写 `constraints/finger_piano.ucf` 的 6 组 TODO 与全部 debug 端口，然后才可把 `constraintsReviewed` 置 `true` 并做 implement / bitstream。

> 注：`artifacts/` 目录被 `.gitignore` 排除，构建产物不进入版本库；需要留存时请单独归档。
