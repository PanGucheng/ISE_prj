# 手指钢琴（Finger Piano）——Spartan-3AN XC3S50AN 课设工程

3-bit 传感器输入的单音电子琴（正式 Stage-2 顶层）：3 个 LM393 比较器输出形成 `sensor_async[2:0]` 编码（`000 = 静音，001~111 = C4~B4`），音符经 **DDS → MCP4725（独立 I²C）→ 重构滤波 → LM386** 输出；三路模拟压力另经 **ADS1115（另一条独立 I²C）** 采集。原来的 7-key 方波电子琴 `key_in[6:0] → tone_generator → audio_out` 作为 **legacy baseline** 保留（`finger_piano_top`，已不再是工程顶层）。

> **架构状态说明（先读这一段）**
>
> - **正式顶层 = `finger_piano_stage2_top`**（12 个用户 I/O；P6B 已完成 UCF 冻结 / 综合 / 仿真 / 实现 / 时序）。`finger_piano_top`（7-key 方波）保留为 legacy baseline。
> - 真实硬件：**3 个 FSR + 3 个 LM393 → 3-bit 编码**；三路模拟压力经 ADS1115；音频链路 DDS → MCP4725 → 重构滤波 → LM386。
> - **压力数据当前没有硬件消费方**，因此在 12 脚 Stage-2 综合中 ADS1115 压力链被 XST 合法 trim（详见 §12.5 与 §13 第十四轮）；这不是缺陷。
> - 板卡功能、FSR 标定、MCP4725 模拟输出、LM386、扬声器**全部未上板验证**。
> - 项目宪法：[`AGENTS.md`](./AGENTS.md)；架构地图与状态：[`../../doc/README.md`](../../doc/README.md)

- 器件：`xc3s50an-4-tqg144`（**TODO：速度等级 `-4` 为暂定占位，必须以芯片丝印为准核对后修改 `project.json` 与本节**）
- 工具：Xilinx ISE 14.7（远端 Win7 `fpga-vm`），Verilog-2001，XST 综合
- 正式顶层：`finger_piano_stage2_top`（legacy baseline：`finger_piano_top`，保留）
- 时钟：外部 12 MHz 有源晶振（P57）作为**唯一**系统时钟；全工程只有一个时钟域 `clk`，无门控时钟、无逻辑产生的第二时钟

## 0. 当前状态（Toolchain Freeze v1 口径）

> 正式顶层已迁移到 Stage-2；legacy 7-key baseline 的验证事实保留在 §12 与
> §13 后续轮次。系统集成与引脚状态见 §12.5 / §12.6 与 §13 第十四轮。

**Stage-2 正式顶层（P6B，2026-09-16，均有无板上板工具证据）**：新顶层
`finger_piano_stage2_top`（wrapper only）、冻结 12 脚 UCF、stage2 top TB。
全量 `verify-20260916-153554-00e49086` **Overall PASS**（综合 0 errors /
166 条已审阅 trim 告警 / 0 unexpected / 0 latches / 12 IOs；33 个仿真全
PASS，含 legacy 与 P1~P6A 回归；implement 门禁 open）。实现
`20260916-154225-79f5b654`：MAP/PAR **0 errors / 0 warnings**、全布线、
`Timing Score: 0`。时序（本人读 `timing.twr`）：`TS_clk = PERIOD 83.33 ns`
满足、**0 timing errors**、最差 setup slack **70.968 ns**、`All constraints
were met.`。资源 12 IOs / 417 FF / 1101 LUT / 578 slices。**未烧录**。

**legacy baseline（stage-1，历史，已不再是工程顶层）**：RTL、综合（0 errors
/ 0 warnings）、6 个仿真用例、实现（MAP/PAR 0/0）、时序（`TS_clk = PERIOD
83.33 ns`：0 timing errors、最差 slack 70.697 ns）、bitstream
（`design.bit` 54 738 字节）、**JTAG 易失配置**（`-Mode Jtag`）、
**ISF erase/program/verify**（`-Mode Isf`，run
`program-20260915-083244-bf54acda`）。

**尚未完成（整个工程，外围硬件未搭建，未做测量）**：

```
power-cycle persistent boot   = NOT_TESTED   # 成功写入后尚未做断电启动验证
board functional test         = NOT_TESTED
sensor input test             = NOT_TESTED   # 压力传感器调理电路未搭建
audio output measurement      = NOT_TESTED   # 未用示波器/频率计测
MCP4725 analog output         = NOT_TESTED
LM386 test                    = NOT_TESTED
speaker test                  = NOT_TESTED
FSR calibration               = NOT_CALIBRATED
complete finger-piano acceptance = NOT_TESTED
userDesignFunctional          = NOT_TESTED   # Stage-2 顶层从未烧录/上板
```

**这些一律记为 `NOT_TESTED` / `NOT_CALIBRATED`，不得写成 FAIL。** 烧录结论
（`programmingVerified = VERIFIED`）与板卡功能结论是两件事，不可互相推导。

## 1. 顶层端口

### 1.1 正式顶层 `finger_piano_stage2_top`（12 个用户 I/O）

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk` | in | 1 | 外部 12 MHz 有源晶振（P57），唯一系统时钟 |
| `rst_n` | in | 1 | 低有效复位；顶层经 `reset_sync` 异步拉低、同步释放为 `rst_n_sync` |
| `sensor_async[2:0]` | in | 3 | LM393 3-bit 编码，`[0]`/`[1]`/`[2]` 权重 1/2/4（不得交换） |
| `adc_i2c_scl` / `adc_i2c_sda` | inout | 1+1 | ADS1115 独立 I²C（开漏 0/Z，外部 4.7 kΩ 上拉到 3.3 V） |
| `dac_i2c_scl` / `dac_i2c_sda` | inout | 1+1 | MCP4725 独立 I²C（开漏 0/Z，外部 4.7 kΩ 上拉到 3.3 V） |
| `note_debug[2:0]` | out | 3 | 同步+滤波+解码后的当前音符编码，0=无音符，1~7=C4~B4（= `note_code`） |

结构：`rst_n → reset_sync → finger_piano_system`（内含 P1~P5 全部数字基础设施），
`assign note_debug = note_code`；顶层不重实现任何子系统，不含 legacy
`key_in`/`key_debug`/`audio_out`，两条 I²C 完全独立。

### 1.2 legacy 顶层 `finger_piano_top`（7-key 方波 baseline，保留）

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
2. **`key_sync`**：两级触发器，消除外部输入相对 `clk` 的亚稳态。两级寄存器都带 `(* ASYNC_REG = "TRUE" *)`（纯属性，只影响 XST/PAR 的摆放，不改变逻辑），`reset_sync` 的两级寄存器同样带该属性。
3. **`key_filter`**：对每路按键独立计数，输入电平持续偏离当前稳定值达到 `STABLE_CYCLES` 才更新输出；短毛刺被完全拒绝。`KEY_FILTER_ENABLE=0` 时综合为纯直通（`assign`），不产生任何计数器。
4. **`note_encoder`**：纯组合优先级编码，`key_stable[0]` 最高优先（1 > 2 > 3 > 4 > 5 > 6 > 7），无按键输出 0。
5. **`tone_generator`**：对 `SYS_CLK_HZ` 做同步计数，半周期到达 terminal count 时翻转 `audio_out`；`note_code==0` 时输出 0 并清零计数；音符变化时相位重启（计数清零、输出清零），使演奏与仿真行为可预测。全程只有 `posedge clk`，没有用任何分频器输出当时钟。

## 4. 配置方法

**所有全局配置只改一个文件**：`src/finger_piano_cfg.vh`。

| 宏 | 默认 | 含义 |
|---|---|---|
| `` `SYS_CLK_HZ `` | `12000000` | **外部有源晶振频率 = 12 MHz（接 P57，2026-09-14 确认）**；所有时序常量都由它推导 |
| `` `KEY_STABLE_MS `` | `10` | 按键数字稳定滤波时间（ms），默认 10 ms |
| `` `KEY_FILTER_ENABLE `` | `1` | `1` 开启滤波；`0` 关闭（纯直通，零资源） |
| `` `KEY_ACTIVE_HIGH `` | `1` | `1`=按下为高；`0`=按下为低（外部比较器输出极性） |
| `` `FP_FILTER_CNT_WIDTH `` | `24` | 滤波计数器位宽 |
| `` `FP_TONE_CNT_WIDTH `` | `24` | 音频半周期计数器位宽 |

- **禁止**把具体频率写进其它模块：其他 RTL 只通过 `parameter SYS_CLK_HZ = `SYS_CLK_HZ` 取默认值，并由顶层参数向下覆盖。改频后 `frequency_table.md` 的表格需按同公式重算（见该文件）。
- UCF 中 `TIMESPEC PERIOD` 的 ns 值必须与 `` `SYS_CLK_HZ `` 一致：`PERIOD_ns = 1000 / SYS_CLK_MHz`。本工程 12 MHz → **`PERIOD = 83.33 ns`**，已写入 `constraints/finger_piano.ucf`。
- 仿真时不需要改动本文件：testbench 用参数覆盖（`#(.SYS_CLK_HZ(...))`）把系统时钟降到 1 MHz 以缩短仿真时间。

## 5. 与课程资料“2 MHz 分频”的对应关系

> 课程资料使用 2 MHz 时基分频作为基础实现提示。本工程为避免由普通逻辑产生新的内部时钟域，统一采用外部有源晶振作为唯一系统时钟，并通过同步计数器或 clock-enable 实现等效分频。若实际系统晶振可整数分频得到 2 MHz，可产生 `ce_2m` 单周期时钟使能，但不将其作为独立时钟驱动时序逻辑。

**本工程的最新情况**：板上 P57 已确认接 **12 MHz** 有源晶振，即系统时钟就是 12 MHz，因此本工程**不需要任何分频，也不需要 `ce_2m`**：`tone_generator` 直接对 12 MHz 计数得到七音半周期（见 `frequency_table.md`）。仍然禁止出现 `clk_2m` 之类的第二时钟域。（若将来确实需要 2 MHz 时基，12/2 = 6 为整数，只允许以单周期使能 `ce_2m` 的形式生成。）

即：**不允许**出现 `always @(posedge clk_2m)` 这类第二时钟域，也不允许把 `audio_out` 当时钟。本阶段没有实现 `ce_2m`（`tone_generator` 直接从 `SYS_CLK_HZ` 计数，功能等价且不需要中间时基）；阶段二若需要 2 MHz 时基，只允许以单周期使能 `ce_2m` 的形式接入。

## 6. 频率精度

