# 手指钢琴 OLED 集成资源优化与音量余量计划

日期：2026-09-22。状态：**COMPLETED（O0～O2d 已完整实施并闭环验收，资源指标超额达成）**。

执行工程：`projects/finger_piano_oled_integration`。
兼容性基线：`projects/finger_piano`（保持 100% 零改动）。
独立 OLED 测试参考：`projects/finger_piano_oled_test`。
基线分析提交：`14d7f3c`；最终验收提交：`a69d87e` (`a69d87e5`)。

本文档已由初始计划更新为实际执行结项报告。各小阶段的真实 Run ID、实测 MAP/PAR 资源指标、时序分析与告警审计数据均已填入相应章节。

## 1. 目标与范围

在保持传感器输入、ADS1115、DDS、MCP4725 和 SSD1306 现有外部行为的前提下，降低 XC3S50AN 的 Slice/LUT 占用，为后续数字音量和压力控制保留空间。

本计划的优化实施范围为 O0～O4、O6；O5 负责预算与后续集成条件说明，不自动启动尚未定义的压力到音量功能开发。

### 1.1 初步资源目标

| 里程碑 | 目标 | 解释 |
|---|---|---|
| OLED 集成、尚未接音量 | occupied Slices ≤ 560/704（约 79.5%） | 预留至少 144 个 Slice；是设计预算，不是已测得收益 |
| 后续真实压力音量完整接入 | 争取 occupied Slices ≤ 600/704（约 85.2%） | 保留至少 104 个 Slice；须在真实功能顶层重新实现后确认 |
| 所有阶段 | FF/LUT/BRAM 不超器件容量；完成布线；现有时序约束无失败 | 不能只比较综合估算或单个模块面积 |

560→600 的 40 Slice 差额不是给音量功能承诺的固定成本。若压力链恢复和音量逻辑的实际增量更大，必须进一步降低前级占用或重新评审预算，不能为了达到数字而裁功能。

功能验证通过而资源目标未达到时，分别记为“功能 PASS / 面积目标未达到”。可以保留已验证且确有收益的独立优化，但不能宣布整份资源计划完成。

### 1.2 工作边界

- 器件配置保持 `xc3s50an-4-tqg144`；不凭计划改变封装、速度等级、时钟、引脚或约束确认状态。
- 保持 12 MHz 单时钟域；节拍使用 clock-enable。保持当前 DDS 24 位相位累加、8 位查表相位和 8 kS/s 输出节奏。
- ADS1115、MCP4725 保持两套独立 I²C 实例与物理总线；OLED 保持自身独立总线。
- 保留 ADC 超时、NACK/错误恢复，以及 DAC pending/overrun 语义；MCP4725 仍仅 Fast Write，不写 EEPROM。
- 不删除或改写 legacy 7-key 功能，不以删除未实例化文件作为资源优化。
- 使用 Verilog-2001；新增头文件、模型、源文件必须显式配置，路径在本工程内，ASCII、无空格，无越界引用和符号链接。
- 不增加工具命令、不改 programmer backend，不执行硬件写入；后续板测需用户另行明确授权。
- 保持 `failOnSynthesisWarnings=true`；不得以全局静音、KEEP/DONT_TOUCH、假消费者或禁用测试绕过验收。
- FSR 零点、量程、阈值和融合规则仍为 NOT_CALIBRATED/TODO，不使用猜测的数值构造所谓最终音量功能。

## 2. 已核对的基线证据

### 2.1 工程配置与输入一致性

| 项目 | 主工程 | OLED 集成工程 |
|---|---|---|
| 顶层 | `finger_piano_stage2_top` | `finger_piano_stage2_oled_top` |
| 综合配置 | Speed / level 1 | Speed / level 1 |
| `expectImplementationBlocked` 分析时快照 | false | false |
| 配置中的仿真用例数 | 35 | **0** |
| 用于资源比较的构建编号 | `20260921-204239-6b3c174b` | `20260921-220404-5bf1a2af` |

分析时两份构建 `run.json.files` 中的输入 SHA-256 与各自当前工程文件全部一致；两个工程的共用源码和配置头文件也一致。后续每次实验仍须重新记录哈希，不能永久沿用此结论。门禁字段必须每次读取，不能把表中快照当成固定规则。

证据位置（artifacts 不入库，其他机器缺文件时不得伪造或用别的 run 补齐）：

