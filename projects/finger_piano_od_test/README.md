# finger_piano_od_test — P31/P32 开漏(open-drain)IO 板级诊断工程

独立、最小、低风险的 open-drain 诊断 bitstream:让 P31 输出约 **1 kHz**、
P32 输出约 **2 kHz** 的方波,但**只允许拉低**,高电平完全来自板级外部上拉。
用于验证 P31/P32 的开漏能力、外部上拉与信号完整性,并作为 ADS1115 I2C
排故的对照实验。

- 器件:`xc3s50an-4-tqg144`
- 时钟:**P57 = 12 MHz 有源晶振(唯一系统时钟,唯一时钟域)**
- 输出:`p31_test` = **P31**、`p32_test` = **P32**,全部 `LVCMOS33`
- **无复位引脚**(本工程 UCF 只允许 P57/P31/P32);计数器使用上电初值,
  配置完成(GSR)后两路先处于释放态再开始分频
- **UCF 只约束 3 个引脚**(P57/P31/P32),**不写 PULLUP**,不写 OFFSET

## 与其它工程的关系

本工程**完全独立**:不修改正式 `finger_piano`、不改 P9 `finger_piano_periph_test`、
不改正式 UCF,也不新增/修改任何 warning allowlist。没有复用文件,因此不存在
需要同步的副本。

```text
projects/finger_piano_od_test/
  project.json                      top=od_test_top
  src/od_test_cfg.vh                ★ 配置真值源:SYS_CLK_HZ / P31_HZ / P32_HZ
  src/od_test_top.v                 ★ 顶层(两个开漏分频器)
  constraints/od_test.ucf           P57/P31/P32 三个 LOC,LVCMOS33,无 PULLUP
  sim/tb_od_test_top.v              testbench(6 项自动判定)
  README.md
```

## 硬件前提(板测前必须满足)

```text
[ ] P31/P32 由外部电阻上拉到 3.3 V(例如 4.7 kΩ 到 3.3 V)
[ ] ADS1115 完全断开(不与 P31/P32 抢总线)
[ ] P57 接 12 MHz 有源晶振,VCCO(Bank2/3)= 3.3 V
[ ] 不依赖 FPGA 内部 PULLUP(本设计/本 UCF 都没有)
```

## 输出语义

```verilog
assign p31_test = low31 ? 1'b0 : 1'bz;   // 只拉低,释放为高阻
assign p32_test = low32 ? 1'b0 : 1'bz;   // 绝不推挽驱动 1
```

`Fout = SYS_CLK_HZ / (2 * HALF)`;12 MHz 下 `HALF31 = 6000`、`HALF32 = 3000`,
即 P31 半周期 500 µs(1 kHz)、P32 半周期 250 µs(2 kHz),占空比各 50%。
全工程只有 `posedge clk`,没有第二时钟域,没有门控时钟。

## 仿真判定(6 项,`TB_OD_TEST_TOP: PASS/FAIL`)

1. 上电后两路都是 Z(释放),不主动驱动;
2. P31 拉低 / 释放半周期各约 500 µs → 约 1 kHz(±2%);
3. P32 拉低 / 释放半周期各约 250 µs → 约 2 kHz(±2%);
4. 占空比约 50%(±5 个百分点);
5. P32 周期是 P31 的一半(±2%);
6. **任何时刻 line 只能是 0 或 Z**——TB 对原始引脚线**逐 clk** 采样,
   出现 1(或 x)即记违规;只有 0/Z 才通过。TB 另用
   `bus = (line === 1'bz) ? 1'b1 : line` 模拟外部上拉后的板级电压来测频,
   严格性检查仍基于原始 `line`。

实测(`sim-20260917-160148-1ca342a7`):

```text
p31 low=500004 ns high=500004 ns period=1000008 ns -> 999.992 Hz  duty=0.500000
p32 low=250002 ns high=250002 ns period=500004 ns  -> 1999.984 Hz duty=0.500000
p31 samples low=12000 z=14999 violations=0
p32 samples low=12000 z=14999 violations=0
TB_OD_TEST_TOP: PASS
```

## 软件验证结果(2026-09-17)

```text
verify-20260917-160206-ec6c1c5b   Overall PASS
  synthesis  0 errors / 0 warnings / 0 latches  (无 allowlist,直接 0 warning)
  simulation od_test_top PASS
  gate       IMPLEMENT_ALLOWED(constraintsReviewed=true,expectImplementationBlocked=false)
```