七个音符的半周期计数值、理论输出频率和误差见 `frequency_table.md`。在当前的 **12 MHz** 下，全部音符误差绝对值 ≤ 0.0103%，远优于 1% 的课程要求；误差来源是半周期计数的整数取整，与晶振自身精度无关（晶振误差另计）。

## 7. UCF 引脚约束（`constraints/finger_piano.ucf`）

**活动 UCF 现在是 Stage-2 正式顶层的冻结分配**（用户 2026-09-16 确认，
VCCO 全部 3.3 V，IOSTANDARD 全部 LVCMOS33；已对 XC3S50AN-TQG144 DS557
逐脚核对）：

| Stage-2 信号 | LOC | Bank | 管脚名 | 说明 |
|---|---|---|---|---|
| `clk` | **P57** | 2 | `IO_L09P_2/GCLK0` | 12 MHz 有源晶振，唯一时钟；走 `IBUFG → BUFGMUX` |
| `rst_n` | **P3** | 3 | `IO_L02P_3` | 低有效，外部上拉/RC |
| `sensor_async[0]` | **P28** | 3 | `IO_L11P_3` | LM393 CH0，权重 1 |
| `sensor_async[1]` | **P29** | 3 | `IO_L10N_3` | LM393 CH1，权重 2 |
| `sensor_async[2]` | **P30** | 3 | `IO_L11N_3` | LM393 CH2，权重 4 |
| `adc_i2c_scl` | **P31** | 3 | `IO_L12P_3` | ADS1115 SCL |
| `adc_i2c_sda` | **P32** | 3 | `IO_L12N_3` | ADS1115 SDA |
| `dac_i2c_scl` | **P102** | 1 | `IO_L10P_1` | MCP4725 SCL |
| `dac_i2c_sda` | **P103** | 1 | `IO_L11P_1` | MCP4725 SDA |
| `note_debug[0]` | **P110** | 0 | `IO_L01P_0` | 当前音符编码 |
| `note_debug[1]` | **P111** | 0 | `IO_L01N_0` | 当前音符编码 |
| `note_debug[2]` | **P113** | 0 | `IO_L02N_0` | 当前音符编码 |
| 时钟周期 | `TIMESPEC "TS_clk" = PERIOD "clk_group" 83.33 ns HIGH 50%` | — | — | 12 MHz；改频后必须同步修改 |

共 **12 个用户 I/O**。实现报告 `routed_pad.txt` 实测 12 脚全部 `LOCATED`，
无自动分配 I/O；`design.pcf` 只有这 12 个 LOC。**不使用 P76/P77**
（`IO_L01P_1/HDC`、`IO_L02N_1/LDC0`，配置期 DUAL）；不给 I²C SCL
建 `TNM_NET`/时钟域；不加 `PULLUP`（真实上拉在板级）。

### 7.1 legacy 顶层 `finger_piano_top` 的历史引脚映射（已从活动 UCF 删除）

保留在 Git history 与本表中作为 legacy baseline 记录（该 top 已不是工程顶层）：

| 信号 | 引脚 |
|---|---|
| `clk` | P57 |
| `rst_n` | P3 |
| `key_in<0>`…`key_in<6>` | P4、P5、P6、P7、P8、P10、P11 |
| `audio_out` | P12 |
| `key_debug<0>`…`key_debug<6>` | P13、P15、P16、P18、P19、P20、P21 |
| `note_debug<0>`…`note_debug<2>` | P24、P25、P27 |

**刻意避开**的引脚：P1=TMS、P2=TDI（保留给 JTAG，占用会导致无法烧录）、
P9/P17/P26/P34=GND、P14/P23=VCCO_3、P40=VCCO_2、P22=VCCINT、P36=VCCAUX、
P33/P35=IPAD113/114（仅输入）。

命名规则：Verilog 向量端口在 UCF 中写成 `名字<下标>`，例如 `sensor_async<0>`。

## 8. `constraintsReviewed=true` 的前置条件（本工程已满足）

`constraintsReviewed=true` 是人工确认，不是工具时序结论。Stage-2 冻结引脚
的以下各项已由用户在 **2026-09-16** 确认，因此 `project.json` 中该字段保持
`true`：

```
[x] clk LOC 已核对（P57，接 12 MHz 有源晶振）
[x] clk IOSTANDARD 已核对（LVCMOS33，3.3 V）
[x] rst_n LOC 与电气条件（P3，低有效）已核对
[x] sensor_async[0..2] LOC 全部核对（P28/P29/P30，位序 1/2/4）
[x] adc_i2c_scl/sda LOC 已核对（P31/P32）
[x] dac_i2c_scl/sda LOC 已核对（P102/P103）
[x] note_debug[0..2] LOC 已核对（P110/P111/P113）
[x] 所有相关 Bank VCCO 均为 3.3 V，全部 IOSTANDARD 匹配（LVCMOS33）
[x] UCF 中 PERIOD 与实际有源晶振频率一致（83.33 ns ↔ 12 MHz）
[x] 未使用 P76/P77（配置期 DUAL）或额外 GCLK/RHCLK 作普通功能 I/O
```

若以后更换晶振或改板，必须重新执行本节核对并把 `constraintsReviewed` 置回
`false`。12 个用户 I/O 绝不允许在最终 bitstream 中处于“未约束、由工具自动
分配”的状态。

## 9. 仿真步骤

**首选方式（已固化进工具，不需要手工拼 fuse/prj/SFTP）**：本工程的六个仿真用例都写在 `project.json` 的 `simulations` 段里，直接用工具入口：

```powershell
pwsh -File .\ise.ps1 sim    -Project finger_piano -Test top_default   # 单个用例
pwsh -File .\ise.ps1 sim    -Project finger_piano                     # 全部 enabled 用例
pwsh -File .\ise.ps1 verify -Project finger_piano                     # 综合+静态+全部仿真+implement 门禁
```

每个用例在 `artifacts/sim-<时间戳>-<随机>/` 下留 `run.json`/`sim.json`/`summary.txt`/`results/`；判据是日志出现 `passPattern`（退出码 0 不算通过，无 PASS 无 FAIL 也判 FAIL）。下面 9.1/9.2 的手工步骤保留作为原理参考与排障手段。

`sim/` 下三个 testbench 都可独立运行，判据是最后打印的 `PASS` 行。

### 9.1 ISE 内置 ISim（图形界面）

1. 在 ISE Project Navigator 新建工程，器件选 `xc3s50an-4-tqg144`；
2. 加入 `src/` 下 6 个 `.v`（`.vh` 加到 include 路径：`Project → Properties → Verilog Include Directories` 填 `src`）；
3. 加入 `sim/` 下要跑的 testbench，顶层设为该 testbench，综合工具选 `ISim`；
4. 设置仿真参数（如需要）：`tb_finger_piano_top` 的 `TB_SYS_CLK_HZ` / `TB_STABLE_MS` / `TB_KEY_ACTIVE_HIGH` / `TB_KEY_FILTER_ENABLE`（最后一个为 0 时该 TB 自动切换成旁路最小用例）；
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

滤波旁路（`KEY_FILTER_ENABLE=0`）同样要重新 fuse 一次，随后 TB 会自动只跑旁路最小用例：

```cmd
fuse -prj sim_finger_piano_top.prj -top tb_finger_piano_top -i src -o tb_top_bp.exe --generic_top "TB_KEY_FILTER_ENABLE=0"
tb_top_bp.exe -tclbatch run_all.tcl -log ..\out\sim_top_bp.isim.log
```

注意：`--generic_top` 只能覆盖**顶层**参数（这里就是 testbench 自己的参数），所以两个参数都是通过 TB 顶层参数传给 DUT 的。

另外两个注意点：

- Windows CMD 下把退出码紧贴重定向符会引发解析问题（`echo %RC%>f.txt` 里的数字会被当成文件描述符），记录退出码时数字与 `>` 之间要留空格。
- 该 Win7 主机的 ISim 运行在 ANSI(GBK) 代码页下，**经过 task 参数传递的非 ASCII 文本会在日志里变成乱码**（`$display` 里的中文字面量反而正常）。因此三个 testbench 的**诊断文本一律使用 ASCII**，以保证运行日志可直接阅读与检索；中文说明保留在本文档与源码注释中。相应地，testbench 不使用中文 task 标签。

## 10. ISE 综合与实现（本工具流程）

改完 RTL/Testbench 的主要验收入口是 `verify`（综合 + 静态检查 + 全部仿真 + implement 门禁，并写出 `artifacts/verify-<id>/verification.json`）：

```powershell
pwsh -File .\ise.ps1 verify -Project finger_piano
```

只做综合时用下面两条；时序不会由工具自动认定，`report` 在有人实际阅读 timing.twr 之前只会给 `NOT_RUN`/`NEEDS_REVIEW`：

