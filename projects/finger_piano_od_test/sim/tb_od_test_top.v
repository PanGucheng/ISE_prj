//=============================================================================
// tb_od_test_top.v
// finger_piano_od_test -- P31/P32/P110 推挽方波 testbench。
//
// 验证目标(自动判定,判据是日志里的 PASS/FAIL 行):
//   1) 复位期间三个输出都为 0(确定初值);
//   2) 三个脚**同相位、同值**:任何时刻 p31 == p32 == p110;
//   3) 任何时刻三个脚都只能是 0 或 1(推挽,不允许 Z/X);
//   4) 半周期严格等于 SYS_CLK_HZ/(2*TONE_HZ) 个 clk,高/低相等(50%);
//   5) 实测周期换算出的频率 == TONE_HZ(例如 1 kHz);
//   6) 高、低两种状态都确实出现过。
//
// 测周期方式:TB 用 `always @(posedge clk) clk_edges = clk_edges + 1` 累计
// clk 沿,在 p31 的 0->1 / 1->0 跳变处记录沿号,相邻跳变之差就是一个半周期
// 的真实 clk 拍数(精确到拍)。
//
// 诊断文本一律 ASCII(Win7 ISim 代码页限制)。
//=============================================================================

`timescale 1ns/1ps

`include "od_test_cfg.vh"