- [主工程 run.json](../../finger_piano/artifacts/20260921-204239-6b3c174b/run.json)
- [主工程 MAP](../../finger_piano/artifacts/20260921-204239-6b3c174b/results/mapped.mrp)
- [集成工程 run.json](../artifacts/20260921-220404-5bf1a2af/run.json)
- [集成工程 XST](../artifacts/20260921-220404-5bf1a2af/results/synthesis.srp)
- [集成工程 MAP](../artifacts/20260921-220404-5bf1a2af/results/mapped.mrp)
- [集成工程时序](../artifacts/20260921-220404-5bf1a2af/results/timing.twr)
- [集成工程已有 verify](../artifacts/verify-20260921-220344-887dc140/verification.json)

### 2.2 MAP 资源比较

| 指标 | 主工程 | OLED 集成 | 净增量 |
|---|---:|---:|---:|
| occupied Slices / 704 | 594 | 702 | +108 |
| logic LUT / 1408 | 948 | 1167 | +219 |
| route-thru LUT | 147 | 166 | +19 |
| total LUT（含 route-thru）/ 1408 | 1095 | 1333 | +238 |
| Slice FF / 1408 | 417 | 519 | +102 |
| BRAM / 3 | 0 | 2 | +2 |
| 用户 I/O | 12 | 14 | +2 |

使用同口径 MAP 字段，不把 XST 的 LUT 估算和 MAP logic LUT 混在同一列。净增量是两个完整设计的差值，不等于 OLED 模块独立面积，跨层优化和打包可能改变结果。

基础系统已占 84% 左右 Slice；集成设计 occupied Slices 约 99.7%，但 FF 约 36.9%、logic LUT 约 82.9%、total LUT 约 94.7%。优化重点应是组合逻辑、算术位宽和打包，不能将“仅余 2 Slice”理解为内部所有 LUT/FF 都已填满。

当前 MAP 未展开 Utilization by Hierarchy，因此没有可信的最终模块面积排名。XST 的中间宏统计能够定位候选结构，但不能直接换算最终节省的 Slice 数。

### 2.3 时序、告警和验证覆盖

- 已阅读集成构建 `timing.twr`：`TS_clk = PERIOD 83.33 ns`，0 failing endpoints，最差 setup slack 70.522 ns，报告 minimum period 12.808 ns。
- 报告仍列出未约束 OFFSET IN、OFFSET OUT 和其他路径；无失败只说明已约束范围满足，不等于外部接口时序或板卡功能通过。不得为面积优化放松 UCF 或添加 TIG 掩盖路径。
- 集成 verify 的结果为 PASS，但 `simulationResult = NOT_CONFIGURED`。这不是集成仿真通过的证据，O0 必须先补齐。
- 集成 verify 审阅允许的 XST 告警为 167 条、unexpected 为 0。MAP 另有 16 条 `PhysDesignRules:812`，对应两块 ROM 的 DIA0～DIA7 dangling pin；不能将 XST allowlist 当成 MAP 告警豁免或称实现“零告警”。后续记录变化并逐条审阅。
- 无本轮新构建、优化收益或板测结果。

## 3. 优化候选与排序

| 候选 | 证据与预期方向 | 主要代价/风险 | 优先级 |
|---|---|---|---|
| 参数化收窄计数器 | 两个 I²C master 仍推断 32 位算术；可能同时减 FF、LUT、进位链 | 边界、回绕、参数兼容性 | 高 |
| DDS 全周期同步 BRAM ROM | 现有 quarter-wave 表、折返、加减在逻辑中；剩余一块 BRAM | 时序对齐、复位/切音行为；BRAM 达 3/3 | 高，按实测决定 |
| Area/1、Area/2 综合对比 | 当前为 Speed/1，已约束内部时序余量较大 | 面积不保证单调改善；必须重新实现 | 低成本先试 |
| OLED FSM 编码/固定最高位移出 | seq_state 和发送器被 XST 编为 one-hot；发送使用动态选位 | FF 节省可能换来更多 LUT | 第二轮 |
| 进一步压缩 OLED 图像数据 | 当前两份 ROM 已在 BRAM | 存储字节减少未必降低 Slice；解压可能增逻辑 | 暂缓 |
| 两个外设共享总线、删超时/异常逻辑 | 会改变既有架构或功能 | 不符合本项目边界 | 不采用 |

不预先承诺每项节省多少 Slice。每项最终以“同输入功能、同约束、完整实现后的差值”决定保留与否。

## 4. O0：冻结基线并补齐回归

### 4.1 准备与文件归属

