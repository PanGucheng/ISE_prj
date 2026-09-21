# finger_piano OLED 集成试验工程

本工程在 `finger_piano_stage2_top` 外增加 SSD1306 显示链，顶层为 `finger_piano_stage2_oled_top`，器件配置为 `xc3s50an-4-tqg144`。主工程及其 legacy 功能保留在 `projects/finger_piano`。

## 开发入口

- [资源优化与音量余量详细计划](docs/resource_optimization_plan.md)：基线证据、O0～O6 阶段、计数器位宽、DDS BRAM、回归矩阵、预算、回退及交付标准。
- [主工程规则](../finger_piano/AGENTS.md)与[仓库规则](../../AGENTS.md)。
- [全局文档入口](../../doc/README.md)。

## 分析时状态（2026-09-21）

构建 `20260921-220404-5bf1a2af` 的 implement 流程完成：MAP 为 702/704 occupied Slices、1167 logic LUT、166 route-thru LUT、519 FF、2/3 BRAM、14 个用户 I/O。

该构建输入 SHA-256 在计划编写时与当前输入一致。已阅读 timing.twr：83.33 ns 时钟约束无失败，最差 setup slack 70.522 ns；仍存在未约束输入/输出和其他路径，不代表完整板级时序或功能通过。MAP 存在 16 条 BRAM 数据输入 dangling pin 告警，不能称实现零告警。

已有 `verify-20260921-220344-887dc140` 为 PASS，但 `simulations` 为空，仿真状态为 NOT_CONFIGURED。资源优化开始前必须按计划 O0 补齐集成回归。

## 本轮文档记录

2026-09-21：新增详细优化计划。状态为 PLANNED；尚未实施计数器、DDS BRAM 或综合配置优化。初步预算为音量接入前 ≤560 Slice、真实压力音量接入后争取 ≤600 Slice，均须后续实测，不能视为保证结果。

本轮仅修改文档和导航，不产生新的 RTL 仿真、构建或硬件写入结果。未来执行优化时在此追加每阶段 run ID、实际收益、时序覆盖及仍未完成的验证。

文档校验：20 个本地引用存在，两个资源基线的输入 SHA-256 匹配；计划 O0～O6 章节、UTF-8 编码、Markdown 代码围栏和 Git diff 检查通过。此结论只针对文档与已有证据，不代表计划已执行。
