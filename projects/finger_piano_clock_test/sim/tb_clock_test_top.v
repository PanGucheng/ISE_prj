//=============================================================================
// tb_clock_test_top.v — finger_piano P7 诊断顶层的分频行为仿真
//
// 验证(计划 §9/§10):
//   - 复位:三个输出 == 0,内部 counter == 0;
//   - 2 MHz   :相邻翻转严格相隔 3 个 clk,完整周期 6 个 clk;
//   - 100 kHz :相邻翻转 60 个 clk,完整周期 120 个 clk;
//   - 1 kHz   :相邻翻转 6000 个 clk,完整周期 12000 个 clk;
//   - 复位再次拉低 -> 三个输出回 0;释放后从完整半周期重新开始。
//
// 判据是"clk 拍数",与 TB 时钟频率无关;这里用与板上一致的 12 MHz 节拍。
// 诊断文本全 ASCII。判定行:TB_CLOCK_TEST_TOP: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_clock_test_top;

    parameter integer TARGET_EDGES = 10;   // 每路至少观测的翻转/上升沿数

    reg  clk;
    reg  rst_n;
    wire ref_2mhz;
    wire ref_100khz;
    wire ref_1khz;

    clock_test_top u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .ref_2mhz   (ref_2mhz),
        .ref_100khz (ref_100khz),
        .ref_1khz   (ref_1khz)
    );

    // 真实 12 MHz 节拍(周期 83.334 ns)
    initial clk = 1'b0;
    always #41.667 clk = ~clk;

    integer checks;
    integer errors;
    integer g;

    //-------------------------------------------------------------------------
    // 边沿间隔监视:每个 posedge clk 采样一次,记录相邻翻转/上升沿的 clk 拍数
    // (输出在 clk 沿更新,采样落后 1 拍,但相邻间隔的差值不变)
    //-------------------------------------------------------------------------
    integer cyc;
    reg     p2, p100, p1;
    integer last2, last100, last1;     // 上次翻转时的 cyc(-1 = 尚未记录)
    integer rise2, rise100, rise1;     // 上次上升沿时的 cyc(-1 = 尚未记录)
    integer bad2, bad100, bad1;        // 半周期异常计数
    integer badp2, badp100, badp1;     // 完整周期异常计数
    integer cnt2, cnt100, cnt1;        // 翻转次数

    always @(posedge clk) begin
        if (!rst_n) begin
            cyc   <= 0;
            p2    <= 1'b0;
            p100  <= 1'b0;
            p1    <= 1'b0;
            last2 <= -1;
            last100 <= -1;
            last1 <= -1;
            rise2 <= -1;
            rise100 <= -1;
            rise1 <= -1;
            bad2  <= 0;
            bad100 <= 0;
            bad1  <= 0;
            badp2 <= 0;
            badp100 <= 0;
            badp1 <= 0;
            cnt2  <= 0;
            cnt100 <= 0;
            cnt1  <= 0;
        end else begin
            cyc <= cyc + 1;

            //--- 2 MHz:半周期 3,完整周期 6 --------------------------------
            if (ref_2mhz !== p2) begin
                cnt2 <= cnt2 + 1;
                if (last2 >= 0) begin
                    if ((cyc - last2) !== 3) bad2 <= bad2 + 1;
                end
                last2 <= cyc;
                p2    <= ref_2mhz;
                if (ref_2mhz === 1'b1) begin
                    if (rise2 >= 0) begin
                        if ((cyc - rise2) !== 6) badp2 <= badp2 + 1;
                    end
                    rise2 <= cyc;
                end
            end

            //--- 100 kHz:半周期 60,完整周期 120 ---------------------------
            if (ref_100khz !== p100) begin
                cnt100 <= cnt100 + 1;
                if (last100 >= 0) begin
                    if ((cyc - last100) !== 60) bad100 <= bad100 + 1;
                end
                last100 <= cyc;
                p100    <= ref_100khz;
                if (ref_100khz === 1'b1) begin
                    if (rise100 >= 0) begin
                        if ((cyc - rise100) !== 120) badp100 <= badp100 + 1;
                    end
                    rise100 <= cyc;
                end
            end

            //--- 1 kHz:半周期 6000,完整周期 12000 -------------------------
            if (ref_1khz !== p1) begin
                cnt1 <= cnt1 + 1;
                if (last1 >= 0) begin
                    if ((cyc - last1) !== 6000) bad1 <= bad1 + 1;
                end
                last1 <= cyc;
                p1    <= ref_1khz;
                if (ref_1khz === 1'b1) begin
                    if (rise1 >= 0) begin
                        if ((cyc - rise1) !== 12000) badp1 <= badp1 + 1;
                    end
                    rise1 <= cyc;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 检查任务
    //-------------------------------------------------------------------------
    task check_eq32;
        input integer    got;
        input integer    exp;
        input [8*60-1:0] label;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s: got %0d expected %0d", label, got, exp);
            end else begin
                $display("  ok: %0s (%0d)", label, got);
            end
        end
    endtask

    task check_true;
        input            cond;
        input [8*60-1:0] label;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end else begin
                $display("  ok: %0s", label);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        checks = 0;
        errors = 0;
        g      = 0;

        $display("TB_CLOCK_TEST_TOP: start (12 MHz, target edges=%0d)", TARGET_EDGES);

        rst_n = 1'b0;
        repeat (40) @(posedge clk);

        //---------------------------------------------------------------------
        // reset:三个输出与全部 counter 归 0
        //---------------------------------------------------------------------
        check_eq32(ref_2mhz,   0, "reset: ref_2mhz == 0");
        check_eq32(ref_100khz, 0, "reset: ref_100khz == 0");
        check_eq32(ref_1khz,   0, "reset: ref_1khz == 0");
        check_eq32(u_dut.cnt_2mhz,   0, "reset: cnt_2mhz == 0");
        check_eq32(u_dut.cnt_100khz, 0, "reset: cnt_100khz == 0");
        check_eq32(u_dut.cnt_1khz,   0, "reset: cnt_1khz == 0");

        @(negedge clk);
        rst_n = 1'b1;
        $display("  info: reset released");

        //---------------------------------------------------------------------
        // 收集各路翻转/上升沿间隔
        //---------------------------------------------------------------------
        g = 0;
        while (((cnt2 < TARGET_EDGES) || (cnt100 < TARGET_EDGES) || (cnt1 < TARGET_EDGES)) && (g < 400000)) begin
            @(posedge clk);
            g = g + 1;
        end

        check_true(cnt2   >= TARGET_EDGES, "2 MHz produced enough toggles");
        check_true(cnt100 >= TARGET_EDGES, "100 kHz produced enough toggles");
        check_true(cnt1   >= TARGET_EDGES, "1 kHz produced enough toggles");

        check_eq32(bad2,   0, "2 MHz half period == 3 clk");
        check_eq32(bad100, 0, "100 kHz half period == 60 clk");
        check_eq32(bad1,   0, "1 kHz half period == 6000 clk");
        check_eq32(badp2,   0, "2 MHz full period == 6 clk");
        check_eq32(badp100, 0, "100 kHz full period == 120 clk");
        check_eq32(badp1,   0, "1 kHz full period == 12000 clk");

        //---------------------------------------------------------------------
        // 运行中再次拉低复位:输出强制 0,计数清零
        //---------------------------------------------------------------------
        @(negedge clk);
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        check_eq32(ref_2mhz,   0, "re-reset: ref_2mhz == 0");
        check_eq32(ref_100khz, 0, "re-reset: ref_100khz == 0");
        check_eq32(ref_1khz,   0, "re-reset: ref_1khz == 0");
        check_eq32(u_dut.cnt_1khz, 0, "re-reset: cnt_1khz == 0");

        //---------------------------------------------------------------------
        // 释放后从完整半周期重新开始
        //---------------------------------------------------------------------
        @(negedge clk);
        rst_n = 1'b1;
        g = 0;
        while ((cnt1 < TARGET_EDGES) && (g < 400000)) begin
            @(posedge clk);
            g = g + 1;
        end
        check_true(cnt1 >= TARGET_EDGES, "1 kHz restarts after reset release");
        check_eq32(bad2,   0, "post-reset: 2 MHz half period == 3 clk");
        check_eq32(bad100, 0, "post-reset: 100 kHz half period == 60 clk");
        check_eq32(bad1,   0, "post-reset: 1 kHz half period == 6000 clk");

        $display("TB_CLOCK_TEST_TOP: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) begin
            $display("TB_CLOCK_TEST_TOP: PASS");
        end else begin
            $display("TB_CLOCK_TEST_TOP: FAIL");
        end
        $finish;
    end

endmodule