1. 阅读根规则、[主工程规则](../../finger_piano/AGENTS.md)、[文档入口](../../../doc/README.md)、[主工程 README](../../finger_piano/README.md)及两个工程当前 project.json。
2. 核对已有基线哈希、分支和工作区，保留原始报告与 run ID；首次使用远程环境或环境改变时运行 doctor。
3. 在集成工程建立工程内 `sim/` 和 `sim/models/`，复制所需 TB/模型，不在 project.json 使用 `../` 引用其他工程。
4. 将主工程当前全部 enabled 回归移植为针对集成工程源码的测试。分析时为 35 项，执行时以实际配置为准，不因数量变化删减旧覆盖。
5. 复用独立 OLED 工程的 SSD1306 模型、BRAM 模型和测试思路。先比较源码版本，不能用通过旧版 OLED 的测试替代当前版本验证。
6. TB 和行为模型仅列在 simulations，不加入综合 sources。包含文件显式同步；不得同时定义行为模型与同名厂商原语导致重复模块。

### 4.2 新增集成验收内容

| 场景 | 必须观察的结果 |
|---|---|
| 上电初始化 | 硬件参数延时不短于现有设计；27 字节初始化、8 页各 128 字节清零、标题、初始音符和显示开启顺序正确 |
| 八种音符状态 | MUTE/C4～B4 的所有动态页与参考字节一致；稳定音符不重复刷新 |
| 刷新期间 A→B→C、A→B→A | 发送的一轮使用一致的 active_note；轮末按最新输入决定后续刷新，不回放过期 pending 状态 |
| OLED 与 DAC 并行 | DDS valid 每 1500 拍；正常样点 generated/accepted/written 一致，mismatch/drop/overrun 为 0 |
| OLED 与 ADC 并行 | 三通道轮询及压力帧顺序保持，不因 OLED 活动改变配置或协议 |
| OLED 地址/控制/数据 NACK | 既定 STOP/释放与错误停机行为保持；ADC/DAC 不受影响 |
| ADC/DAC 错误注入 | 保持旧回归中的错误恢复与隔离语义；不会改变 OLED 控制状态 |
| 传输途中复位 | 三条总线按既有语义释放，恢复流程确定；DDS 静音中心和节拍行为正确 |

“一轮 active_note 一致”只保证 FPGA 发送内容的一致性，不据此宣称 SSD1306 内部扫描在物理显示上绝无撕裂。SIM_FAST_INIT 可用于多数回归，但必须保留至少一项真实硬件延时分支检查，不能只测快速分支。

**退出条件：** 集成工程仿真不再为 NOT_CONFIGURED；全部 enabled 测试明确 PASS；未优化 RTL 下完成集成 verify 和 implement 基线，记录新 run ID。若新增测试暴露原有问题，单独定位并验证修复，不与面积优化混为一次提交。

### 4.3 O0 实施结果与基线记录

- **仿真回归网补齐**：完成 `sim/` 与 `sim/models/` 独立搭建，移植 35 项单测，新增 `tb_finger_piano_stage2_oled_top.v`（三总线并行、NACK 隔离、快速切音、途中复位）及 OLED 专项测试，配置共 37 项 enabled 仿真。
- **全量 Verify 基线**：`verify-20260921-223231-a13029b5`（37/37 PASS，XST exit 0，167 告警审阅通过，0 锁存器，门禁开放）。
- **未优化实现基线 (O0 Implement)**：Run ID `20260921-223857-612bf5e3`
  - occupied Slices: **702 / 704 (99.7%)**
  - logic LUT: **1,167 / 1,408 (82.8%)**
  - Slice FF: **519 / 1,408 (36.8%)**
  - RAMB16: **2 / 3 (66%)**
  - Timing: 0 errors, Slack **+70.522 ns**, Minimum Period 12.808 ns (Fmax 78.07 MHz)
- **提交**：`eeed27b`

## 5. O1：综合策略受控对比

在 O0 同一份 RTL、UCF、器件、顶层、源顺序和仿真配置下，依次比较：

| 实验 | optimization | optimizationLevel |
|---|---|---:|
| O1-S1 | Speed | 1 |
| O1-A1 | Area | 1 |
| O1-A2 | Area | 2 |

只使用既有 project.json 字段和 ise.ps1 入口，每个配置保存独立快照和 run ID。不要同时加入 FSM 属性或改位宽，否则无法归因。不扩展工具来加入新的 MAP 参数。

每个配置执行 verify，随后 check/implement，记录 XST、MAP、PAR、时序及告警。不将失败的候选配置提交为正式状态。选择功能、告警、已约束时序均合格且最终资源更合理的配置；无收益则保留 Speed/1。

后续 RTL 实验固定所选配置。若重新比较配置，另列实验，不把配置收益误计到 RTL 改动中。

### 5.1 O1 综合策略实测对比结果