module tb_od_test_top;

    parameter integer TB_TONE_HZ = `OD_TONE_HZ;

    localparam integer SYS_CLK_HZ = `OD_SYS_CLK_HZ;
    localparam integer HALF       = SYS_CLK_HZ / (2 * TB_TONE_HZ);

    integer errors;

    //-------------------------------------------------------------------------
    // 12 MHz 系统时钟(半周期 41.6667 ns)
    //-------------------------------------------------------------------------
    reg  clk;
    reg  rst_n;
    real clk_half_ns;

    initial begin
        clk         = 1'b0;
        clk_half_ns = 500.0 / (SYS_CLK_HZ / 1000000.0);
        forever begin
            #(clk_half_ns);
            clk = ~clk;
        end
    end

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    wire p31_line;
    wire p32_line;
    wire p110_line;

    od_test_top #(
        .SYS_CLK_HZ (SYS_CLK_HZ),
        .TONE_HZ    (TB_TONE_HZ)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .p31_test  (p31_line),
        .p32_test  (p32_line),
        .p110_test (p110_line)
    );

    //-------------------------------------------------------------------------
    // clk 沿计数 + 严格性/同相位监视
    //-------------------------------------------------------------------------
    integer clk_edges;
    integer level_violations;    // 出现 0/1 之外的电平
    integer phase_violations;    // 三个脚不同值
    integer high_samples;
    integer low_samples;

    initial begin
        clk_edges        = 0;
        level_violations = 0;
        phase_violations = 0;
        high_samples     = 0;
        low_samples      = 0;
    end

    always @(posedge clk) clk_edges = clk_edges + 1;

    always @(posedge clk) begin
        #1;   // 等 DUT 的非阻塞更新与连续赋值稳定后再采样
        if (p31_line !== 1'b0 && p31_line !== 1'b1) level_violations = level_violations + 1;
        if (p32_line !== 1'b0 && p32_line !== 1'b1) level_violations = level_violations + 1;
        if (p110_line !== 1'b0 && p110_line !== 1'b1) level_violations = level_violations + 1;

        if (!((p31_line === p32_line) && (p32_line === p110_line))) begin
            phase_violations = phase_violations + 1;
        end

        if (p31_line === 1'b1) high_samples = high_samples + 1;
        if (p31_line === 1'b0) low_samples  = low_samples  + 1;
    end

    //-------------------------------------------------------------------------
    // 半周期测量(跳变到跳变,精确 clk 拍数)
    //-------------------------------------------------------------------------
    integer last_rise;
    integer last_fall;
    integer high_width;
    integer low_width;
    integer transitions;
    reg     p31_prev;

    initial begin
        last_rise   = 0;
        last_fall   = 0;
        high_width  = -1;
        low_width   = -1;
        transitions = 0;
        p31_prev    = 1'b0;
    end

    always @(posedge clk) begin
        #1;
        if (p31_prev === 1'b0 && p31_line === 1'b1) begin
            // 0 -> 1:上一个低电平持续 = 现在 - 上次下降
            if (last_fall != 0) low_width = clk_edges - last_fall;
            last_rise   = clk_edges;
            transitions = transitions + 1;
        end else if (p31_prev === 1'b1 && p31_line === 1'b0) begin
            // 1 -> 0:上一个高电平持续 = 现在 - 上次上升
            if (last_rise != 0) high_width = clk_edges - last_rise;
            last_fall = clk_edges;
        end
        p31_prev = p31_line;
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    real period_ns;
    real f_hz;

    initial begin
        errors = 0;
        rst_n  = 1'b0;

        $display("TB_OD_TEST_TOP: start SYS_CLK_HZ=%0d TONE_HZ=%0d HALF=%0d clk",
                 SYS_CLK_HZ, TB_TONE_HZ, HALF);

        // 1) 复位期间:三个输出都应为 0
        repeat (20) @(posedge clk);
        #1;
        if (p31_line !== 1'b0 || p32_line !== 1'b0 || p110_line !== 1'b0) begin
            $display("TB_OD_TEST_TOP: ERROR outputs not all 0 during reset: p31=%b p32=%b p110=%b",
                     p31_line, p32_line, p110_line);
            errors = errors + 1;
        end

        // 2) 释放复位,等两个方向都测到
        @(negedge clk);
        rst_n = 1'b1;

        while ((high_width < 0) || (low_width < 0)) @(posedge clk);
        #1;

        period_ns = (high_width + low_width) * (1000000000.0 / SYS_CLK_HZ);

        $display("TB_OD_TEST_TOP: high_width=%0d clk, low_width=%0d clk, transitions=%0d",
                 high_width, low_width, transitions);
        $display("TB_OD_TEST_TOP: samples high=%0d low=%0d, level_violations=%0d phase_violations=%0d",
                 high_samples, low_samples, level_violations, phase_violations);

        // 3) 半周期严格 = HALF,高/低相等(已在比较中体现 50%)
        if (high_width != HALF) begin
            $display("TB_OD_TEST_TOP: ERROR high width %0d != %0d clk", high_width, HALF);
            errors = errors + 1;
        end
        if (low_width != HALF) begin
            $display("TB_OD_TEST_TOP: ERROR low width %0d != %0d clk", low_width, HALF);
            errors = errors + 1;
        end

        // 4) 频率 == TONE_HZ
        if ((high_width > 0) && (low_width > 0)) begin
            f_hz = 1000000000.0 / period_ns;
            $display("TB_OD_TEST_TOP: measured frequency = %f Hz (target %0d Hz, period %f ns)",
                     f_hz, TB_TONE_HZ, period_ns);
            if (f_hz < (TB_TONE_HZ - 1) || f_hz > (TB_TONE_HZ + 1)) begin
                $display("TB_OD_TEST_TOP: ERROR measured frequency out of range");
                errors = errors + 1;
            end
        end

        // 5) 推挽电平合法性与同相位
        if (level_violations != 0) begin
            $display("TB_OD_TEST_TOP: ERROR non-0/1 level seen in %0d sample(s)", level_violations);
            errors = errors + 1;
        end
        if (phase_violations != 0) begin
            $display("TB_OD_TEST_TOP: ERROR p31/p32/p110 differ in %0d sample(s)", phase_violations);
            errors = errors + 1;
        end

        // 6) 两种状态都出现过
        if (high_samples == 0 || low_samples == 0) begin
            $display("TB_OD_TEST_TOP: ERROR output never exercised both levels");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("TB_OD_TEST_TOP: PASS");
        end else begin
            $display("TB_OD_TEST_TOP: FAIL (%0d error(s))", errors);
        end

        $finish;
    end

endmodule