```powershell
pwsh -File .\ise.ps1 report -Project finger_piano -Latest
pwsh -File .\ise.ps1 check  -Project finger_piano -Stage synth
pwsh -File .\ise.ps1 build  -Project finger_piano -Stage synth
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

**本阶段明确不实现**：ADC、DDS、显示屏/数码管、PWM 音量、和弦、UART、DCM/PLL、自动演奏器（小星星只是 testbench 输入序列）。**板卡验证状态**：引脚约束已按用户确认的板卡信息填写（P57 12 MHz / P3 / P4–P11 / P12 / P13–P21 / P24–P27，LVCMOS33），实现与 bitstream 已生成，`-Mode Jtag`（易失，`program -onlyFpga`）与 `-Mode Isf`（非易失，`program -p 1 -e -v`，显式擦除门禁）均已真机跑通（见 §13 第七轮），但**仍未上板实测**——未做断电保持启动测试、未用示波器/频率计实测音高，`userDesignFunctional` 保持 `NOT_TESTED`。

后续扩展的接入位置（第二阶段的独立计划见 `doc/3bit传感器编码输入基础设施开发计划.md`、`doc/DDS正弦音频发生器开发计划.md`、`doc/DDS到MCP4725数字音频链路集成计划.md`、`doc/ADS1115压力数据处理与标定基础设施开发计划.md`、`doc/ADS1115与MCP4725可选外设开发计划.md`）：

- **显示当前音符/频率**：`note_debug` 已给出音符编码，直接接显示驱动模块；若显示需要刷新时基，用单周期使能 `ce_*` 而非新时钟。
- **PWM 音量**：在 `tone_generator` 输出之后插入 `pwm_volume`（同 `clk` 域），用高速计数器调制占空比；`audio_out` 语义不变。
- **DDS 正弦波**：把 `tone_generator` 的“半周期翻转”替换为相位累加器 + 正弦查找表（可用 `ip/` 下的分布式 ROM 或 Block RAM）；`SYS_CLK_HZ` 与相位增量仍由同一参数推导。

### 12.1 可选外设(P1:ADS1115 / MCP4725 驱动基础设施,默认关闭)

P1 五个提交(A~E)已落地,**IMPLEMENTED / STANDALONE**:`src/periph/` 下的
`i2c_master.v`(命令级开漏主机)、`ads1115_ctrl.v`(三通道轮询采集,
OS 轮询+超时)、`mcp4725_ctrl.v`(仅 Fast Write,pending+overrun 缓冲),
配套协议模型与三个 TB(58/40/73 checks)。协议依据为仓库内
`doc/ads1115.pdf` 与 `doc/MCP4725.pdf`。设计细节、I²C 拍数公式、ENABLE 宏
语义与接线规划见 [doc/ADC_DAC扩展设计.md](../../doc/ADC_DAC扩展设计.md)。

**默认全关**:ENABLE 宏为 0、顶层无端口、无实例化、UCF 无 I²C LOC
(引脚待用户逐脚确认,见 doc/README.md §12.3 候选分配);综合网表
232 FF / 20 I/O 与 legacy 基线一致,方波路径未受影响。**7 键 RTL 仍是
legacy baseline**,真实硬件(3×LM393 → 3-bit 编码)迁移在上板前单独进行。

### 12.2 3-bit 传感器输入基础设施(P2,IMPLEMENTED / SIMULATED / INTEGRATED)

P2 四个提交(p2a/p2b/p2c + 文档 p2e)已落地:`src/input/` 下的 `sensor_code_decoder.v`
(编码表语义边界,000=静音,001~111=C4~B4)、`sensor_code_filter.v`
(**整体码字原子滤波**:单一 candidate + 单一计数器,N-1 拍不更新、第 N 拍
一次性更新,杜绝 001→011→111 逐 bit 滤波的短暂错音)、`sensor_code_frontend.v`
(极性归一化 → 复用 `key_sync` WIDTH=3 两级同步 → 原子滤波 → 解码),
配套三个 TB(8/29/6 checks)与 4 个仿真(含 ACTIVE_HIGH=0 低有效套件)。
状态:**INTEGRATED**(经 `finger_piano_system` 进入 Stage-2 顶层,引脚
P28/P29/P30 已冻结)。验收:verify-20260916-015815-edd2f5fa 全量 PASS。

### 12.3 DDS 正弦音频发生器(P3,IMPLEMENTED / SIMULATED / INTEGRATED / NOT_BOARD_TESTED)

P3 六个提交(A~F)已落地:`src/audio/sine_lut_12bit.v`(quarter-wave
65×11 bit 查表,256 相位合成,范围 256~3840,中心 2048)、
`src/audio/dds_sine_generator.v`(24 bit 相位累加器 + 8 kS/s clock-enable
采样节拍,12 MHz 下 SAMPLE_DIV=1500;音符切换相位归零且**不改变采样节拍**,
静音持续输出 0x800;无 ready 输入,时间轴独立)、
`projects/finger_piano/dds_frequency_table.md`(七音 phase increment 冻结表,
与方波 frequency_table.md 分开维护)。验收:17 个仿真全 PASS——七音零交叉
实测误差全部 ≤0.4%,phase increment 与独立 real 数学计算逐位一致,12 MHz
下 50 个 valid 间隔全部精确 1500 拍,ENABLE=0 恒 0x800/valid=0。
**已进入 Stage-2 顶层(P4/P6B),但 DDS/模拟音频硬件从未上板验证。**

### 12.4 DDS → MCP4725 数字音频链路(P4,IMPLEMENTED / SIMULATED / INTEGRATED / NOT_BOARD_TESTED)

P4 四个提交(p4a/p4b/p4c+d/p4f)已落地:`src/audio/dds_mcp4725_pipeline.v`(纯结构化
集成层:DDS 固定 8 kS/s 时间轴直连 mcp4725_ctrl,无第二采样计数器、无
FIFO、无 ready 反馈进入 DDS)+ `sim/tb_dds_mcp4725_pipeline.v`(scoreboard
逐样点比对 + 全局 ready/延迟/范围/EEPROM 监视,4 个仿真入口)。验收
(verify-20260916-030251-5159ebcd,21 个仿真全 PASS):12 MHz 真实参数下
7168 样点全部 生成/接受/Fast Write(0 drop / 0 overrun / 0 scoreboard
错误),ready 在每个 valid 时为 1,最大事务延迟 1014 clk < 1500 clk,
捕获流频率抽检 C4 −0.02% / A4 +0.01% / B4 +0.04%,地址可参数化(0x61
验证),NACK 丢弃样点不重传且可恢复,mid-transaction reset 干净恢复,
EEPROM 写全程 0。状态:**端到端数字音频流 PASS,已进入 Stage-2 顶层**
(DAC I²C 引脚 P102/P103 已冻结);模拟输出/重构滤波/LM386 仍未验证
(§39/§40)。



### 12.5 压力数据处理(P5,RTL-INTEGRATED / SYSTEM-SIMULATED / 当前 Stage-2 综合中 INTENTIONALLY SYNTHESIS-TRIMMED / ZERO CALIBRATION NOT MEASURED)

P5 五个提交(p5a/p5b/p5c/p5d + p5f)已落地:`src/pressure/` 三模块 ——
`pressure_frame_capture.v`(三通道轮询扫描帧原子锁存,frame_valid 单 clk)、
`pressure_channel_corrector.v`(负码钳 0、不取绝对值、零点减法、下溢饱和,
输出 15 bit unsigned)、`pressure_processor.v`(三通道包装,valid 与数据
同沿),外加 `sim/tb_ads1115_pressure_pipeline.v`(ADS1115 模型 → driver →
processor 全链路)。刻意不做:阈值分级、压力融合、归一化、电压/牛顿换算、
stale timeout。三个 `CFG_PRESSURE_CHx_ZERO` 默认 0(**UNMEASURED DEFAULT**),
标定方法与全部 TODO 表格见
[pressure_calibration.md](pressure_calibration.md)(STATUS = NOT_CALIBRATED)。
验收:25 个仿真全 PASS,含端到端用例(负码/1000/2500 + 零点 0/100/200 →
0/900/2300 经真实 I2C driver)。

**P6B 之后的实际归属**:P5 已由 `finger_piano_system` 实例化并进入正式
Stage-2 顶层,系统级仿真(含真实 I²C driver)全部 PASS。但当前 12 脚 Stage-2
顶层**没有压力数据的硬件消费方**(`pressure_ch0/1/2`/`pressure_valid` 不引出
引脚,压力→音量/音高映射属于后续独立计划),因此 XST 在本设计中**合法地
trim 掉 ADS1115 压力链与相关 debug 出口**,并产生 166 条已审阅的
"unconnected/constant, will be trimmed" 告警(见 §13 第十四轮的白名单)。
**这是有意为之、不是缺陷**:不得用 `KEEP`/`DONT_TOUCH` 或假消费者去对抗
优化;等后续实现 pressure→audio 消费方后,该层级会自然保留在网表中。

### 12.6 stage-2 系统集成(P6A + P6B,STAGE2 TOP = INTEGRATED / IMPLEMENTED / NOT_BOARD_TESTED)

P6A 五个提交(p6a~p6e)落地 `src/system/finger_piano_system.v`——P1~P5
模块的**纯结构化连接层**(sensor frontend → note_code → DDS/MCP4725
pipeline;ADS1115 controller → pressure_processor),ENABLE_ADC/ENABLE_DAC
独立门控,无系统总控 FSM、无 reset_sync 重复实例化、压力链与音符链解耦、
两条 I²C 物理总线保持独立。

P6B 落地正式物理顶层 `src/finger_piano_stage2_top.v`(wrapper only:
`reset_sync` + `finger_piano_system` + `note_debug = note_code`)、
`sim/tb_finger_piano_stage2_top.v`(29 checks)与冻结 12 脚 UCF;
`project.json` 的 `top` 已切为 `finger_piano_stage2_top`。综合
12 IOs / 417 FF / 1101 LUT,实现 MAP/PAR 0/0、`Timing Score: 0`,
`TS_clk = PERIOD 83.33 ns` 0 timing errors、最差 slack 70.968 ns;
全量 verify Overall PASS(33 仿真)。legacy `finger_piano_top` 与其
6 个仿真用例继续保留作回归参考。

系统级 TB(`sim/tb_finger_piano_system.v`,真实 12 MHz 节拍 + 真实 10 ms
滤波门限)验证(P6 计划 §17~§28):
- 复位态输出确定、双总线释放;ADC 自动扫描 → pressure 1000/2000/3000;
- 000~111 全码遍历:stable 门限门控切换,MCP 捕获音频与独立泰勒级数
  LUT 模型(同 8-bit 相位量化)**逐样点匹配(±1 LSB)**;
- CH0 源注入 500→5000→20000:压力跟随、note 与 DAC 流纹丝不动;音符
  快速切换不打断 ADC 帧;
- ADC NACK / DAC NACK 互相隔离;双总线事务中复位:总线释放、状态清零、
  双链完整重启;
- ENABLE 四种组合(11/00/10/01),关闭侧总线静默监视;
- longrun:真实 860 SPS 下 C4 连续 8224 样点逐点匹配,8319 DAC 帧 +
  223 ADC 帧零错误。
状态:**STAGE2 TOP SIM = PASS / INTEGRATED / IMPLEMENTED;BOARD =
NOT_TESTED;未执行任何 `program`**。物理上板(传感器、I²C 器件、模拟音频)
从未验证。

## 13. 验证记录

### 第十四轮:P6B 最终顶层与 UCF 迁移(2026-09-16)

**这是本工程第一次把真实 3-bit 传感器 + 双 I²C 架构作为正式 FPGA 顶层。**
未改任何 P1~P6A 已验证 RTL(仅新增顶层与 TB)。提交序列:`p6b`(计划文档
392336e)→ `p6ba`(98e8960,stage2 top 源文件)→ `p6bb`(9c2c507,stage2 top TB
与仿真入口)→ `p6bc`(43bd961,UCF 迁移)→ verify 白名单工具提交(f9693bd)→
`p6bd`(754c07c,top 切换)→ 全量 verify(本轮)。

- **新顶层** `src/finger_piano_stage2_top.v`:`wrapper only`——外部 `rst_n`
  → 现有 `reset_sync` → `rst_n_sync` → `finger_piano_system`;
  `assign note_debug = note_code`。不重实现任何子系统,不含 legacy
  `key_in[6:0]`/`audio_out`,两条 I²C 仍完全独立,全工程仍单 `clk` 域。
- **引脚冻结(用户 2026-09-16 确认,全部 LVCMOS33,VCCO=3.3 V)**:
  `clk`=P57、`rst_n`=P3、`sensor_async[0..2]`=P28/P29/P30、
  `adc_i2c_scl/sda`=P31/P32、`dac_i2c_scl/sda`=P102/P103、
  `note_debug[0..2]`=P110/P111/P113。共 **12 个用户 I/O**,XST 实测
  `Number of IOs: 12`。不使用 P76/P77 等配置期 DUAL 脚。
- **新 UCF**(`constraints/finger_piano.ucf`)按功能重整:
  SYSTEM CLOCK / RESET / 3-BIT SENSOR INPUT / ADS1115 I2C / MCP4725 I2C /
  NOTE DEBUG / TIMING;删除 legacy 无效 NET(`key_in*`/`key_debug*`/
  `audio_out`/旧 `note_debug`);不写 PULLUP,不给 I²C SCL 建时钟域(唯一
  `TNM_NET`/`TIMESPEC` 仍只在 `clk`,`TS_clk = PERIOD 83.33 ns`)。
- **stage2 top TB**(`sim/tb_finger_piano_stage2_top.v`,29 checks 全过):
  复位态 `note_debug=000` 且双总线释放;真实 10 ms 门限下
  `sensor 000/001/011/111/000 → note_debug 0/1/3/7/0`;note 1/7/mute 都产生
  MCP4725 Fast Write(mute 段逐样点 0x800);ADS 模型 1000/2000/3000 →
  系统内部 pressure frame;双总线事务 > 0 且 `adc_error`/`dac_error`/
  `dac_overrun` 全 0;无 EEPROM 命令;再次复位干净。运行:
  `sim-20260916-154045-3f5a4e43`(单测另见 `sim-20260916-152125-85857e36`)。
- **综合裁掉的是没有硬件消费方的层级(有意,非缺陷)**:12 脚顶层没有
  消费 `pressure_ch0/1/2`/`pressure_valid`/`sensor_code_stable`/
  `adc_error`/`dac_error`/`dac_overrun` 以及 DDS/MCP debug 口的引脚,因此
  XST 合法地把 ADS1115 压力链与 debug 出口整段 trim,并报 166 条
  "unconnected/constant, will be trimmed" 告警(`Xst:2677`×155、
  `Xst:646`×2、`Xst:1710`×4、`Xst:1895`×5)。这类告警**不是**功能/时序
  问题,但会触发 `failOnSynthesisWarnings`。经用户批准,工具新增
  `verification.synthesisWarningAllowlist`(窄口径、逐条 id+正则+期望计数),
  **保持 `failOnSynthesisWarnings=true`**:只有这 166 条已审阅条目算
  allowed,任何其他 warning、新路径或计数漂移仍判 FAIL(原始 `.srp` 不改写,
  不使用 `XIL_XST_HIDEMESSAGES`,也不加 KEEP/DONT_TOUCH/假消费者)。
  P5 压力处理因此是 **RTL-INTEGRATED / SYSTEM-SIMULATED,但在当前 12 脚
  Stage-2 综合中被有意 trim**(无硬件消费方),待后续实现 pressure→audio
  消费方后自然保留在网表中。
- **综合基线**(run `20260916-153555-b4d6b31b`):0 errors / 0 latches,
  warnings 166(166 allowed / 0 unexpected),**12 IOs**、417 FF、1101 LUT、
  578 slices、1 GCLK。与 legacy 232 FF / 20 IOs 不同属正常(P6B §31)。
- **全量 verify**(`verify-20260916-153554-00e49086`)Overall **PASS**,
  Stage `IMPLEMENT_ALLOWED`:配置/静态检查 PASS,综合 0 errors / 166 allowed /
  0 unexpected / 0 latches,implement 门禁 PASS;**33 个仿真全部 PASS**
  (legacy 6 + P1 3 + P2 4 + P3 4 + P4 4 + P5 4 + 系统 7 + stage2_top 1),
  legacy/P1~P6A 回归零失败。

状态:STAGE2 TOP = IMPLEMENTED;STAGE2 TOP SIM = PASS;UCF = CONFIRMED;
BOARD = **NOT_TESTED**;未执行任何 `program`。

**实现与引脚核对**(run `20260916-154225-79f5b654`,`build -Stage implement`):
translate/map/par 退出码 0;**MAP 0 errors / 0 warnings**、**PAR 0 errors /
0 warnings**、`All signals are completely routed`、`Timing Score: 0`;
`routed_pad.txt` 中 12 个用户 I/O 全部 `LOCATED`,库与电平与冻结表一致
(P57 clk/Bank2、P3 rst_n/Bank3、P28/P29/P30 sensor/Bank3、P31/P32
adc_i2c/Bank3、P102/P103 dac_i2c/Bank1、P110/P111/P113 note_debug/Bank0,
全部 `LVCMOS33`),`Number of bonded IOBs: 12`,**无自动分配 I/O**。

**时序(本人阅读 `timing.twr`,非工具自动结论)**:`Timing constraint:
TS_clk = PERIOD TIMEGRP "clk_group" 83.33 ns HIGH 50%` → 31512 paths /
1814 endpoints / **0 failing,0 timing errors**(0 setup / 0 hold /
0 component switching limit),`Minimum period is 12.362ns`,**最差 setup slack
70.968ns**,component switching limit 最差 slack 80.126ns,报告结尾
`All constraints were met.` / `Timing errors: 0  Score: 0`。UCF 未写
`OFFSET IN/OUT`,`Unconstrained OFFSET IN BEFORE` / `OFFSET OUT AFTER` /
`Unconstrained path analysis` 各段都是「无约束可查」且 0 errors,因此只能
说明没有违反任何已写约束,不能解释为板级 I/O 时序已认证。工具 `summary.txt`
照旧输出 `Timing: NEEDS_REVIEW`。

### 第十三轮:P6A stage-2 系统数字集成(system core + 系统级仿真,2026-09-16)

**未改任何 legacy RTL、顶层端口与 UCF**;新增 `src/system/finger_piano_system.v`
(纯连接层)、`sim/tb_finger_piano_system.v`(7 个 TB_MODE)、P1/P5 计划文档
状态收尾与 cfg 宏清理(`CFG_DDS_PHASE_BITS` 伪参数删除)。提交序列:
`p6a`(81e4008,文档)→ `p6b`(e7199cd,system core)→ `p6c`(c55e12d,
基础系统 TB)→ `p6d`(3e40acf,双总线/隔离/ENABLE 组合)→ `p6e`(本文档)。

- **system core(P6 §5~§14)**:sensor frontend → note_code →
  dds_mcp4725_pipeline;ads1115_ctrl → pressure_processor 直连;
  ENABLE_ADC/ENABLE_DAC 独立 generate 门控;无总控 FSM、无第二复位、
  无压力→音符耦合、双 I²C 保持独立。加入 sources 但 top 不变,
  综合 0 errors / 0 warnings,**232 FF / 20 I/O 与 legacy 基线一致**
  (P6 §33 反向检查:模块被编译后 trim)。
- **系统级 TB**:真实 12 MHz 节拍 + 宏 10 ms 滤波门限;MCP 捕获流与
  **独立 real 泰勒级数 LUT 模型逐样点比对(±1 LSB,同 8-bit 相位量化
  语义)**。本轮踩过并修掉:TB 时钟先用 100 MHz 导致全拍数常数失真;
  system core 未透传 STABLE_MS 而 TB 按 1 ms 等待(stable 永远落后一档);
  过零测频公式量纲/半周期因子错误且计数系统性缺漏(改为逐点波形匹配);
  wave 期望误用 24-bit 精确相位(8-bit 量化差最高数百 LSB);MODE 1
  窗口起点 k0 超出搜索上限;MODE 2 错误计数基线跨复位失效。
- **7 个系统仿真全 PASS**:basic(58 checks:复位态、压力 1000/2000/3000、
  全码遍历 768 样点/音逐点匹配、mute 恒 0x800)、dual_i2c(CH0 注入
  500→5000→20000 压力跟随而 note/DAC 不变、切音符不断扫)、
  error_isolation(ADC NACK ↔ DAC 隔离、双事务中复位干净重启)、
  longrun(真实 860 SPS:C4 连续 8224 样点逐点匹配、8319 DAC 帧 +
  223 ADC 帧、0 错误)、disabled/adc_only/dac_only(ENABLE 四组合 +
  关闭侧总线静默监视)。

**验收**:全量 verify Overall PASS(综合 0 errors / 0 warnings /
0 latches,232 FF / 20 IOs 不变;32 个仿真全部 PASS:legacy 6 + P1 3 +
P2 4 + P3 4 + P4 4 + P5 4 + 系统 7)。P6A 状态:**SYSTEM DIGITAL CORE =
SIMULATED / NOT_TOP_INTEGRATED / NOT_BOARD_TESTED**;**FINAL TOP = NOT
MIGRATED**——P6B(新增 stage2 top、UCF 重整、top 切换)必须等待用户对
7 个接口引脚逐脚确认后才能开始。


### 第十二轮:P5 压力数据处理基础设施(frame capture / corrector / processor,2026-09-16)

**未改任何 legacy RTL、顶层端口与 UCF**;新增 `src/pressure/` 三个模块、
三个 TB、一个全链路 TB 与 `pressure_calibration.md`。提交序列:
`p5a`(78e8de0)→ `p5b`(ad284a2)→ `p5c`(a83f47c)→ `p5d`(d025f6e)→
全量 verify → 标定文档与本文档(`p5f`)。

- `pressure_frame_capture`:三通道轮询扫描帧**原子**锁存(§7),frame_valid
  严格 1 clk,无 valid 时帧保持,无假 valid。
- `pressure_channel_corrector`:负码一律钳 0(**不取绝对值**,§23),
  零点减法 + 下溢饱和(无 unsigned 绕回),输出 15 bit unsigned;
  计划 §22 的 9 行真值表全过(20 checks)。
- `pressure_processor`:三通道包装(方案 A,§18),pressure_valid 与新帧
  同沿对齐(§17);通道独立性 TB(只改 CH0 只变 P0,§26)。
- **全链路 TB**:ads1115_model(FFFF/1000/2500)→ ads1115_ctrl →
  processor,零点 0/100/200 → P=(0,900,2300)(§47),负码经真实 I2C
  字节序后仍正确钳 0。
- 明确未做(§14/§15/§20/§21/§36~§38):满量程、阈值分级、归一化、
  电压/牛顿换算、压力融合、音量/音高映射、stale timeout、ENABLE 宏。
- 标定:`pressure_calibration.md` STATUS = NOT_CALIBRATED,全部 TODO 为
  真实 TODO,零点宏默认 0(UNMEASURED)。

**验收**:verify-20260916-031854-e3c00f1e Overall PASS:综合 0 errors /
0 warnings / 0 latches,232 FF / 20 IOs;25 个仿真全部 PASS(legacy 6 +
P1 3 + P2 4 + P3 4 + P4 4 + P5 4)。P5 状态:**SIMULATED /
NOT_TOP_INTEGRATED / ZERO CALIBRATION NOT MEASURED / NOT_BOARD_TESTED**。


### 第十一轮:P4 DDS→MCP4725 端到端数字音频链路(pipeline / 吞吐 / 错误恢复,2026-09-16)

**未改任何 legacy RTL、顶层端口与 UCF**;新增 `src/audio/dds_mcp4725_pipeline.v`
(纯结构化集成层)与 `sim/tb_dds_mcp4725_pipeline.v`。提交序列:
`p4a`(5f4b95b)→ `p4b`(9e93a09)→ `p4c/d`(54879d2)→ 全量 verify →
本文档(`p4f`)。

- **吞吐(真实 12 MHz / 8 kS/s / ~333 kHz I2C)**:7168 样点
  (mute 512 + C4 2048 + A4 2048 + B4 2048 + mute 512)全部
  生成 / 被 controller 接受 / 完成 Fast Write;0 drop / 0 overrun /
  0 dac_error;scoreboard 逐样点 0 mismatch;ready 在每个 valid 采样沿
  均为 1;最大事务延迟 1014 clk < 1500 clk 采样周期。
- **频率抽检(观察点在 I2C 后的模型捕获流,首末过零点间隔估计)**:
  C4 −0.019% / A4 +0.009% / B4 +0.039%。
- **错误与恢复**:地址 NACK、数据 NACK → dac_error 脉冲、当拍样点丢弃
  (不重传过时音频)、controller 恢复 idle、后续样点继续;过载注入
  (独立 controller 高速刺激)→ overrun 置位且 pending 不被覆盖;
  mid-transaction reset → 总线释放、busy=0、复位后完整新帧;
  地址参数化经 0x61 验证;EEPROM 写全程 0。
- 本轮踩过并修掉:scoreboard 数组 4096 深度小于 7168 样点序列(回绕假错);
  过零计数 ±1 量化(±1.5%)超 1% 预算 → 改首末过零点间隔估计(±0.05%);
  mid-tx reset 误清错误统计(累计计数只在上电复位清零)。

**验收**:verify-20260916-030251-5159ebcd Overall PASS:综合 0 errors /
0 warnings / 0 latches,232 FF / 20 IOs;21 个仿真全部 PASS(legacy 6 +
P1 3 + P2 4 + P3 4 + P4 4)。P4 状态:端到端**数字**音频流 PASS;
**SIMULATED / NOT_TOP_INTEGRATED / NOT_BOARD_TESTED**——模拟输出、重构
滤波、LM386、扬声器均未验证。

### 第十轮:P3 DDS 正弦音频发生器(LUT / DDS 核心 / 七音验证,2026-09-16)

**未改任何 legacy RTL、顶层端口与 UCF**;新增 `src/audio/` 两个模块、
两个 TB、`dds_frequency_table.md`。提交序列:`p3a`(20c230b)→
`p3b`(20ae0a2)→ `p3c`(3f7cd03)→ `p3d`(b0c9ee4)→ `p3e`(fb00f7b)→
本文档(`p3f`)。

- `sine_lut_12bit`:quarter-wave 65×11 bit 常量 case(离线脚本生成的
  round(1792·sin(kπ/128)),RTL 无 real/$sin),四象限合成 12 bit 偏置
  正弦;TB 全 256 相位遍历:范围/四关键点/反对称 ±1LSB/单调不减/
  独立 real 数学复核(708 checks)。
- `dds_sine_generator`:SAMPLE_DIV=1500(12 MHz/8 kHz 精确整除),
  相位仅在 sample_tick 前进(24 bit 自然溢出),音符切换相位归零且
  **采样节拍不变**,静音持续 0x800,无 ready 输入(时间轴独立),
  ENABLE=0 无任何计数器。
- 七音实测:8192 样点/音零交叉测频,误差全部 ≤0.4%;phase increment
  与独立 real 计算逐位一致(548657/615871/691284/732388/822063/922747/
  1035741);12 MHz 下 50 个 valid 间隔全部精确 1500 拍且 1 clk 宽;
  全程 dac_code ∈ [256,3840] 无 X。
- 本轮踩过并修掉:XST 再次拒绝 generate 内 localparam(SAMPLE_DIV 移到
  模块作用域);TB 首稿漏写时钟生成器与 DUT 实例(未入库即被拦截)。

**验收**:verify-20260916-023327-306facb2 Overall PASS:综合 0 errors /
0 warnings / 0 latches,232 FF / 20 IOs;17 个仿真全部 PASS(legacy 6 +
P1 3 + P2 4 + P3 4)。P3 状态:**SIMULATED / NOT_INTEGRATED /
NOT_BOARD_TESTED**(DDS→MCP4725 链路属 P4;不得声称 DDS 硬件已验证)。



### 第九轮:P2 3-bit 传感器输入基础设施(decoder / filter / frontend,2026-09-16)

**未改任何 legacy RTL、顶层端口与 UCF**;新增 `src/input/` 三个模块与三个 TB。
提交序列:`p2a`(776659d)→ `p2b`(c454e22)→ `p2c`(1821585)→ 全量
verify(集成已分布在 A~C 的 project.json 增量中)→ 本文档(`p2e`)。

- `sensor_code_decoder`:显式 case 编码表(000=静音,001~111=C4~B4),
  8/8 编码 TB PASS;按设计无非法编码逻辑。
- `sensor_code_filter`:整体码字原子滤波(单一 candidate + 单一计数器 +
  stable 寄存器),N-1 拍不更新、第 N 拍一次性更新(off-by-one 由 TB 锁死);
  短暂中间码零泄漏(逐拍允许集合监视);candidate 改变计数重记;
  回 stable 清零;ENABLE=0 纯直通。TB 用缩短参数(10 kHz / 1 ms → N=10)。
- `sensor_code_frontend`:极性归一化(唯一反相点,ACTIVE_HIGH 参数)→
  复用 key_sync WIDTH=3 → 原子滤波 → 解码;high/low 两套仿真均 PASS,
  低有效套件验证物理111→逻辑000、110→001、000→111 的极性映射;
  快速中间码 001→011(短)→111 全程无短暂 note 3。

**验收**:verify-20260916-015815-edd2f5fa Overall PASS:综合 0 errors /
0 warnings / 0 latches,registers 232 / IOs 20(与基线一致);13 个仿真
全部 PASS(legacy 6 + P1 3 + P2 4)。P2 功能状态:**SIMULATED /
NOT_INTEGRATED / BOARD PINS TODO**(3 个 LM393 引脚待用户逐脚确认,
顶层迁移属 §31 独立提交)。



### 第八轮:P1 可选外设驱动基础设施(i2c_master / ads1115_ctrl / mcp4725_ctrl,2026-09-15 ~ 09-16)

**未改任何 legacy RTL、顶层端口与 UCF LOC**;新增 `src/periph/` 三个模块、
两个协议模型、三个 TB、cfg.vh 外设宏(默认全关)。提交序列:
`p1a`(12ea8d2)→ `p1b`(91c65ee)→ `p1c`(9a019d2)→ `p1d`(84a0afd)→ 本文档(`p1e`)。

- `i2c_master`:命令级 START/RESTART/WRITE/READ/STOP,开漏 0/Z,粘滞
  error_code(0/1 NACK/2 timeout/3 protocol),写 NACK 自动补 STOP,逐命令
  看门狗;master 不区分地址/数据字节,拍数全部由 controller 传入。
- `ads1115_ctrl`:三通道"写配置→轮询 Config.OS(≥2ms 等待超时)→读转换",
  配置字由手册位域拼接(C3E3/D3E3/E3E3),原始 16-bit 有符号输出。
- `mcp4725_ctrl`:仅 Fast Write(首字节高半字节恒 0000,EEPROM 命令结构上
  不可能),一项 pending + overrun(拒绝 latest-value-wins),VOUT 语义按
  第三字节 ACK 沿;t_BUF 按 MCP 手册 1300ns。
- 拍数分层:12 MHz + 333333 → 固定 18+18=36 拍(actual 333333.333 Hz);
  其它速率走强制公式(先除后取整避免 32 位溢出);吞吐 TB 实测 120/120
  样点 0 overrun / 0 drop,SCL 高段全部 18 拍。
- 本轮踩过并修掉的真 bug:XST 拒绝 generate 块内 `localparam`(ISim 却
  接受,故单测全绿而综合 6 errors——localparam 已全部移到模块作用域);
  controller 完成判定补"master 即时拒绝(cmd_ready 从不拉低)"路径;
  ads1115 OS 位误用越界 `poll_hi[15]`(应为高位字节的 bit7);轮询未关
  事务就再发 START(违反自身 xact 纪律);mcp4725 FSM 漏写 S_ERR 分支。

**验收**:verify-20260916-013752-c8254ef6 Overall PASS(stage
IMPLEMENT_ALLOWED):综合 0 errors / 0 warnings / 0 latches,
registers 232 / IOs 20(与 P1 前完全一致);9 个仿真全 PASS
(legacy 6 + i2c_master 58 checks + ads1115_ctrl 40 + mcp4725_ctrl 73);
implement 门禁 PASS。外设功能状态:**SIMULATED / NOT_INTEGRATED /
NOT_BOARD_TESTED**(仿真 PASS ≠ 板卡可用)。


### 第七轮：JTAG 烧录稳定性 + ISF 写入只读诊断（2026-09-14 ~ 09-15）

**易失 JTAG 路径（`-Mode Jtag`，`program -onlyFpga`）已实测稳定**：连续两次真机 PASS，`Programming device` / `Completed downloading bit file to device` / `DONEIN=1` / `CRC error=0`，且**无 `Programming Flash`、无 SPI access core**；并读回 `MODE pins M[2:0] = 011`。下载线已固定为
`cableSerial = 210241672559`、`cableFrequencyHz = 10000000`（来自 52 条真实成功转录，非默认值），正式路径不再使用 `-p auto`；preflight 与写入合并进**同一个远端 `hardware_transaction.cmd`**，两者之间无 sleep/SSH/SFTP。

**内部 ISF 写入当前存在未解决问题（写入自称成功、校验恒定失败）**：

| 时间 | 命令 | 结果 |
|---|---|---|
| 09-14 21:14 / 21:18 | `assignFile` + `program -p 1 -v` | ✅ `Verification completed successfully`，DONE 拉高 |
| 09-15 08:06 / 08:10（pinned）/ 08:14（auto） | 同上 | ❌ `Programming completed successfully` → **`Verify failed on page 0`** → `DONE did not go high`，`Elapsed time = 65 sec`（成功那次 6 sec） |

三次失败转录逐字节相同；独立只读 `verify -p 1 -spi` 亦报 `Verify failed on page 0`，故**内容确实与 bitstream 不一致**（不是 in-step 校验误报）。只读诊断结论：

- `readStatusRegister -p 1 -flash`：`Device Density Bits: 0011` → 按 XCN14003/AR59572 的对应关系为 **X-FAB ISF，1 Mbit**（非 UMC）；`Sector Protection enabled = 0`、全部 sector `NOT SECURED`/`NOT LOCKED DOWN` → **无写保护**。
- `blankCheck -p 1 -spi`：`Part is not blank`（Flash 里有内容）。
- `readStatusRegister -p 1 -fpga`（未加载 SPI core 时）：`CRC error = 1`、`CFG_RDY(INIT_B) = 0`、`DONEIN = 0` → 从 Flash 启动以 CRC 错误失败。
  > **HISTORICAL（已被后续成功写入取代）**：这条读数是在**三次失败写入之后、成功写入之前**采集的，反映的是当时的损坏内容；它**不代表**当前 ISF 状态，也不能作为当前持久启动的结论。
- 环境/补丁：`MYXILINX` 与 `ISE_XCN14003_patch` **均未设置**，ISE 安装内无任何 `*patch*` 文件，`impact` 为 `Release 14.7 - iMPACT P.20131013`，`spartan3a\data` 全部为 2013/10/13 基准文件 → **未安装 XCN14003 补丁**；因器件判定为 X-FAB，该补丁（针对 X-FAB→UMC 算法变更）在本例中按判定树不需要。

**已排除**：下载线选择方式（`-p auto` 同样失败，选项 A 实测）、bitstream 文件（与成功那次同一 SHA-256）、命令序列（转录前缀逐行相同）、Flash 写保护、工具判定层（工具如实报 FAIL）。

**下一步唯一允许的 ISF 测试**（已固化进工具）：`assignFile` + **`program -p 1 -e -v`**，并要求日志出现 `Erasing device...` 与 `Erasure completed successfully.` 后才采信编程/校验结果；任一步失败立即停止、绝不自动重试。只有 verify PASS 后才做断电启动测试，且断电启动结论单独记录。

**已执行并成功（2026-09-15 08:32，run `program-20260915-083244-bf54acda`）**：加上显式 `-e` 后，同一份 `design.bit`、同一条下载线、同一个位置，一次写入通过：

```
'1': Erasing device...  done.
'1': Erasure completed successfully.
'1': Programming Flash...done.
'1': Programming completed successfully.
'1': Verifying device...done.
'1': Verification completed successfully.
'1': Programmed successfully.
INFO:iMPACT - '1': Checking done pin....done.      ← 没有出现 "DONE did not go high"
Elapsed time =      7 sec.                          ← 失败时是 65 sec
```

`run.json`：`result = PASS`、`programmingCompleted = PASS`、`programmingVerified = VERIFIED`、`preflightState = COMPLETE`、`cableSerialSeen = 210241672559`（无 mismatch）、`programAttempts = 2`（**第 1 次是只读 preflight 冷启动失败、未写入**，第 2 次完成唯一一次写入）。

**根因（工程结论，措辞已冻结）**：旧 ISF 流程在**重写非空 ISF 时没有显式执行擦除**。加入 `-e` 后，iMPACT 明确完成 `Erase → Program → Verify`，原先稳定出现的 page 0 verify failure 消失。因此工程上将「缺少显式 erase」认定为本次 ISF 重写失败的根因。
（**不要**写成「`program -v` 的隐式 erase 没有擦净」——没有直接证据证明旧流程真的执行过 erase。同一镜像、同一下载线、同一工具，唯一差别是加了 `-e`。）

**结论 B（断电重启持久启动）：仍未测试**，必须在上面 verify PASS 之后再单独进行，且不得从 programming PASS 推导。

### 第六轮：时钟改为 12 MHz + 引脚约束确认 + 实现/bitstream（2026-09-14）

**这是本工程第一次产生真实引脚约束与 bitstream**，但**仍然没有烧录、没有上板**。

**1. 时钟由 2 MHz 改为 12 MHz。** 用户确认板上 P57 接的是 **12 MHz 有源晶振**（此前记录的 2 MHz 作废）。`` `SYS_CLK_HZ `` 由 `2000000` 改为 **`12000000`**；`frequency_table.md` 第 2/4/5 节与自检值全部按 12 MHz 重算，新增 `tone_generator_12m` 用例（`TB_SYS_CLK_HZ=12000000`）在真实 12 MHz 下实测半周期：