| 实验 | 策略配置 | occupied Slices | logic LUT | Slice FF | Slack | Run ID | 结论 |
|---|---|---:|---:|---:|---:|---|---|
| O1-S1 | Speed / 1 | 702 (99.7%) | 1,167 | 519 | +70.522 ns | `20260921-223857-612bf5e3` | 基线对照 |
| O1-A1 | Area / 1 | **686 (97.4%)** | **1,103** | **506** | **+70.942 ns** | `20260921-234744-460982d6` | **采纳：省 16 Slices, 64 LUTs, 13 FFs, 时序裕量提升** |
| O1-A2 | Area / 2 | 702 (99.7%) | 1,138 | 506 | +70.820 ns | `20260921-234842-b4b1580c` | 淘汰：过度重排导致切片碎片化回升 |

- **全量 Verify**：Run ID `verify-20260921-234932-e9155e29`（37/37 PASS）
- **提交**：`4a56c98`，后续所有 RTL 优化均固定在 Area/1 策略下执行。

## 6. O2：计数器按参数收窄

### 6.1 候选范围

| 文件/信号 | 当前声明 | 当前运行参数 | 候选位宽 | 建议小阶段 |
|---|---:|---|---:|---|
| `src/periph/i2c_master.v`：两实例 phase_cnt | 各 32 | 相位最大装载 18，另含固定装载 2 | 5 | O2a |
| 同文件：两实例 timeout_cnt | 各 32 | `36*(18+18)+1024 = 2320` | 12 | O2a |
| `src/periph/ads1115_ctrl.v`：wait_cnt | 32 | OS_WAIT_CYCLES=24000 | 15，须证明/处理持续累计 | O2b |
| `src/audio/dds_sine_generator.v`：sample_cnt | 16 | SAMPLE_DIV=1500，计数 0～1499 | 11 | O2c |
| `src/input/sensor_code_filter.v`：stable_count | 24 | 10 ms×12 MHz=120000 周期 | 17 | O2d |

合计候选声明位缩减约 123 位；这不是最终 FF、LUT 或 Slice 的保证节省量。XST 后端可能已裁剪部分位，必须用实际 MAP 对比。

### 6.2 实现规则

- 用 Verilog-2001 常量函数计算所需位数，最小返回 1，不能使用 `$clog2`。区分“最大计数值 N”所需 `ceil(log2(N+1))` 与“计数 0～N-1”所需 `ceil(log2(N))`。
- phase_cnt 的最大值覆盖 LOW/HIGH、HDSTA、SUSTA、SUSTO、BUF 的安全值及固定装载常数；保留现有参数钳制规则，不只检查当前的 18 拍。
- timeout_cnt 必须能够表示阈值本身，保持比较与递增的先后语义、ready/error 脉冲周期和总线释放时刻。
- 不通过缩短超时、降低采样率、放松滤波或减小 DDS 相位宽度换面积。
- ADS wait_cnt 在 wait_active 时持续累计，阈值只在 S_W_CHK 检查。不得直接截宽后允许回绕；优先评估阈值饱和，使“已超时”保持到检查点，同时保留 OS-ready 优先级、停止条件和配置写入后的清零时刻。若等价性不能证明，保留较宽位数。
- sensor_code_filter 原有 CNT_WIDTH 参数与共享宏涉及 legacy 用途，先核对所有实例。只对目标实例推导有效位宽或增加向后兼容选择，不全局把宏改成 17 破坏其他参数组合。
- 审查所有装载、加减、比较的扩展与截断，不能只改 reg 声明；不为隐藏告警改算法。

### 6.3 验证与退出条件

每个小阶段单独验证、单独记录资源：

1. I²C：正常 START/repeated START/READ/WRITE/STOP、NACK、超时、非法命令、复位释放；检查 SCL/SDA 外部轨迹与旧版等价。
2. 参数边界：最小有效参数、2 的幂及其相邻值、项目现有支持范围内的大参数；包含阈值恰好在边界的情况，避免只测默认值。
3. ADS：跨多个 poll 累计；OS-ready 与超时同次检查；未完成转换、错误停止后恢复、接近计数上限和复位。
4. DDS：周期精确为 1500；七音、静音、相邻采样沿前后切音；phase increment 表和相位宽度不变。
5. 滤波：阈值前一拍/恰好达阈值、短毛刺、整个向量变化和旁路参数。

**退出条件：** 全量 verify PASS，check/implement 完成，时序复核合格，逐项记录资源变化。出现协议/周期差异必须修复；功能等价但无面积收益时记录结论并回退该候选，不把它列为成功瘦身。

### 6.4 O2 实施结果与明细对比（O2a～O2d）

针对推断出过宽加法器与比较器的控制计数器，全部采用 Verilog-2001 常量函数（无 `$clog2`）推导最小位宽，逐步实施并闭环验证：

