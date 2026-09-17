# finger_piano_od_test — P31/P32 开漏(open-drain)IO 板级诊断工程

独立、最小、低风险的 open-drain 诊断 bitstream:在 ADS1115 完全断开、P31/P32
各自用 **4.7 kΩ 上拉到 3.3 V** 的条件下,用一个**运行时变化的慢速相位**让两路
开漏输出互补,每个状态保持 1 秒,单个 bitstream 内就能分别观察
**Z(外部上拉 -> 约 3.3 V)** 与 **LOW(约 0 V)**,并验证
"只拉低、绝不推挽驱动 1"。

- 器件:`xc3s50an-4-tqg144`
- 时钟:**P57 = 12 MHz 有源晶振(唯一时钟域)**
- 复位:**P3 `rst_n`(低有效)**
- 输出:`p31_test` = **P31**、`p32_test` = **P32**,顶层 **inout**,全部 `LVCMOS33`
- **UCF 只约束 4 个引脚**(P57/P3/P31/P32),**不写 PULLUP/PULLDOWN**,不写 OFFSET
- 不使用 `KEEP`/`DONT_TOUCH`

## 行为(2 秒完整周期)

| 相位 | 时间 | P31 | P32 | 板上电平(P31 / P32) |
|---|---|---|---|---|
| 0 | 0 ~ 1 s | **Z** | **LOW** | 外部上拉 -> 约 3.3 V / 约 0 V |
| 1 | 1 ~ 2 s | **LOW** | **Z** | 约 0 V / 外部上拉 -> 约 3.3 V |

```verilog
wire p31_drive_low = phase;      // phase=0 -> P31 释放
wire p32_drive_low = ~phase;     // phase=0 -> P32 拉低
assign p31_test = p31_drive_low ? 1'b0 : 1'bz;
assign p32_test = p32_drive_low ? 1'b0 : 1'bz;
```

相位由 `PHASE_HALF_CYC = 12,000,000` 个 clk 的计数器产生(12 MHz 下正好 1 秒),
全工程只有 `posedge clk` 一个时钟域,只有 `negedge rst_n` 一个异步复位。

**为什么不做"常量 Z"**:常量 Z 会被 XST 直接裁成 UNUSED 脚,而 bitgen 默认
`UnusedPin = Pulldown` 会给该脚加内部弱下拉,既不是真正高阻,也违反
"不启用内部 PULLUP/PULLDOWN"。这里两路都是由运行时相位驱动的真实三态缓冲,
综合器无法把它们当常量优化掉,因此两个 OBUFT 都保留、两个脚都 `LOCATED`。

## 与其它工程的关系

本工程**完全独立**:不修改正式 `finger_piano`、不改 P9 `finger_piano_periph_test`、
不改正式 UCF,也不新增/修改任何 warning allowlist。没有复用文件。

```text
projects/finger_piano_od_test/
  project.json                      top=od_test_top
  src/od_test_cfg.vh                ★ 配置真值源:SYS_CLK_HZ / PHASE_HALF_CYC
  src/od_test_top.v                 ★ 顶层(rst_n + 慢速相位 + 两路开漏输出)
  constraints/od_test.ucf           P57/P3/P31/P32,LVCMOS33,无 PULLUP/PULLDOWN
  sim/tb_od_test_top.v              testbench(快速用例 + 真实 1 秒用例)
  README.md
```

## 硬件前提(板测前必须满足)

```text
[ ] ADS1115 完全断开(不与 P31/P32 抢总线)
[ ] P31 单独经 4.7 kΩ 上拉到 3.3 V
[ ] P32 单独经 4.7 kΩ 上拉到 3.3 V
[ ] P57 接 12 MHz 有源晶振;P3 接低有效复位(外部上拉/RC)
[ ] VCCO(Bank 2/3)= 3.3 V
[ ] 不依赖 FPGA 内部 PULLUP/PULLDOWN(本设计/本 UCF 都没有)
```

## 仿真判定

两个用例,判据是 `TB_OD_TEST_TOP: PASS/FAIL`。TB 用
`always @(posedge clk) clk_edges = clk_edges + 1` 累计 clk 沿,在 P31 的
`Z->LOW` / `LOW->Z` 跳变处记录沿号,两个跳变之差就是一个状态持续的真实拍数。

实测:

```text
od_test_fast     (TB_PHASE_HALF_CYC=200)      z_width=200 clk   low_width=200 clk
od_test_real_1s  (TB_PHASE_HALF_CYC=12000000) z_width=12000000 clk low_width=12000000 clk
TB_OD_TEST_TOP: PASS
```

- `sim-20260917-162148-08626fc3`(fast)、`sim-20260917-162206-ef560259`(real)
- 真实用例还逐 clk 检查:两路只能是 0/Z(0 次驱动 1)、两路恒互补、两种状态
  都出现过;复位期间 P31=Z、P32=LOW。

## 软件验证结果(2026-09-17)