| 音符 | 频率表 N | 12 MHz 实测 N | f_out (Hz) | 误差 |
|---|---|---|---|---|
| C4 | 22936 | 22936 | 261.5975 | −0.0086% |
| D4 | 20429 | 20429 | 293.7001 | +0.0103% |
| E4 | 18204 | 18204 | 329.5979 | −0.0097% |
| F4 | 17182 | 17182 | 349.2027 | −0.0078% |
| G4 | 15306 | 15306 | 392.0031 | +0.0034% |
| A4 | 13636 | 13636 | 440.0117 | +0.0027% |
| B4 | 12148 | 12148 | 493.9085 | +0.0058% |

与「按实数频率取整」的预期值（22934/20431/18202/17181/15307/13636/12149）相比有 0~2 个计数差异（只有 A4 完全相同），原因仍是 RTL 用 0.1 Hz 整数频率表配合「先加半个除数再截断」；两种取值误差都 ≤ 0.02%，表格以 **RTL 实际算法**为准。

滤波与位宽：12 MHz × 10 ms → `STABLE_CYCLES = (12000000/1000)*10 = 120000`（17 位够），`FP_FILTER_CNT_WIDTH = 24` 裕量很大；24 位下 `KEY_STABLE_MS` 上限约 **1398 ms**。UCF 的 `PERIOD` 由 500 ns 改为 **83.33 ns**（不再只是注释）。