| 阶段 | 优化对象与改动说明 | occupied Slices | logic LUT | Slice FF | Slack | 净增减 | Implement Run ID | 关联 Commit |
|---|---|---:|---:|---:|---:|---|---|---|
| **O1 结项点** | Area / 1 综合策略定型 | 686 (97.4%) | 1,103 | 506 | +70.942 ns | 基准 | `20260921-234744-460982d6` | `4a56c98` |
| **O2a** | `i2c_master.v`：`phase_cnt` (32→5), `timeout_cnt` (32→12)，抽取比较中间线，削减两实例共 94 个 FF | 532 (75.5%) | 842 | 412 | +72.197 ns | **-154 Slices, -261 LUTs, -94 FFs** | `20260921-235900-7c8e6706` | `2283638` |
| **O2b** | `ads1115_ctrl.v`：`wait_cnt` (32→16)，增加饱和截断防止回绕 | 513 (72.8%) | 821 | 396 | +71.262 ns | **-19 Slices, -21 LUTs, -16 FFs** | `20260922-000316-f99a9ee2` | `5ccac52` |
| **O2c** | `dds_sine_generator.v`：`sample_cnt` (16→11，针对 SAMPLE_DIV=1500) | 508 (72.1%) | 815 | 391 | +70.260 ns | **-5 Slices, -6 LUTs, -5 FFs** | `20260922-000603-1cee942d` | `5efa7f5` |
| **O2d** | `sensor_code_filter.v`：`stable_count` (24→17，针对 120000 周期去抖) | **500 (71.0%)** | **806** | **384** | **+69.888 ns** | **-8 Slices, -9 LUTs, -7 FFs** | `20260922-000818-fcaf41fa` | `a69d87e` |

**O2 阶段总体成效**：
- Slices 从 686 降至 500（净节省 **186 Slices**，相对 O0 基线累计净节省 **202 Slices**）；
- Logic LUT 从 1,103 降至 806（净节省 **297 LUTs**，相对 O0 基线累计净节省 **361 LUTs**）；
- Slice FF 从 506 降至 384（净节省 **122 FFs**，相对 O0 基线累计净节省 **135 FFs**）；
- 时序余量保持极高水平（Slack +69.888 ns，0 timing errors，Fmax 74.394 MHz）。

## 7. O3：DDS 正弦表迁入 BRAM 的条件实验（DEFERRED 暂缓）

### 7.1 设计方向

现有 `sine_lut_12bit.v` 是 65 点 quarter-wave 表，加象限折返和幅值加减；XST 推断 128×11 ROM 宏，最终仍由逻辑实现。当前最慢内部路径经过这一链。

候选方案：从旧 RTL 的确定输出离线展开完整 256×12 bit 表（3072 bit），以一块支持足够字宽的同步 BRAM 实现。保留原函数用于 golden 比对/原版本使用，不把现有组合接口悄悄改成同步接口。新增模块建议单独命名，如 `sine_rom_12bit_sync.v`。

实现候选要明确输出寄存器是否被 BRAM 吸收或采用预取；不能只插入一拍并平移 valid 就默认行为等价。需要画清周期表或列出时序表，覆盖：

- 复位释放后首次 sample_tick；
- 正常相位推进（先输出旧相位样点，再推进相位）；
- note 切换与 sample_tick 同拍、前一拍、后一拍；
- note=0 静音时输出 2048，仍维持原 valid 节奏；
- 下游 busy 时不暂停 DDS 时间轴。

允许内部组织变化，但不能改变外部音符切换、数据/valid 及 DAC 样点序列。若必须改变外部延迟契约，退出本次等价优化，另行评审，不能直接放宽测试。

### 7.2 BRAM 和验证要求

- 使用后 BRAM 将从 2/3 变为 3/3；必须在结果中明确记录。这是 Slice 与 BRAM 的交换，不是所有资源同时下降。
- 数据来自现有整数表及运算结果，256 个相位必须逐值完全一致；不重新用浮点 sin 四舍五入生成近似表。
- 保留四个锚点：0→2048、64→3840、128→2048、192→256；全相位范围 256～3840。
- 配置工程内仿真模型或受支持厂商模型，核对 INIT 地址/位序、同步读取、使能/复位行为。现有 RAMB16_S9 模型不能直接冒充不同字宽原语模型。
- 依次完成 ROM 全表、DDS 周期等价、DDS→MCP4725、DDS→gain→MCP4725 与集成回归；正常流仍须 0 drop/overrun/mismatch。
- 不承诺单块 BRAM 容纳 256×8 档×12 bit 的完整相位音量二维表（24576 bit）；本阶段保持增益模块独立。

