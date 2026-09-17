# finger_piano_od_test — P31/P32/P110 推挽方波板级诊断工程

独立、最小、低风险的板级诊断 bitstream:用 P57 的 12 MHz 产生**同相位、同频率**
的 **1 kHz / 50% 占空比推挽方波**,同时从 **P31、P32、P110** 三个脚输出,便于
用示波器/频率计同时核对三个脚的输出频率、相位与推挽驱动能力(高电平由 FPGA
自己驱动,不再依赖外部上拉)。

- 器件:`xc3s50an-4-tqg144`
- 时钟:**P57 = 12 MHz 有源晶振(唯一时钟域)**
- 复位:**P3 `rst_n`(低有效)**
- 输出:**P31 `p31_test`**、**P32 `p32_test`**、**P110 `p110_test`**,全部
  `LVCMOS33`,三个脚**同相位**
- **UCF 只约束 5 个引脚**(P57/P3/P31/P32/P110),**不写 PULLUP/PULLDOWN**,不写 OFFSET
- 不使用 `KEEP`/`DONT_TOUCH`

## 行为

```verilog
localparam integer HALF = SYS_CLK_HZ / (2 * TONE_HZ);   // 12 MHz / 1 kHz -> 6000 clk
// 每 HALF 个 clk 翻转一次 -> 50% 占空比
assign p31_test  = wave;
assign p32_test  = wave;
assign p110_test = wave;
```

全工程只有 `posedge clk` 一个时钟域、只有 `negedge rst_n` 一个异步复位;
分频用 clock-enable 语义的计数器,不产生任何派生时钟(没有第二时钟域)。

## 与其它工程的关系

本工程**完全独立**:不修改正式 `finger_piano`、不改 P9 `finger_piano_periph_test`、
不改正式 UCF,也不新增/修改任何 warning allowlist。没有复用文件。

```text
projects/finger_piano_od_test/
  project.json                      top=od_test_top
  src/od_test_cfg.vh                ★ 配置真值源:SYS_CLK_HZ / TONE_HZ
  src/od_test_top.v                 ★ 顶层(rst_n + 1 kHz 计数器 + 三个推挽输出)
  constraints/od_test.ucf           P57/P3/P31/P32/P110,LVCMOS33,无 PULLUP/PULLDOWN
  sim/tb_od_test_top.v              testbench(快速用例 + 1 kHz 用例)
  README.md
```

## 硬件前提

```text
[ ] P57 接 12 MHz 有源晶振;P3 接低有效复位(外部上拉/RC)
[ ] P31/P32/P110 引出到示波器/频率计(推挽输出,不需要外部上拉)
[ ] VCCO(Bank 0/2/3)= 3.3 V
[ ] 不依赖 FPGA 内部 PULLUP/PULLDOWN(本设计/本 UCF 都没有)
```

## 仿真判定

两个用例,判据是 `TB_OD_TEST_TOP: PASS/FAIL`。TB 用
`always @(posedge clk) clk_edges = clk_edges + 1` 累计 clk 沿,在输出跳变处
记录沿号,相邻跳变之差就是一个半周期的真实拍数;并逐 clk 检查三个脚同值、
只允许 0/1。

实测:

```text
od_test_fast    (TB_TONE_HZ=12000): high=500 clk   low=500 clk   -> 12000.000 Hz, 0 violations
od_test_tone_1k (TB_TONE_HZ=1000) : high=6000 clk  low=6000 clk  ->  1000.000 Hz, period 1000000 ns
TB_OD_TEST_TOP: PASS
```

- 快速用例 `sim-20260917-163517-6103b8d7`
- 1 kHz 用例 `sim-20260917-163544-802d4103`(verify 内为 `sim-20260917-163544-802d4103`)
- 两个用例都验证:复位期间三个输出为 0;三脚恒同值(0 次相位不一致);
  0 次非法电平(不是 0/1);高/低半周期相等=50%;两种电平都出现过。

## 软件验证结果(2026-09-17)

```text
verify-20260917-163533-b5de1bae   Overall PASS
  synthesis  0 errors / 0 warnings / 0 latches(无 allowlist,直接 0 warning)
  simulation od_test_fast PASS + od_test_tone_1k PASS
  gate       IMPLEMENT_ALLOWED
```

实现/bitstream run `20260917-163556-c0d5de09`(六阶段退出码全 0):

| 项 | 值 |
|---|---|
| MAP / PAR | **0 errors / 0 warnings**;`All signals are completely routed`;`Timing Score: 0` |
| bonded IOBs | **5**:`clk` P57 INPUT/IBUF、`rst_n` P3 INPUT/IBUF、`p31_test`/`p32_test`/`p110_test` **OUTPUT** |
| LOCATED | **5/5 全部 LOCATED**,`design.pcf` 只有这 5 条 `LOCATE`,无自动分配 I/O |
| IOSTANDARD | 五个脚全部 `LVCMOS33`(Bank 0/2/3) |
| Termination | 三个输出 `NONE**`(无内部上/下拉) |
| timing.twr(人工阅读) | `TS_clk = PERIOD TIMEGRP "clk_group" 83.33 ns` → **0 timing errors**、`All constraints were met.`、最小周期 6.299 ns;UCF 无 OFFSET,板级 I/O 时序未认证 |
| bitstream | `design.bit` **54 738 字节**,DRC 0 errors / 0 warnings |
| SHA256 | `c7f5684d349939c79b69f78c9f9f40433e2abc0c8b4e6aa2998a119017f647ea` |

bitstream 路径:

```text
projects/finger_piano_od_test/artifacts/20260917-163556-c0d5de09/results/design.bit
```

## 状态

```text
OD DIAGNOSTIC BITSTREAM = READY(推挽 1 kHz,P31/P32/P110)
BOARD TEST              = READY_FOR_BOARD_TEST(等待用户实测)
PROGRAM                 = NOT RUN(本版尚未烧录)
userDesignFunctional    = NOT_TESTED
```

**本版未执行 `program`。** 板上的 fabric 目前仍是上一版 1 秒互补 open-drain
设计(`program-20260917-162532-7fe23477`),要观察本版推挽 1 kHz 需要重新授权烧录。
即使烧录成功也只是配置证据,**不构成板级功能 PASS**。

## 板测步骤(建议)

1. 用示波器/频率计同时接 P31、P32、P110;
2. 应看到三路 1 kHz、约 50% 占空比、**彼此同相**、幅度 0 → 3.3 V 的方波;
3. 若某一路反相或频率不符,说明该脚 LOC/IOSTANDARD/焊接有问题;
4. 本工程不测 ADS1115 通信,也不涉及 LM386 / 扬声器。

## 历史(仅为追溯,不作当前事实)

- 上一版:1 秒慢速互补 open-drain(P31/P32 交替 Z/LOW),见 commit `15e4e25`、
  `program-20260917-162532-7fe23477`;
- 更早一版:P31/P32 各 1 kHz / 2 kHz open-drain 方波,见 commit `f4ba528`;
- 早期"常量 Z / 静态电平"尝试已被否定:常量 Z 会被 XST 裁成 UNUSED 脚,
  且 bitgen 默认给未使用脚加内部 Pulldown(不是真正高阻),因此不再采用。