**2. 引脚约束按用户确认填写，`constraintsReviewed` 置 `true`。** 用户确认：P57 为 12 MHz 有源晶振、可用 I/O 为 P1–P40、I/O 电压 3.3 V。因此按第 7 节表格写入 `constraints/finger_piano.ucf`（clk P57、rst_n P3、key_in P4/P5/P6/P7/P8/P10/P11、audio_out P12、key_debug P13/P15/P16/P18/P19/P20/P21、note_debug P24/P25/P27，全部 `LVCMOS33`，另有 `TNM_NET "clk_group"` + `TS_clk = PERIOD 83.33 ns`），并把 `project.json` 的 `constraintsReviewed` 由 `false` 改为 **`true`**——这是**用户确认驱动**的修改，不是为让工具产出 bitstream 而绕过门禁。刻意避开 P1=TMS / P2=TDI（保留给 JTAG）、P9/P17/P26/P34=GND、P14/P23=VCCO_3、P40/VCCO_2、P22=VCCINT、P36=VCCAUX、P33/P35=IPAD（仅输入）。

**3. 本轮真实结果（远端 fpga-vm / ISE 14.7）**

- `check -Stage synth` → PASS；`build -Stage synth` → run `20260914-204359-76ed80cc`，`synthesis.srp` **0 errors / 0 warnings / 0 latches**，232 个触发器、20 个 I/O。
- 六个仿真用例全部 PASS（verify 内 20:45 一轮与 20:44 单独一轮均 PASS）：
  `note_encoder`、`tone_generator`、**`tone_generator_12m`**、`top_default`、`top_active_low`、`top_filter_bypass`。