综合/实现/bitstream run `20260917-160223-4ac8eeec`(六阶段退出码全 0):

| 项 | 值 |
|---|---|
| MAP / PAR | **0 errors / 0 warnings**;`All signals are completely routed`;`Timing Score: 0` |
| bonded IOBs | **3**(clk P57 INPUT/IBUF、p31_test P31 TRISTATE、p32_test P32 TRISTATE) |
| LOCATED | **3/3 全部 LOCATED**,`design.pcf` 只有这 3 条 `LOCATE`,无自动分配 I/O |
| IOSTANDARD | 三个脚全部 `LVCMOS33`(Bank 2/3) |
| timing.twr(人工阅读) | `TS_clk = PERIOD TIMEGRP "clk_group" 83.33 ns` → **0 timing errors**、`All constraints were met.`、最小周期 5.440 ns、最差 setup slack 77.890 ns;UCF 无 OFFSET,板级 I/O 时序未认证 |
| bitstream | `design.bit` **54 738 字节**,DRC 0 errors / 0 warnings |
| SHA256 | `4bc753ce2d3779ddf4636961b5654ed6ca34b56c5ef41c3f1f62312150e1cfc6` |

bitstream 路径:

```text
projects/finger_piano_od_test/artifacts/20260917-160223-4ac8eeec/results/design.bit
```

## 状态

```text
OD DIAGNOSTIC BITSTREAM = READY
BOARD TEST              = READY_FOR_BOARD_TEST(等待用户实测 P31/P32)
PROGRAM                 = DONE(2026-09-17 volatile Jtag,经用户明确授权)
userDesignFunctional    = NOT_TESTED
```

**从未执行 ISF 写入。** 2026-09-17 经用户明确要求 + `-ConfirmHardwareWrite`
执行了一次 **volatile Jtag** 配置(见下);烧录成功只是配置证据,
**不构成板级功能 PASS**。

## 授权烧录记录(2026-09-17)

| 模式 | run id | 结果 | 关键证据 |
|---|---|---|---|
| Jtag(易失) | `program-20260917-160448-8a55fdf0` | `PASS` / `CONFIG_STATUS_OK` | preflight PASS(cable SN 210241672559 / 10 MHz);`Programming device` → `Completed downloading bit file to device` → `Programmed successfully`;转录无任何 SPI/Flash/sector 行;`M[2:0]=011`、`DONEIN=1`、`CRC error=0`、`GWE=1` |

- 前一次尝试(`program-20260917-160428-4827500f`)因下载线
  `DIGILENT_OPEN_FAILED`(`failed to open device (DmgrOpenEx, erc = 3072)`)在
  preflight 阶段失败,**未写入任何内容**(`PREFLIGHT_FAILED`);重试后成功。
  属 fpga-vm USB 透传层问题,与工具/板卡无关。
- 当前硬件状态:**FPGA fabric = od_test(易失,掉电丢失)**;内部 ISF 仍是
  P9 诊断 mode 0 镜像(上电启动 P9 诊断,不是本工程)。
- `userDesignFunctional` 依旧 **NOT_TESTED**:需要在板级实测 P31/P32 波形。

## 板测步骤(建议)

1. 按上面「硬件前提」接好外部 3.3 V 上拉,断开 ADS1115;
2. 授权烧录后,用示波器/频率计分别测 P31 与 P32:
   - P31:约 1 kHz 方波,幅度 0 → 3.3 V(高电平来自外部上拉);
   - P32:约 2 kHz 方波,同幅度;
3. 确认高电平幅度由上拉电阻决定:若把上拉断开,高电平应消失(线保持低/浮空),
   这能证明 FPGA **没有**内部上拉、也没有推挽驱动 1;
4. 本工程不测 ADS1115 通信,也不涉及 LM386 / 扬声器。

结论边界:频率计/示波器观察到方波 **≠** 上升时间/信号完整性认证;需要按
实际总线速率与容性负载评估。

## 未做(明确)

- 未做板级测量、未做上升/下降时间测量、未做容性负载评估;
- 未执行任何 `program`(JTAG/ISF 都没有);
- 不使用 P3 复位脚(本工程 UCF 只允许 P57/P31/P32),复位后行为依赖 FPGA
  上电初始化(GSR)。
