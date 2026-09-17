//=============================================================================
// tb_od_test_top.v
// finger_piano_od_test -- P31/P32 开漏 IO 诊断工程 testbench。
//
// 验证目标(自动判定,判据是日志里的 PASS/FAIL 行):
//   1) 复位期间 phase=0:P31 = Z、P32 = LOW;
//   2) 复位释放后 P31/P32 互补互换,**每个状态严格保持
//      TB_PHASE_HALF_CYC 个 clk**(真实参数 = 12,000,000 clk = 1 秒);
//   3) 任何时刻 P31/P32 都只能是 0 或 Z,绝不出现逻辑 1;
//   4) 任何时刻恰好一路 LOW、另一路 Z(互补);
//   5) 两路都确实出现过 0 和 Z 两种状态。
//
// 测频/测距方式:TB 用 `always @(posedge clk) clk_edges = clk_edges + 1`
// 累计 clk 沿,在 P31 的 Z->LOW / LOW->Z 跳变处记录 clk_edges,于是
// 两个跳变之间的差值就是一个状态持续的真实 clk 拍数(精确到拍)。
//
// TB 不给 DUT 引脚加任何上拉(DUT 的 z 必须能被观察到);严格性检查基于
// 原始 line。诊断文本一律 ASCII(Win7 ISim 代码页限制)。
//=============================================================================

`timescale 1ns/1ps

`include "od_test_cfg.vh"

module tb_od_test_top;

    parameter integer TB_PHASE_HALF_CYC = `OD_PHASE_HALF_CYC;

    localparam integer SYS_CLK_HZ = `OD_SYS_CLK_HZ;

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

    od_test_top #(
        .SYS_CLK_HZ     (SYS_CLK_HZ),
        .PHASE_HALF_CYC (TB_PHASE_HALF_CYC)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .p31_test (p31_line),
        .p32_test (p32_line)
    );

    //-------------------------------------------------------------------------
    // clk 沿计数 + 严格性/互补监视
    //-------------------------------------------------------------------------
    integer clk_edges;
    integer p31_violations;
    integer p32_violations;
    integer p31_low_samples;
    integer p31_z_samples;
    integer p32_low_samples;
    integer p32_z_samples;
    integer complement_violations;

    initial begin
        clk_edges              = 0;
        p31_violations         = 0;
        p32_violations         = 0;
        p31_low_samples        = 0;
        p31_z_samples          = 0;
        p32_low_samples        = 0;
        p32_z_samples          = 0;
        complement_violations  = 0;
    end

    always @(posedge clk) clk_edges = clk_edges + 1;

    always @(posedge clk) begin
        #1;   // 等 DUT 的非阻塞更新与连续赋值稳定后再采样
        if (p31_line !== 1'b0 && p31_line !== 1'bz) p31_violations = p31_violations + 1;
        if (p32_line !== 1'b0 && p32_line !== 1'bz) p32_violations = p32_violations + 1;
        if (p31_line === 1'b0) p31_low_samples = p31_low_samples + 1;
        if (p31_line === 1'bz) p31_z_samples   = p31_z_samples   + 1;
        if (p32_line === 1'b0) p32_low_samples = p32_low_samples + 1;
        if (p32_line === 1'bz) p32_z_samples   = p32_z_samples   + 1;

        if (!((p31_line === 1'b0 && p32_line === 1'bz) ||
              (p31_line === 1'bz && p32_line === 1'b0))) begin
            complement_violations = complement_violations + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 相位宽度测量(跳变到跳变,精确 clk 拍数)
    //-------------------------------------------------------------------------
    integer last_z_edge;
    integer last_low_edge;
    integer z_width;      // P31 处于 Z 的 clk 拍数(phase 0 长度)
    integer low_width;    // P31 处于 LOW 的 clk 拍数(phase 1 长度)
    integer transitions;
    reg     p31_prev;

    initial begin
        last_z_edge   = 0;
        last_low_edge = 0;
        z_width       = -1;
        low_width     = -1;
        transitions   = 0;
        p31_prev      = 1'bz;
    end

    always @(posedge clk) begin
        #1;
        if (p31_prev === 1'bz && p31_line === 1'b0) begin
            // Z -> LOW:phase 变成 1
            if (last_z_edge != 0) z_width = clk_edges - last_z_edge;
            last_low_edge = clk_edges;
            transitions   = transitions + 1;
        end else if (p31_prev === 1'b0 && p31_line === 1'bz) begin
            // LOW -> Z:phase 变成 0
            if (last_low_edge != 0) low_width = clk_edges - last_low_edge;
            last_z_edge = clk_edges;
        end
        p31_prev = p31_line;
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        errors = 0;
        rst_n  = 1'b0;

        $display("TB_OD_TEST_TOP: start SYS_CLK_HZ=%0d PHASE_HALF_CYC=%0d",
                 SYS_CLK_HZ, TB_PHASE_HALF_CYC);

        // 1) 复位期间:phase=0
        repeat (20) @(posedge clk);
        #1;
        if (p31_line !== 1'bz) begin
            $display("TB_OD_TEST_TOP: ERROR p31 is not Z during reset: line=%b", p31_line);
            errors = errors + 1;
        end
        if (p32_line !== 1'b0) begin
            $display("TB_OD_TEST_TOP: ERROR p32 is not LOW during reset: line=%b", p32_line);
            errors = errors + 1;
        end

        // 2) 释放复位,等待两次状态互换(拿到两个方向的完整宽度)
        @(negedge clk);
        rst_n = 1'b1;

        while ((z_width < 0) || (low_width < 0)) @(posedge clk);
        #1;

        $display("TB_OD_TEST_TOP: p31 z_width=%0d clk, low_width=%0d clk, transitions=%0d",
                 z_width, low_width, transitions);
        $display("TB_OD_TEST_TOP: samples p31 low=%0d z=%0d | p32 low=%0d z=%0d",
                 p31_low_samples, p31_z_samples, p32_low_samples, p32_z_samples);

        // 3) 每个状态严格等于 TB_PHASE_HALF_CYC 个 clk
        if (z_width != TB_PHASE_HALF_CYC) begin
            $display("TB_OD_TEST_TOP: ERROR p31 Z width %0d != %0d clk", z_width, TB_PHASE_HALF_CYC);
            errors = errors + 1;
        end
        if (low_width != TB_PHASE_HALF_CYC) begin
            $display("TB_OD_TEST_TOP: ERROR p31 LOW width %0d != %0d clk", low_width, TB_PHASE_HALF_CYC);
            errors = errors + 1;
        end

        // 4) 严格 0 / Z
        if (p31_violations != 0) begin
            $display("TB_OD_TEST_TOP: ERROR p31 drove a non-0/Z level in %0d sample(s)", p31_violations);
            errors = errors + 1;
        end
        if (p32_violations != 0) begin
            $display("TB_OD_TEST_TOP: ERROR p32 drove a non-0/Z level in %0d sample(s)", p32_violations);
            errors = errors + 1;
        end

        // 5) 互补
        if (complement_violations != 0) begin
            $display("TB_OD_TEST_TOP: ERROR p31/p32 not complementary in %0d sample(s)", complement_violations);
            errors = errors + 1;
        end

        // 6) 两种状态都出现过
        if (p31_low_samples == 0 || p31_z_samples == 0) begin
            $display("TB_OD_TEST_TOP: ERROR p31 never exercised both states");
            errors = errors + 1;
        end
        if (p32_low_samples == 0 || p32_z_samples == 0) begin
            $display("TB_OD_TEST_TOP: ERROR p32 never exercised both states");
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
