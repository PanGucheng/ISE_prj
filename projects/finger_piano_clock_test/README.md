# finger_piano_clock_test — P7 FPGA 启动与时钟分频板级诊断工程

独立的**板级诊断**工程，用于在接入 ADS1115 / MCP4725 / LM386 之前，先用
同一个 12 MHz 系统时钟独立证明 FPGA、时钟路径、分频器与外部复位工作正常。

计划入口：[`../../doc/P7FPGA启动与时钟分频板级验证.md`](../../doc/P7FPGA启动与时钟分频板级验证.md)。

> **本工程不是正式 `finger_piano`。** 正式 Stage-2 顶层 / UCF /
> `synthesisWarningAllowlist` 一律不动；`xc3s50an_smoke` 也不改造。

## 1. 端口与引脚（全部 LVCMOS33，VCCO 3.3 V）

| 端口 | 方向 | LOC | 说明 |
|---|---|---|---|
| `clk` | in | **P57** | 12 MHz 有源晶振，唯一系统时钟 |
| `rst_n` | in | **P3** | 低有效外部复位 |
| `ref_2mhz` | out | **P110** | ÷6 → 2,000,000 Hz（每 3 clk 翻转，周期 6 clk） |
| `ref_100khz` | out | **P111** | ÷120 → 100,000 Hz（每 60 clk 翻转，周期 120 clk） |
| `ref_1khz` | out | **P113** | ÷12000 → 1,000 Hz（每 6000 clk 翻转，周期 12000 clk） |

五个引脚都是 P6B 已确认的引脚，不引入任何新 LOC。三个输出是普通 GPIO，
**绝不**被当作时钟；全工程只有 `clk` 一个时钟域。

## 2. 结构

```
clk (P57, 12 MHz)
  ├─ ÷6     → ref_2mhz   (P110)   counter width 2
  ├─ ÷120   → ref_100khz (P111)   counter width 6
  └─ ÷12000 → ref_1khz   (P113)   counter width 13
rst_n (P3) 低有效:全部 counter 与输出归 0,释放后从完整半周期重来
```

`fout = fclk / (2*N)`，N 为“每 N 个 clk 翻转”。在输入恰为 12 MHz 时
三个输出无任何整数取整误差。

## 3. 文件

```
projects/finger_piano_clock_test/
  project.json
  src/clock_test_top.v
  constraints/clock_test.ucf
  sim/tb_clock_test_top.v
  README.md
```

## 4. 仿真

TB 用与板上一致的 12 MHz 节拍，按 clk 拍数验证（与 TB 频率无关）：

- 复位：三个输出与全部 counter == 0；
- 相邻翻转间隔：2 MHz = 3、100 kHz = 60、1 kHz = 6000 clk；
- 完整周期（上升沿到上升沿）：6 / 120 / 12000 clk；
- 运行中再次拉低复位：输出回 0；释放后重新从完整半周期开始。

```powershell
pwsh -File .\ise.ps1 sim    -Project finger_piano_clock_test
pwsh -File .\ise.ps1 verify -Project finger_piano_clock_test
```

判据是日志出现 `TB_CLOCK_TEST_TOP: PASS`（退出码 0 不算通过）。

## 5. 综合 / 实现 / bitstream

```powershell
pwsh -File .\ise.ps1 check -Project finger_piano_clock_test -Stage implement
pwsh -File .\ise.ps1 build -Project finger_piano_clock_test -Stage implement
pwsh -File .\ise.ps1 build -Project finger_piano_clock_test -Stage bitstream
```

本工程**不使用** `finger_piano` 的 166-warning allowlist，要求综合原始
`0 errors / 0 warnings / 0 latches`。实现后人工阅读 `timing.twr`，确认
`TS_clk = PERIOD 83.33 ns` 满足。

## 6. 软件准备结果（2026-09-16）

```text
verify      verify-20260916-161314-e4afa190   Overall PASS
            synthesis 0 errors / 0 warnings / 0 latches（未使用任何 allowlist）
            simulation clock_test_top  PASS
            implement gate open

implement   20260916-161330-82a13ebe
            MAP 0 errors / 0 warnings；PAR 0 errors / 0 warnings；
            All signals are completely routed；Timing Score: 0
            routed_pad: P57 clk / P3 rst_n / P110 ref_2mhz /
            P111 ref_100khz / P113 ref_1khz 全部 LOCATED，5 bonded IOBs，
            无自动分配 I/O
            timing.twr（人工阅读）: TS_clk = PERIOD clk_group 83.33 ns，
            0 timing errors，Minimum period 7.670 ns，最差 slack 75.660 ns，
            All constraints were met.

bitstream   20260916-161405-0050b850
            path   : results/design.bit
            size   : 54738 bytes
            target : xc3s50an tqg144（bitgen DRC 0 errors / 0 warnings）
            SHA256 : 9E1DBC034C1B05CD2BF1ED623FCB826783FD6081CF166DEACA8C78DB47DC40D4
```

### 6.1 Stage-2 恢复 bitstream（recovery artifact）

```text
finger_piano  20260916-161434-96853257
              size   : 54738 bytes
              SHA256 : 65A18EE6F191CC72DF9B9793B2308423AF530F3E8CCC37DFF55A8B07BD3518BA
              source : finger_piano_stage2_top @ commit bd85e3a（或之后仅文档提交）
```

DO NOT PROGRAM（除非用户明确授权）。这只是把正式 Stage-2 镜像也构建好，
方便诊断 ISF 测试后恢复。

## 7. 状态

```text
P7 SOFTWARE PREPARATION   = COMPLETE
HARDWARE TEST             = WAITING USER（READY_FOR_BOARD_TEST）
BOARD MEASUREMENT         = TODO（由用户实测填写，Agent 不得编造）
```

生成 bitstream 后本工程停在 `READY_FOR_BOARD_TEST`。**不执行任何 JTAG /
ISF `program`**，除非用户明确授权并带 `-ConfirmHardwareWrite`。

## 8. 板测记录（用户实测后填写）

| 项目 | 理论 | 实测 | 误差 |
|---|---|---|---|
| P110 | 2,000,000 Hz | TODO | TODO |
| P111 | 100,000 Hz | TODO | TODO |
| P113 | 1,000 Hz | TODO | TODO |
| 由 P110 反推输入时钟 | 12,000,000 Hz | TODO | TODO |
| 由 P111 反推输入时钟 | 12,000,000 Hz | TODO | TODO |
| 由 P113 反推输入时钟 | 12,000,000 Hz | TODO | TODO |

```text
f_2MHz / f_100kHz = 20  (理论)
f_100kHz / f_1kHz = 100 (理论)

JTAG CONFIG               TODO
RESET                     TODO
ISF PROGRAM/VERIFY        TODO
POWER-CYCLE #1..#5        TODO
```

任何 TODO 都不得由 Agent 自行填写。