**保留条件与执行结论：** 
依据本节约定：“若 O2 已达到预算，可记录 O3 为 DEFERRED，保留 BRAM”。
**实际执行结论**：O2 实施后 occupied Slices 已达到 **500 / 704 (71.0%)**，预留空闲 Slices 达 **204 个**（目标 $\ge 144$ 已超额达成）。因此 **O3 记录为 DEFERRED，不实施 DDS BRAM 迁入，完整保留第 3 块 BRAM（保持 2/3 占用）**。

## 8. O4：按剩余差额选择 OLED 局部优化（NOT_NEEDED 无须执行）

仅在 O1～O3 的结果仍不足时开展，每次只变一项：

1. 比较 seq_state、oled_i2c_write 状态编码；现有 XST 采用部分 one-hot、部分 gray。不要认为源码 reg 位宽就是最终状态位数，也不要全局强制所有 FSM 用二进制。
2. 比较动态选位 `shift_reg[bit_cnt]` 与固定最高位移出的结构；确保只在正确位边界移位，最后一位、ACK 和 START 地址发送不变。
3. 按实际综合结果评估重复译码/数据选择路径，避免为节省很少逻辑合并整个控制器。

必须保留上电等待、初始化字节、8 页清零、标题和全部音符图像、帧内 active_note 一致、稳定时不刷新、NACK 停止/释放。不能以缩短文字、删音符或停止 ADC 等方式充当等价优化。

OLED bitmap 与 fixed ROM 已在两块 BRAM 中，单纯压缩字节不等于减少 Slice。双复位同步器等少量寄存器不是首要对象。

**执行结论**：因 O2 已实现充分的资源预留，**O4 判定为 NOT_NEEDED（无须进一步微调 OLED 逻辑）**，保持当前稳定验证过的单流式引擎状态。

## 9. O5：音量与压力链资源预算

### 9.1 当前尚未计入的硬件

当前 Stage-2 顶层把 pressure_ch0/1/2 和 pressure_valid 悬空；部分 ADC 数据寄存器及压力捕获逻辑被合法裁剪。后续接真实压力消费者后，它们会恢复，不能仅预算一个增益模块。

P8 已有独立增益资源记录：run `20260917-000243-066eda17`，43 Slice、80 LUT4、0 FF、0 multiplier，见[主工程 P8 记录](../../finger_piano/README.md)。这是独立综合口径，不能直接与完整 MAP 相加或当成真实集成增量。

### 9.2 待测预算项目

| 项目 | 目前结论 | 后续取得证据的方法 |
|---|---|---|
| audio_gain 与 pipeline | 已有 standalone 功能验证，集成增量未知 | 使用真正运行时 volume 输入的合法功能设计，比较完整实现结果 |
| ADC 结果与 pressure frame 恢复 | 当前部分被裁剪 | 在真实压力消费者接入时检查层次和 trim 变化 |
| 压力等级/融合/标定 | 未定义、NOT_CALIBRATED | 取得实测数据与功能规格后另立计划 |
| 音量变化的同步与控制 | 待确定最终输入契约 | 明确在哪个样点锁存音量，验证无旧样点/新音量错配 |
| 集成打包、布线余量 | 不能从独立面积精确相加 | 最终顶层 MAP/PAR 和 timing.twr |

音量样点保持围绕 2048 缩放、level=0 输出 2048、level=7 为现有约 7/8 增益。原 shift/add 量化与理想乘除可能差 1 LSB；保持旧 RTL 的逐值语义，不擅自换成“更精确”的算法。

不得为了“测满资源”新增 KEEP、假硬件消费者或猜测的压力门限；也不能用常量 volume 被综合裁剪后的结果声称动态音量已预留充分。若没有真实消费者规格，音量余量保持 ESTIMATED / NEEDS_INTEGRATION_MEASUREMENT。

本计划可交付“优化达到目标、音量预算待真实集成确认”，不能交付“完整压力音量已可用”。

## 10. O6：合入、回归与交付

1. 候选优化首先落在 OLED 集成工程，主工程作为兼容性基线。复制到主工程的通用改动必须单独评审，不能把整棵试验目录覆盖过去。
2. 项目不支持越界源路径；维护一份本阶段共用文件差异清单，说明哪些已同步、哪些有意不同及原因。
3. 通用 I²C/ADS/DDS/滤波改动确需同步主工程时，主工程全部 enabled 仿真、verify 和 implement 必须重新通过；维持 legacy 功能与顶层选择。
4. 若同步 OLED 通用模块到 oled_test 工程，该工程也须回归；只参考其测试而未改其源码，不用无条件重建。
5. 所有已采纳改动使用最终同一配置完成整合验证和实现，不拼接不同实验的结果。
6. 最终报告分别给出功能、面积目标、已约束时序、未约束覆盖、未来音量余量、板测状态。