- `verify -Project finger_piano` → **Overall PASS**，`verify-20260914-204501-bde0e8a6`，Stage **`IMPLEMENT_ALLOWED`**：静态检查 PASS（UCF 的 LOC/TIMESPEC 在已评审工程中只报 INFO）、综合 0/0、六个仿真 PASS、implement 门禁 `implement gate open (UCF present and constraintsReviewed=true)` PASS。
- `check -Stage implement` → PASS（门禁放开后不再是按设计的阻断）。
- `build -Stage bitstream` → run **`20260914-204555-24cabc5e`**，`run.status=COMPLETE`，MAP/PAR 均 `0 error / 0 warning`，bitgen `DRC detected 0 errors and 0 warnings`，产物 `results/design.bit`（54 738 字节）。
- **时序（本人已阅读 `timing.twr`，不是工具自动结论）**：`TS_clk = PERIOD TIMEGRP "clk_group" 83.33 ns` → **0 timing errors**，最差 setup/hold slack **70.697 ns**，脉冲宽度 slack 80.126 ns，报告结尾为 `All constraints were met.` / `Timing errors: 0  Score: 0`。**但**：UCF 未写任何 `OFFSET IN/OUT`（板级按键建立/保持与音频输出延迟没有板卡数据），所以 `Unconstrained OFFSET IN BEFORE` / `OFFSET OUT AFTER` / `Unconstrained path analysis` 三段是“无约束可查”，只能说明**没有违反任何已写约束**，不能解释为板级 I/O 时序已认证。工具 `summary.txt` 仍按规则输出 `Timing: NEEDS_REVIEW`。
- 器件与器件名核对：`routed.pad` 中 `P57 clk IBUF IO_L09P_2/GCLK0 INPUT LVCMOS33`、`P3 rst_n`、`P4/P5/P6/P7/P8/P10/P11` 七个按键、`P12 audio_out`、`P13/P15/P16/P18/P19/P20/P21` 与 `P24/P25/P27` 全部 `LOCATED`；P1/P2 未被占用（仍是 TMS/TDI）。
- **`program` 仍然只跑了只读 preflight，没有写入硬件**：20:48 与 20:50 两次 `program -Mode Jtag` 都因 `CABLE_NOT_FOUND` 在 preflight 就停下（`program-20260914-204807-6fd72080`，输出 `nothing was written`），此时连写脚本都不会生成；同一时段 `probe-20260914-204823-414a4508` / `probe-20260914-205006-a9df9206` 也都是 `CABLE_NOT_FOUND`。原因仍是 fpga-vm 的 USB 透传不稳定（当天 20:26/20:29 曾 `probe` PASS），属环境问题，与工具/板卡无关。`design.bit` 已具备、`constraintsReviewed=true`，随时可以烧录，但**是否真正写入由用户决定**。
- **顺带修掉一个真实缺口**：本工程的 `design.bit` 头部是 bitgen 的紧凑格式（`b` 字段 = `3s50antqg144`），旧解析器只认 `Target Device:` 文本头，因此 preflight 一直显示 `NOT_PARSED`，等于少了一层「bitstream 器件 ≠ JTAG 器件」的交叉检查。现已支持该格式并做严格比较（只允许 `xc` 前缀等价，不发明 package 等价规则，速度等级缺失就如实写 `not in header`）；现在输出 `bitstream target : xc3s50antqg144 (header: BITGEN) match: YES`。已补单元测试（真实头形状、跨器件必须 NO、字段缺失必须 UNDETERMINED）。

