//=============================================================================
// tb_od_test_top.v
// finger_piano_od_test -- P31/P32 开漏 IO 诊断工程 testbench。
//
// 验证目标(全部为自动判定,判据是日志里的 PASS/FAIL 行):
//   1) 上电后两路都处于释放态(Z),不主动驱动任何电平;
//   2) P31 拉低/释放半周期各约 500 us -> 约 1 kHz;
//   3) P32 拉低/释放半周期各约 250 us -> 约 2 kHz;
//   4) 占空比约 50%(拉低与释放时长一致);
//   5) **任何时刻输出只能是 0 或 Z,绝不允许出现逻辑 1**(连续逐 clk 监视);
//   6) P32 周期是 P31 周期的一半(2 kHz = 2 x 1 kHz)。
//
// 板上模型:TB 不给 DUT 引脚加内部上拉(DUT 的 z 必须能被观察到),而是用
//   bus = (line === 1'bz) ? 1'b1 : line
// 模拟"外部 4.7 kΩ 上拉到 3.3 V 之后"的电压;严格性检查仍检查原始 line
// 只有 0 / Z,因此如果 DUT 推挽驱动 1,line 会是 1 -> 直接判违规。
//
// 诊断文本一律 ASCII(Win7 ISim 代码页限制)。
//=============================================================================

`timescale 1ns/1ps

`include "od_test_cfg.vh"