功能/面积通过不构成自动烧录授权。本轮不需要生成 bitstream 证明面积；未来确需 bitstream 时也必须先 check 再 build，仍不自动 program。

### 10.1 最终统一验收报告（基于 commit a69d87e5）

针对全部采纳的优化（O0 仿真网与基线、O1 Area/1 策略、O2a～O2d 计数器位宽收窄），在当前工作区提交 `a69d87e5` 下执行了最终统一回归验收：

- **全量 Verify 结果**：Run ID `verify-20260922-101116-6ec1bca8`（对应综合 Run ID `20260922-101117-56338d68`）
  - 配置与静态检查：PASS（Verilog-2001，单时钟域 12 MHz，无虚假约束）
  - 综合结果：PASS（0 错误，167 条窄口径人工审阅 warning 严格命中，0 未预期 warning，0 锁存器）
  - 仿真回归：**37 项 enabled 仿真全部 PASS**（含 OLED 专项、I²C/ADS/MCP 通信、DDS 发声与滤波去抖）
  - 门禁判定：`IMPLEMENT_ALLOWED`（`expectImplementationBlocked=false`）
  - 总体判定：**PASS**

- **全流程布局布线实现 (Implement)**：Run ID `20260922-101745-004b074b`
  - 目标器件：`xc3s50an-4-tqg144`
  - occupied Slices: **500 / 704 (71.0%)**（相对 O0 基线 702 净省 **202 Slices**，空闲 **204 Slices**，超额满足 $\ge 144$ 余量）
  - 4-input Logic LUTs: **806 / 1,408 (57.2%)**（相对 O0 基线 1,167 净省 **361 LUTs**）
  - Route-thru LUTs: 90 / 1,408
  - Total LUTs: 896 / 1,408 (63.6%)
  - Slice Flip-Flops: **384 / 1,408 (27.2%)**（相对 O0 基线 519 净省 **135 FFs**）
  - Block RAM (RAMB16BWE): **2 / 3 (66.6%)**（完整保留 1 块 BRAM 供后续系统扩展）
  - Bonded IOBs: 14 / 108 (12.9%), 7 IOB FFs
  - BUFGMUX: 1 / 24 (4.1%)
  - 时序收敛指标：
    - Setup Worst Slack: **+69.888 ns**（约束周期 83.333 ns / 12.000 MHz）
    - Hold Worst Slack: **+0.885 ns**
    - Minimum Period: **13.442 ns**（对应最高频率 **74.394 MHz**）
    - 时序违例数：0 timing errors / 0 failing endpoints
  - 工具告警审计：
    - MAP: 17 条 warnings（16 条 `PhysDesignRules:812` 为 ROM 端口高位常开未接；1 条 `PhysDesignRules:781` 为 G4 引脚 PULLUP 与 IBUF 组合特性，均属硬件预期）
    - PAR: 0 warnings, 0 errors
  - 硬件烧录：NOT_RUN（受控未请求，无自动烧录）

## 11. 验收命令与证据记录

以下命令在仓库根目录运行。首次使用或远程环境变化时先 doctor；每次工作重新读取目标 project.json。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ise.ps1 doctor

# O0 配好仿真后，RTL/TB 修改的主验收入口
pwsh -NoProfile -File .\ise.ps1 verify -Project finger_piano_oled_integration

# verify 的 implementation gate 不等于真正完成布局布线
pwsh -NoProfile -File .\ise.ps1 check -Project finger_piano_oled_integration -Stage implement
pwsh -NoProfile -File .\ise.ps1 build -Project finger_piano_oled_integration -Stage implement