**4. 本轮仍未做**：真正烧录、上板按键实测、示波器/频率计实测音高。`program` 的状态模型依旧以 `userDesignFunctional = NOT_TESTED` 收尾，工具任何路径都不会打印 `BOARD PASS`。

### 第五轮：时钟确认为 2 MHz + JTAG/ISF 烧录工具（2026-09-14）（**该频率判断已被第六轮取代：实际为 12 MHz**）

**时钟**：外部有源晶振已确认为 **2 MHz**。`src/finger_piano_cfg.vh` 的 `` `SYS_CLK_HZ `` 由占位的 50 000 000 改为 **2 000 000**；`frequency_table.md` 用 RTL 等价脚本（`[int64]` + `[math]::Floor`）重算，并新增 `tone_generator_2m` 用例在真实 2 MHz 下**实测**半周期：

| 音符 | 频率表 N | 2 MHz 实测 N | f_out (Hz) | 误差 |
|---|---|---|---|---|
| C4 | 3823 | 3823 | 261.5747 | −0.0173% |
| D4 | 3405 | 3405 | 293.6858 | +0.0054% |
| E4 | 3034 | 3034 | 329.5979 | −0.0097% |
| F4 | 2864 | 2864 | 349.1620 | −0.0195% |
| G4 | 2551 | 2551 | 392.0031 | +0.0034% |
| A4 | 2273 | 2273 | 439.9472 | −0.0120% |
| B4 | 2025 | 2025 | 493.8272 | −0.0107% |

表与 RTL **逐位一致**（相位重启用例实测 D4 = 3405）。与“按实数频率取整”的预期值相比：D4/E4/G4/A4/B4 一致；**C4 得到 3823（预期 3822）、F4 得到 2864（预期 2863）**，各差 1 个计数——原因是 RTL 使用 0.1 Hz 整数频率表（261.6 / 349.2 Hz）配合「先加半个除数再截断」，而实数取整是另一条路径。两种取值的误差都 ≤ 0.02%，远优于 1%；表格以 **RTL 实际算法**为准（见 `frequency_table.md` 的说明）。若要与实数取整逐位一致，需要把 `tone_generator.v` 的频率常量精度从 0.1 Hz 改为 0.01 Hz——属 RTL 修改，本轮未做。

滤波与位宽：2 MHz × 10 ms → `STABLE_CYCLES = 20000`（15 位就够），`FP_FILTER_CNT_WIDTH = 24` 保持不变、**无需缩位**；24 位下 `KEY_STABLE_MS` 上限约 8388 ms。UCF 时钟约束目标为 **`PERIOD = 500 ns`**，但仍只写在注释里——clk 的 `LOC` 未确认前不得填写。

**烧录工具**：新增只读 `probe` 与 `program -Mode Jtag|Isf`，其中 iMPACT batch 命令全部来自对真实 ISE 14.7 的实测（命令表、顺序要求、退出码不可靠、IDCODE 0x02610093 等，详见根 README 的「JTAG 探测与烧录」）。`constraintsReviewed` 仍为 `false`，没有为了让工具产生 bitstream 而让 ISE 自动分配未知 I/O。

**本轮验证（2 MHz 配置，6 个仿真用例）**

- 综合：`20260914-164037-9a8f4f9d`（verify 内）与 `20260914-163756-0fc737e0`（单独 build）→ 0 errors / 0 warnings / 0 latches，231 个触发器、20 个 I/O，`design.ngc` 已生成。
- 仿真全部 PASS：`note_encoder`、`tone_generator`、**`tone_generator_2m`**（`sim-20260914-164029-dfcb69a7`，实测半周期与频率表逐位一致）、`top_default`、`top_active_low`、`top_filter_bypass`。
- `verify` → **Overall PASS**（`verify-20260914-164037-b82da68b`，Stage `PRE_BOARD`）：静态检查 PASS、综合 0 errors/0 warnings、warnings 策略 blocking、implement 门禁 EXPECTED BLOCK = PASS。
- 烧录相关（`probe` 全程只读）：
  - 16:19 下载线在 VM 内可见（Digilent JTAG-HS2, SN 210241672559），但 `identify` 报链未识别；
  - 16:27 / 16:28 下载线从 VM 消失（`no JTAG device was found`）→ 工具如实报 `CABLE_NOT_FOUND` + `JTAG chain NOT_RUN` + `Result FAIL`；
  - 板卡供电处理后（20:26 / 20:29）**`probe` PASS**：`Cable PASS`、`JTAG chain PASS`、Position 1 = **xc3s50an**、**IDCODE `0x02610093`**（与安装自带 `xc3s50an_tq144_1532.bsd` 的期望值完全一致）、`Match YES`、`Result PASS`（run `probe-20260914-202618-d161523e` 与 `probe-20260914-202941-bbbebd63`）；
  - 为此给工具补了 `readIdcode -p 1`：本 ISE 版本的 `identify` 只打印器件名，IDCODE 由该命令以 `'1': IDCODE is '02610093' (in hex)` 形式给出；
  - 已知环境问题：fpga-vm 的 USB 透传不稳定，连续运行时常报 `no JTAG device was found`，重试即可；与工具、板卡无关；
  - **本轮没有执行任何 program 写入**（`constraintsReviewed` 仍为 `false`，且工程尚无 bitstream）。

### 第四轮：report 缺文件判定收紧 + 综合 warning 策略（2026-09-14）

本轮**未改 RTL/Testbench**，只收紧工具判定并补测试与措辞：

1. **`report` 不再只看 `results/` 是否存在**。现在逐项判定 `results/`、`synthesis.srp`、`synth.exitcode`、`run.status`、`design.ngc`（implement/bitstream 另加各阶段退码与网表/时序文件）。工具流程 `COMPLETE` 但关键产物缺失（或 `results/`、`run.status` 缺失）→ 明确报 `NOT_AVAILABLE`、列出 `missingFiles` 并**非零退出**；工具流程本身 `FAILED` → 仍为 `AVAILABLE` + `synthesis FAIL`（缺失文件是失败证据），不会误判成数据缺失。
2. **新增可选策略 `verification.failOnSynthesisWarnings`**（本工程设为 `true`）：为 `true` 时 XST warning 数 > 0 会让 verify 的 synthesis 与 overall 判 FAIL；不配置时保持旧行为（只报告 warning）。`report` 始终是纯事实输出，不受该策略影响。
3. 文档措辞修正：实施计划中的「共四组用例」改为「3 个 Testbench，共 5 组仿真运行」；根 README 中的「fuse 阶段固定上限 300 s」改为「fuse 阶段超时为 `max(300, timeoutSeconds)`，即至少 300 s」。
4. 新增三条自测：results 存在但 `synthesis.srp` 缺失 → `NOT_AVAILABLE`；`failOnSynthesisWarnings=true` 且 warnings>0 → verify FAIL；未配置该项 → 旧行为（warnings 不影响结论）。`tools/test-tools.ps1` 连续 3 次全绿。

**本轮真实验收**

- `verify -Project finger_piano` → **Overall PASS**（verify id `verify-20260914-160313-e852db47`，Stage `PRE_BOARD`）：综合 run `20260914-160313-3e018090` 为 0 errors / **0 warnings**，日志显示 `warnings policy: blocking (failOnSynthesisWarnings=true)`，5 个仿真 PASS，implement 门禁 EXPECTED BLOCK=PASS。
- `report -Project finger_piano -Latest` → run `20260914-160313-3e018090`：产物五项全 True、`missing for stage: (none)`、`data status: AVAILABLE`、registers 231 / IOs 20 / `result PASS`、timing `NOT_RUN`。
- 用历史失败 run `20260914-144156-edb3def6`（宏漏反引号那次）复核实测：`design.ngc` 缺失被列为 `missing for stage: design.ngc`，但 `data status` 仍为 `AVAILABLE`、`result FAIL`（XST exit 6 / errors 13）——与 `NOT_AVAILABLE` 的区分符合预期。

### 第三轮：工具链验收入口 sim / verify / report（2026-09-14）

本轮**没有改动任何 RTL 或 Testbench**，只把此前人工验证过的 `fuse + tclbatch` 流程固化成工具入口（`sim`/`verify`/`report`，`board-check` 预留），并把本工程的五个仿真用例写进 `project.json`。

**工具侧要点**（详见根 `README.md` 的「仿真与验收」与 `AGENTS.md`）：

- `sim` 固化了的 ISim 陷阱：必须先 `call settings32.bat`、必须用 `-tclbatch run_all.tcl`、`--generic_top` 只属于 fuse、退出码 0 不算 PASS（必须有 `passPattern`，命中 `failPattern` 或无任何模式都判 FAIL）、每次运行前清旧 exe 与旧退码/状态文件、每轮独立目录。
- 包装脚本刻意命名为 `sim_fuse.cmd` / `sim_run.cmd`：CMD 解析裸命令名先搜当前目录，若叫 `fuse.cmd` 会遮蔽 `settings32.bat` 加到 PATH 的 `fuse.exe` 并递归调用自己（本轮真实踩到，表现为 exit 255、退码文件全缺失）。
- `verify` 用 `project.json` 的 `verification.expectImplementationBlocked` 判断 implement 门禁是否为「预期阻断」，不写工程名特例；本工程 `constraintsReviewed=false`，因此被阻断记 PASS。
- `report` 只读已有 artifacts：综合段解析工具流程、XST 退出码、ERROR/WARNING、latch、multi-source、寄存器/IO、`design.ngc`；时序段在无 `timing.twr` 时为 `NOT_RUN`，有报告时为 `NEEDS_REVIEW`，**永不自动给 Timing PASS**。

**真实验收结果（远端 fpga-vm / ISE 14.7）**

五个用例逐个经 `sim -Test <名称>` 运行，全部 PASS（fuse 退出码 0、仿真退出码 0、`run.status=COMPLETE`、命中 passPattern）：

| 用例 | 仿真 run id | 结果 |
|---|---|---|
| `note_encoder` | `sim-20260914-154659-d1e02767` | PASS |
| `tone_generator` | `sim-20260914-154705-464301be` | PASS |
| `top_default` | `sim-20260914-154712-ca95a53d` | PASS |
| `top_active_low`（`TB_KEY_ACTIVE_HIGH=0`） | `sim-20260914-154719-62344adc` | PASS |
| `top_filter_bypass`（`TB_KEY_FILTER_ENABLE=0`） | `sim-20260914-154726-0ecf43c3` | PASS |

`verify -Project finger_piano` 整体 **PASS**（verify id `verify-20260914-154737-5b713369`，Stage `PRE_BOARD`）：静态检查 PASS、综合 run `20260914-154737-9dbd12b2` 为 0 errors / 0 warnings / 0 latches（231 个触发器、20 个 I/O）、五个仿真 PASS、implement 门禁「预期阻断且确实阻断」PASS。`verification.json` 在 `artifacts/verify-20260914-154737-5b713369/`。

`report` 对三类 run 都验证过：构建 run `20260914-154737-9dbd12b2`（errors 0 / warnings 0 / registers 231 / IOs 20 / ngc true / timing NOT_RUN）、仿真 run `sim-20260914-154806-54659009`（PASS）、验证 run `verify-20260914-154737-5b713369`（overall PASS / stage PRE_BOARD）；`-Latest` 与 `-Json` 均正常。

工具自测 `tools/test-tools.ps1` 已扩展并连续三次通过，覆盖：模板保护、配置校验、缺文件、路径逃逸、UCF 门禁、结果取回、旧文件不复用、构建失败与中断、run 隔离、仿真名不存在/TB 缺失/非法 generic、fuse 失败、超时、退出码 0 但无 PASS、failPattern、generic 进入 fuse、report 缺文件与时序不得称 PASS、verify 两个方向的门禁、静态检查正负例、无 simulations 段的旧工程兼容。

### 第二轮修订：文档计算修正 + 滤波旁路验证（2026-09-14）

本轮**未改任何受保护的 RTL 设计**：复位同步、两级输入同步、滤波算法、优先级编码、频率公式、音符切换相位重启、单时钟域架构全部保持不变；改动只有文档、注释、testbench 的验证参数，以及两个模块的 `ASYNC_REG` 属性。

**1. `frequency_table.md` 的重算脚本原本会算错两个音。** 原脚本用 `[int](($sysClkHz * 10 + $dHz) / (2 * $dHz))`；PowerShell 的 `/` 产生浮点结果，而 `[int]` 是「就近舍入（round-half-to-even）」而不是截断。实测在 50 MHz 下会把 **F4 算成 71593（RTL 为 71592）**、**A4 算成 56819（RTL 为 56818）**。现改为 `[int64]` 分子分母 + `[math]::Floor`，并在文档中写明「`+ f_dHz` 是加半个除数，其后必须是向零截断的整数除法」。复算后七个 `N` 与 RTL 完全一致：`95566 / 85121 / 75850 / 71592 / 63776 / 56818 / 50618`；因此第 2 节表格的理论频率与误差**无需修改**（它们本来就是按 RTL 的值算出来的）。

**2. 滤波计数器容量公式漏了 `/1000`。** 原写法 `SYS_CLK_HZ * KEY_STABLE_MS < 2^W` 与 RTL 的 `STABLE_CYCLES = (SYS_CLK_HZ / 1000) * STABLE_MS` 不一致（ms 与 Hz 之间差一个千倍因子）。现统一为

```
(SYS_CLK_HZ / 1000) * KEY_STABLE_MS  <=  2^FP_FILTER_CNT_WIDTH
```

`src/finger_piano_cfg.vh` 与 `frequency_table.md` 已同步修正。核对结论：50 MHz / 10 ms → 500000 周期，19 位已足够（2^19 = 524288）；24 位为更高时钟与更长滤波时间留裕量；50 MHz、24 位下 `KEY_STABLE_MS` 上限约 335 ms（2^24 / 50000 = 335.54）。`key_filter.v` 的实际算法未改动。

**3. 新增 `KEY_FILTER_ENABLE = 0` 的旁路最小验证。** `tb_finger_piano_top.v` 增加顶层参数 `TB_KEY_FILTER_ENABLE` 并由它驱动 DUT：`=1` 保持原有完整套件，`=0` 改为最小用例（复位状态 → 按一个键 → 8 个周期内 `note_debug` 正确 → 松键 8 个周期内恢复 0 → 音频恢复静音）。两种宏取值因此都有真实运行证据，而不是只靠代码审阅。

**4. CDC 同步链增加 `(* ASYNC_REG = "TRUE" *)`**（评审建议项，已实测兼容）。`reset_sync.v` 的 `rst_meta`/`rst_sync_q`、`key_sync.v` 的 `meta`/`sync_out` 四个寄存器都带上该属性；XST 报告中出现四行 `Set user-defined property "ASYNC_REG = TRUE" for signal <...>`，且 **0 errors / 0 warnings**，说明属性生效而非被静默忽略。逻辑、端口、时序行为均未改变。

**5. 状态更新**：仓库已由用户手动改为 **public**；第一阶段软件工程（RTL + 综合 + 仿真 + 文档）完成。

**交付计数**：`projects/finger_piano/` 目录内 **14 个 tracked 文件**；加上第一阶段实施计划 `doc/archive/手指钢琴ISE工程实施计划.md`（已归档），**项目相关交付文件共 15 个**。

#### 综合（第二轮，最终 run）

- 构建编号：`20260914-151945-182649b0`，`xst` 退出码 0，工具流程 `COMPLETE`。
- `synthesis.srp`：**0 errors / 0 warnings / 0 infos**、`No errors in compilation`；无 latch 推断、无多驱动告警。
- 资源：231 个触发器（219 个来自 RTL，另有 7 个 `stable_q` 因扇出被复制 12 次）、20 个 I/O。产物 `artifacts/20260914-151945-182649b0/results/design.ngc`。
- 本轮中间 run `20260914-151840-67d75cf6`（只给 3 个寄存器加属性、未含 `sync_out`）同样 0 errors / 0 warnings；两个 run 均保留。

#### 仿真（第二轮，五组用例，输入与本次提交的源码一致）

| 用例 | DUT 参数覆盖 | fuse 退出码 | 运行退出码 | 结果 |
|---|---|---|---|---|
| `tb_note_encoder` | — | 0 | 0 | PASS（checks=15, errors=0） |
| `tb_tone_generator` | — | 0 | 0 | PASS（checks=11, errors=0） |
| `tb_finger_piano_top` | 默认（filter=1, 按下为高） | 0 | 0 | PASS（checks=129, errors=0, sim_time=4527866 ns） |
| `tb_finger_piano_top` | `TB_KEY_ACTIVE_HIGH=0` | 0 | 0 | PASS（checks=129, errors=0） |
| `tb_finger_piano_top` | `TB_KEY_FILTER_ENABLE=0` | 0 | 0 | PASS（checks=10, errors=0, sim_time=2236 ns） |

- **filter enabled（完整功能测试）**：窗口判据（999 周期仍静默 / 1008 周期已生效，7 个音逐一）、300 周期毛刺被拒、七音频率实测（最大误差 0.0387% < 1%）、小星星 14 音与 6 个重复音符的 `1→0→1` 释放，全部 PASS。
- **filter disabled（旁路最小测试）**：用 `--generic_top "TB_KEY_FILTER_ENABLE=0"` 重新 fuse 后 PASS，日志为 `bypass note 1 valid within 8 cycles (cycle 122)`、`bypass note 1 released within 8 cycles (cycle 124)`，证明旁路路径只剩两级同步延迟、没有 10 ms 稳定延迟；复位态与松键后 `audio_out` 均保持 0。
- 运行位置：远端 `C:\Users\PanGucheng\ise-builds\_sim\finger_piano\20260914-152007`；本机日志副本 `tools/.work/sim-finger-piano-20260914-152007/received/`（`tools/.work` 已被 `.gitignore` 排除）。

#### implement 预期失败（第二轮复核）

`check -Project finger_piano -Stage implement` 仍然按设计失败：`Implementation needs a UCF and constraintsReviewed=true after confirming clocks, pins and timing intent.`。`constraintsReviewed` 保持 `false`，UCF 未添加任何 `LOC`/`IOSTANDARD`/`TIMESPEC`，没有为了“测试 implement”而绕过该机制。

### 第一轮：第一阶段实现（2026-09-14）

**第一轮验证结果：**

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
- **七个音符频率**（1 MHz 仿真时钟下实测半周期计数，再与实数标称频率比较）：C4 1911 → 261.6431 Hz（+0.0088%）、D4 1702 → 293.7720 Hz（+0.0347%）、E4 1517 → 329.5979 Hz（−0.0097%）、F4 1432 → 349.1620 Hz（−0.0195%）、G4 1276 → 391.8495 Hz（−0.0358%）、A4 1136 → 440.1408 Hz（+0.0320%）、B4 1012 → 494.0711 Hz（+0.0387%）；最大误差 **0.0387% < 1%**。占位 50 MHz 时钟下的理论误差见 `frequency_table.md`（≤0.011%；现行 12 MHz 为 ≤0.0103%）。
- **小星星序列**：14 个音全部按 `note_debug` 逐一核对，且每个音之后都观察到 `note_debug` 回到 0；其中 **6 个重复音符**（1、5、6、4、3、2）确认经历了 `key_stable` 的 `1 -> 0 -> 1`，即确实是两次独立按键，而不是被数字滤波并成一次长按。
- **输入极性**：`KEY_ACTIVE_HIGH` 为 1 与 0 两种配置下检查数与结论完全一致（均 129 checks / 0 errors）。
- 运行位置：远端 `C:\Users\PanGucheng\ise-builds\_sim\finger_piano\sim-20260914-144318`；本机日志副本 `tools/.work/sim-finger-piano-20260914-144318/received/`（`tools/.work` 已被 `.gitignore` 排除，不进入版本库）。

#### 仍待用户提供（这些是后续步骤的阻塞项）

- **实际有源晶振频率** → 修改 `src/finger_piano_cfg.vh` 的 `` `SYS_CLK_HZ ``，按 `frequency_table.md` 第 4 节重算表格，并重新综合。
- **芯片丝印速度等级** → 确认 `-4` 或改为 `-5`（改 `project.json` 一处字段）。
- **TQ144 最小系统板原理图引脚** → 填写 `constraints/finger_piano.ucf` 的 6 组 TODO 与全部 debug 端口，然后才可把 `constraintsReviewed` 置 `true` 并做 implement / bitstream。

> 注：`artifacts/` 目录被 `.gitignore` 排除，构建产物不进入版本库；需要留存时请单独归档。