module tb_od_test_top;

    localparam integer SYS_CLK_HZ = `OD_SYS_CLK_HZ;
    localparam integer P31_HZ     = `OD_P31_HZ;
    localparam integer P32_HZ     = `OD_P32_HZ;

    integer errors;

    //-------------------------------------------------------------------------
    // 12 MHz 系统时钟(半周期 41.6667 ns)
    //-------------------------------------------------------------------------
    reg  clk;
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
    // DUT:引脚接到 tri 线,不加任何上拉,便于观察原始 0/Z
    //-------------------------------------------------------------------------
    wire p31_line;
    wire p32_line;

    od_test_top #(
        .SYS_CLK_HZ (SYS_CLK_HZ),
        .P31_HZ     (P31_HZ),
        .P32_HZ     (P32_HZ)
    ) dut (
        .clk      (clk),
        .p31_test (p31_line),
        .p32_test (p32_line)
    );

    // 外部上拉后的板级电压模型(z -> 1),仅用于测频/测周期
    wire p31_bus = (p31_line === 1'bz) ? 1'b1 : p31_line;
    wire p32_bus = (p32_line === 1'bz) ? 1'b1 : p32_line;

    //-------------------------------------------------------------------------
    // 严格性监视:逐 clk 检查 line 只能是 0 或 Z
    //-------------------------------------------------------------------------
    integer p31_violations;
    integer p32_violations;
    integer p31_low_samples;
    integer p31_z_samples;
    integer p32_low_samples;
    integer p32_z_samples;

    initial begin
        p31_violations = 0;
        p32_violations = 0;
        p31_low_samples = 0;
        p31_z_samples   = 0;
        p32_low_samples = 0;
        p32_z_samples   = 0;
    end

    always @(posedge clk) begin
        #1;   // 等 DUT 的非阻塞更新与连续赋值稳定后再采样
        if (p31_line !== 1'b0 && p31_line !== 1'bz) p31_violations = p31_violations + 1;
        if (p31_line === 1'b0)  p31_low_samples = p31_low_samples + 1;
        if (p31_line === 1'bz)  p31_z_samples   = p31_z_samples   + 1;

        if (p32_line !== 1'b0 && p32_line !== 1'bz) p32_violations = p32_violations + 1;
        if (p32_line === 1'b0)  p32_low_samples = p32_low_samples + 1;
        if (p32_line === 1'bz)  p32_z_samples   = p32_z_samples   + 1;
    end

    //-------------------------------------------------------------------------
    // 测量与判定
    //-------------------------------------------------------------------------
    real t0;
    real p31_low_ns, p31_high_ns, p32_low_ns, p32_high_ns;
    real p31_period_ns, p32_period_ns;
    real f31_hz, f32_hz;
    real duty31, duty32;

    initial begin
        errors = 0;
        $display("TB_OD_TEST_TOP: start SYS_CLK_HZ=%0d P31_HZ=%0d P32_HZ=%0d", SYS_CLK_HZ, P31_HZ, P32_HZ);

        // 1) 上电释放态
        #10;
        if (p31_line !== 1'bz) begin
            $display("TB_OD_TEST_TOP: ERROR p31 not released (Z) at power-up: line=%b", p31_line);
            errors = errors + 1;
        end
        if (p32_line !== 1'bz) begin
            $display("TB_OD_TEST_TOP: ERROR p32 not released (Z) at power-up: line=%b", p32_line);
            errors = errors + 1;
        end

        // 2) P31:测一个完整周期(拉低 + 释放)
        @(negedge p31_bus);
        t0 = $realtime;
        @(posedge p31_bus);
        p31_low_ns = $realtime - t0;
        @(negedge p31_bus);
        p31_high_ns = $realtime - t0 - p31_low_ns;
        p31_period_ns = p31_low_ns + p31_high_ns;

        // 3) P32:测一个完整周期
        @(negedge p32_bus);
        t0 = $realtime;
        @(posedge p32_bus);
        p32_low_ns = $realtime - t0;
        @(negedge p32_bus);
        p32_high_ns = $realtime - t0 - p32_low_ns;
        p32_period_ns = p32_low_ns + p32_high_ns;

        f31_hz = 1.0e9 / p31_period_ns;
        f32_hz = 1.0e9 / p32_period_ns;
        duty31 = p31_low_ns / p31_period_ns;
        duty32 = p32_low_ns / p32_period_ns;

        $display("TB_OD_TEST_TOP: p31 low=%f ns high=%f ns period=%f ns -> f=%f Hz duty=%f",
                 p31_low_ns, p31_high_ns, p31_period_ns, f31_hz, duty31);
        $display("TB_OD_TEST_TOP: p32 low=%f ns high=%f ns period=%f ns -> f=%f Hz duty=%f",
                 p32_low_ns, p32_high_ns, p32_period_ns, f32_hz, duty32);

        // 4) 频率约 1 kHz / 2 kHz(±2%)
        if (f31_hz < (P31_HZ * 0.98) || f31_hz > (P31_HZ * 1.02)) begin
            $display("TB_OD_TEST_TOP: ERROR p31 frequency out of range: %f Hz", f31_hz);
            errors = errors + 1;
        end
        if (f32_hz < (P32_HZ * 0.98) || f32_hz > (P32_HZ * 1.02)) begin
            $display("TB_OD_TEST_TOP: ERROR p32 frequency out of range: %f Hz", f32_hz);
            errors = errors + 1;
        end

        // 5) 占空比 50%(±5 个百分点)
        if (duty31 < 0.45 || duty31 > 0.55) begin
            $display("TB_OD_TEST_TOP: ERROR p31 duty out of range: %f", duty31);
            errors = errors + 1;
        end
        if (duty32 < 0.45 || duty32 > 0.55) begin
            $display("TB_OD_TEST_TOP: ERROR p32 duty out of range: %f", duty32);
            errors = errors + 1;
        end

        // 6) P32 周期是 P31 的一半(±2%)
        if (p32_period_ns < (p31_period_ns * 0.49) || p32_period_ns > (p31_period_ns * 0.51)) begin
            $display("TB_OD_TEST_TOP: ERROR period ratio p31/p32 != 2 (p31=%f ns p32=%f ns)",
                     p31_period_ns, p32_period_ns);
            errors = errors + 1;
        end

        // 7) 严格 0/Z:从未出现 1(或 x)
        if (p31_violations != 0) begin
            $display("TB_OD_TEST_TOP: ERROR p31 drove a non-0/Z level in %0d sample(s)", p31_violations);
            errors = errors + 1;
        end
        if (p32_violations != 0) begin
            $display("TB_OD_TEST_TOP: ERROR p32 drove a non-0/Z level in %0d sample(s)", p32_violations);
            errors = errors + 1;
        end

        // 8) 观察到两种状态:确实拉低过、也确实释放过
        if (p31_low_samples == 0 || p31_z_samples == 0) begin
            $display("TB_OD_TEST_TOP: ERROR p31 never exercised both states (low=%0d z=%0d)",
                     p31_low_samples, p31_z_samples);
            errors = errors + 1;
        end
        if (p32_low_samples == 0 || p32_z_samples == 0) begin
            $display("TB_OD_TEST_TOP: ERROR p32 never exercised both states (low=%0d z=%0d)",
                     p32_low_samples, p32_z_samples);
            errors = errors + 1;
        end

        $display("TB_OD_TEST_TOP: p31 samples low=%0d z=%0d violations=%0d",
                 p31_low_samples, p31_z_samples, p31_violations);
        $display("TB_OD_TEST_TOP: p32 samples low=%0d z=%0d violations=%0d",
                 p32_low_samples, p32_z_samples, p32_violations);

        if (errors == 0) begin
            $display("TB_OD_TEST_TOP: PASS");
        end else begin
            $display("TB_OD_TEST_TOP: FAIL (%0d error(s))", errors);
        end

        $finish;
    end

endmodule