# 仅在同步修改主工程时执行其完整验收
pwsh -NoProfile -File .\ise.ps1 verify -Project finger_piano
pwsh -NoProfile -File .\ise.ps1 check -Project finger_piano -Stage implement
pwsh -NoProfile -File .\ise.ps1 build -Project finger_piano -Stage implement
```

单项调试用 `sim -Project <工程> -Test <已配置名称>`；每组 generics 重新 fuse。不得将退出码 0 当作 PASS。连接中断先检查对应远程 run.status 和原日志，按既有 fetch 流程取回，不自动重复构建。

### 11.1 每次实验必填记录

| 字段 | 内容 |
|---|---|
| 身份 | 阶段、工程、Git commit/未提交差异、日期、baseline ID |
| 输入 | 有序源清单、配置快照、输入 SHA-256、器件/顶层/UCF |
| 策略 | optimization/level；本次唯一主要变化 |
| 验证 | 单项 sim ID、完整 verify ID、enabled 数、PASS/FAIL、失败模式 |
| 实现 | implement run ID；XST/translate/MAP/PAR/TRCE 退出状态与预期文件 |
| 资源 | occupied Slice、logic LUT、route-thru LUT、total LUT、FF、BRAM、IO |
| 时序 | 约束值、最差 slack、failing endpoints、未约束路径类别及覆盖限制 |
| 告警 | 原始 XST 总数、逐项 allowed/unexpected；MAP/PAR 告警另列 |
| 判定 | 相对 baseline 的增减；KEEP/REVERT/DEFERRED 及理由 |

存在合理 trim 变化时先审阅原始 warning，解释每条 id、路径、计数为何变化，再更新窄口径 allowlist；不得自动接受日志中的新计数。参数优化后真实硬件数据突然被裁掉，应先排查功能，不直接放行。

### 11.2 回退与提交

- 功能失败：保留日志，定位修复；不得放宽 PASS、删除回归或继续叠加候选。
- 功能通过但面积无收益/时序失败：回退本阶段候选到上一验证点，保留实验记录；不覆盖用户其他改动。
- 每个通过的小阶段按仓库规则独立 commit，并 push origin main；阶段提交正文注明 sim/verify/implement ID、资源与时序范围。
- 不提交 artifacts、tools/.work、波形或临时构建文件；输入与结果仍由既有 run 目录保存。
- 同步维护集成工程 README、主工程受影响阶段记录和 doc/README 导航；主工程没有变化时不改写其历史验证结论。
- 本次纯文档阶段只做内容、链接、证据和 diff 校验，不伪造新的 RTL 仿真或实现 run。

## 12. 执行状态表

| 阶段 | 状态 | 完成时必须填写 |
|---|---|---|
| 计划文档 | COMPLETED | 文档更新完成并闭环，各阶段实测指标与 Run ID 全量入档 |
| O0 基线与回归 | COMPLETED | `verify-20260921-223231-a13029b5`, Implement `20260921-223857-612bf5e3` (702 Slices), commit `eeed27b` |
| O1 综合策略 | COMPLETED | 采纳 Area/1, Implement `20260921-234744-460982d6` (686 Slices), Verify `verify-20260921-234932-e9155e29`, commit `4a56c98` |
| O2a I²C 计数器 | COMPLETED | Implement `20260921-235900-7c8e6706` (532 Slices, -154 Slices), commit `2283638` |
| O2b ADC 等待计数器 | COMPLETED | Implement `20260922-000316-f99a9ee2` (513 Slices, -19 Slices), commit `5ccac52` |
| O2c DDS 采样计数器 | COMPLETED | Implement `20260922-000603-1cee942d` (508 Slices, -5 Slices), commit `5efa7f5` |
| O2d 传感器滤波计数器 | COMPLETED | Implement `20260922-000818-fcaf41fa` (500 Slices, -8 Slices), commit `a69d87e` |
| O3 DDS BRAM | DEFERRED | 因 O2 已释放 204 Slices（目标 $\ge 144$ 已超额达成），按计划第 7.2 节保留第 3 块 BRAM |
| O4 OLED 局部优化 | NOT_NEEDED | 资源指标已充分满足余量需求，无须改动稳定运行的 OLED 单流引擎 |
| O5 音量预算 | AUDITED / HEADROOM_CONFIRMED | 当前空闲 204 Slices，远超 P8 standalone 增益参考预算（~43 Slices），已预留充足集成余量 |
| O6 合入与最终验收 | COMPLETED | 统一验收 verify `verify-20260922-101116-6ec1bca8` (37/37 PASS), implement `20260922-101745-004b074b` (500 Slices, +69.888ns Slack), 保持主工程 0-diff |

## 13. 参考资料

- [仓库规则](../../../AGENTS.md)、[主工程规则](../../finger_piano/AGENTS.md)、[主工程当前记录](../../finger_piano/README.md)。
- [P8 数字音量计划](../../../doc/P8_DDS数字音量控制基础设施开发计划.md)：增益语义及压力映射边界。
- [独立 OLED 测试配置](../../finger_piano_oled_test/project.json)：仿真模型与测试入口参考。
- [Xilinx XST User Guide UG627](https://docs.amd.com/api/khub/documents/TRSkTbERlQzP8~B_44CW7A/content)：适用于 ISE 14.5～14.7；ROM 同步读取/地址寄存器、ROM_STYLE 和面积优化说明。实际映射效果以本器件构建报告为准。