```text
verify-20260917-162242-83a5f2d2   Overall PASS
  synthesis  0 errors / 0 warnings / 0 latches(无 allowlist,直接 0 warning)
  simulation od_test_fast PASS + od_test_real_1s PASS
  gate       IMPLEMENT_ALLOWED
```

实现/bitstream run `20260917-162326-70a97bfb`(六阶段退出码全 0):

| 项 | 值 |
|---|---|
| MAP / PAR | **0 errors / 0 warnings**;`All signals are completely routed`;`Timing Score: 0` |
| bonded IOBs | **4**:`clk` P57 INPUT/IBUF、`rst_n` P3 INPUT/IBUF、`p31_test` P31 **TRISTATE**、`p32_test` P32 **TRISTATE** |
| LOCATED | **4/4 全部 LOCATED**,`design.pcf` 只有这 4 条 `LOCATE`,无自动分配 I/O |
| IOSTANDARD | 四个脚全部 `LVCMOS33` |
| Termination | 两个开漏脚 `NONE**`(**无内部上/下拉**) |
| timing.twr(人工阅读) | `TS_clk = PERIOD TIMEGRP "clk_group" 83.33 ns` → **0 timing errors**、`All constraints were met.`、最小周期 5.675 ns;UCF 无 OFFSET,板级 I/O 时序未认证 |
| bitstream | `design.bit` **54 738 字节**,DRC 0 errors / 0 warnings |
| SHA256 | `4dea3b6dc2f151db49aed3bc0162675fc9e28619a6c3fddbbd5846c7e08a9c1f` |

bitstream 路径:

```text
projects/finger_piano_od_test/artifacts/20260917-162326-70a97bfb/results/design.bit
```

## 状态

```text
OD DIAGNOSTIC BITSTREAM = READY
BOARD TEST              = READY_FOR_BOARD_TEST(等待用户实测)
PROGRAM                 = DONE(2026-09-17 volatile Jtag,经用户明确授权)
userDesignFunctional    = NOT_TESTED
```

**未执行 ISF 写入。** 2026-09-17 经用户明确要求 + `-ConfirmHardwareWrite`
执行了一次 **volatile Jtag** 配置(见下);烧录成功只是配置证据,
**不构成板级功能 PASS**。

## 授权烧录记录(2026-09-17)

| 模式 | run id | 镜像 | 结果 | 关键证据 |
|---|---|---|---|---|
| Jtag(易失) | `program-20260917-162532-7fe23477` | `20260917-162326-70a97bfb`(SHA256 `4dea3b6d…7e08a9c1f`) | `PASS` / `CONFIG_STATUS_OK` | preflight PASS(cable SN 210241672559 / 10 MHz);`Programming device` → `Completed downloading bit file to device` → `Programmed successfully`;转录无任何 SPI/Flash/sector 行;`M[2:0]=011`、`DONEIN=1`、`CRC error=0`、`GWE=1` |

- 前一次尝试(`program-20260917-162506-060a5d7b`)因下载线
  `DIGILENT_OPEN_FAILED`(`failed to open device (DmgrOpenEx, erc = 3072)`)在
  preflight 阶段失败,**未写入任何内容**(`PREFLIGHT_FAILED`);重试后成功。
  属 fpga-vm USB 透传层问题,与工具/板卡无关。
- 当前硬件状态:**FPGA fabric = 本工程慢速互补开漏设计(易失,掉电丢失)**;
  内部 ISF 仍是 P9 诊断 mode 0 镜像(上电启动 P9 诊断,不是本工程)。
- `userDesignFunctional` 依旧 **NOT_TESTED**:需要在板级按 §板测步骤实测。

## 板测步骤(建议)

1. 按上面「硬件前提」接好两路 4.7 kΩ 上拉,断开 ADS1115;
2. 上电/配置后观察(每 1 秒互换一次,周期 2 秒):
   - 相位 0:P31 应为约 3.3 V(外部上拉,FPGA 未驱动),P32 应为约 0 V(FPGA 拉低);
   - 相位 1:P31 应为约 0 V,P32 应为约 3.3 V;
3. 若把某路上拉断开,该路在高阻相位应变为浮空/低,可进一步证明 FPGA 没有
   内部上拉、也没有推挽驱动 1;
4. 本工程不测 ADS1115 通信,也不涉及 LM386 / 扬声器。

结论边界:示波器/万用表观察到电平 **≠** 上升时间/信号完整性认证;需要按
实际总线速率与容性负载评估。

## 未做(明确)

- 未做板级测量、未做上升/下降时间测量、未做容性负载评估;
- 只做了 volatile Jtag 写入(有授权记录),未做 ISF 写入;
- 上一版 1 kHz / 2 kHz 快速开漏方波设计只保留在 Git 历史(`f4ba528` 及其前);
  本版按用户新要求改为 1 秒慢速互补相位,以便单个 bitstream 同时验证
  Z 与 LOW 两种状态。
