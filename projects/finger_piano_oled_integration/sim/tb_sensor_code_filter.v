//=============================================================================
// tb_sensor_code_filter.v — sensor_code_filter 验收(P2 计划 Commit B)
//
// 缩短参数(P2 计划 §19):SYS_CLK_HZ=10000,STABLE_MS=1 ->
// STABLE_CYCLES = (10000/1000)*1 = 10。验证的是数字算法,无需板上 12 MHz。
//
// 覆盖(§18 全表):
//   T1 复位 -> 输出 000
//   T2 000->001   达门限后一次更新(第 9 拍不更新,第 10 拍更新 = off-by-one)
//   T3 001->111   整个码字一次更新(先 011/101 短暂中间码,不允许泄漏)
//   T4 短毛刺     不更新
//   T5 candidate 改变 -> 计数重新开始(9+1+9 组合不更新)
//   T6 回到原 stable 值 -> counter 清零
//   T7 ENABLE=0   纯直通(独立实例,立即跟随)
//
// 全程泄漏监视:每个采样沿检查 code_stable 是否落在当前允许集合内。
// 诊断文本全 ASCII。判定行:TB_SENSOR_CODE_FILTER: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_sensor_code_filter;

    localparam integer N = 10;   // STABLE_CYCLES(由参数推导,勿改)

    reg         clk;
    reg         rst_n;
    reg  [2:0]  code_sync;
    wire [2:0]  code_stable;

    // ENABLE=0 直通实例
    reg  [2:0]  code_sync_bp;
    wire [2:0]  code_stable_bp;

    integer checks;
    integer errors;
    integer leak_cnt;

    sensor_code_filter #(
        .SYS_CLK_HZ (10000),
        .STABLE_MS  (1),
        .ENABLE     (1)
    ) u_dut (
        .clk         (clk),
        .rst_n_sync  (rst_n),
        .code_sync   (code_sync),
        .code_stable (code_stable)
    );

    sensor_code_filter #(
        .SYS_CLK_HZ (10000),
        .STABLE_MS  (1),
        .ENABLE     (0)
    ) u_dut_bp (
        .clk         (clk),
        .rst_n_sync  (rst_n),
        .code_sync   (code_sync_bp),
        .code_stable (code_stable_bp)
    );

    //-------------------------------------------------------------------------
    // 边界矩阵测试实例：覆盖 2 的幂次及其相邻门限值 (N = 7,8,9, 15,16,17, 31,32,33, 63,64,65)
    //-------------------------------------------------------------------------
    reg  [2:0] bm_in;
    wire [2:0] bm_out_7,  bm_out_8,  bm_out_9;
    wire [2:0] bm_out_15, bm_out_16, bm_out_17;
    wire [2:0] bm_out_31, bm_out_32, bm_out_33;
    wire [2:0] bm_out_63, bm_out_64, bm_out_65;

    sensor_code_filter #(.SYS_CLK_HZ(7000),  .STABLE_MS(1)) u_bm_7  (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_7));
    sensor_code_filter #(.SYS_CLK_HZ(8000),  .STABLE_MS(1)) u_bm_8  (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_8));
    sensor_code_filter #(.SYS_CLK_HZ(9000),  .STABLE_MS(1)) u_bm_9  (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_9));
    sensor_code_filter #(.SYS_CLK_HZ(15000), .STABLE_MS(1)) u_bm_15 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_15));
    sensor_code_filter #(.SYS_CLK_HZ(16000), .STABLE_MS(1)) u_bm_16 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_16));
    sensor_code_filter #(.SYS_CLK_HZ(17000), .STABLE_MS(1)) u_bm_17 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_17));
    sensor_code_filter #(.SYS_CLK_HZ(31000), .STABLE_MS(1)) u_bm_31 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_31));
    sensor_code_filter #(.SYS_CLK_HZ(32000), .STABLE_MS(1)) u_bm_32 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_32));
    sensor_code_filter #(.SYS_CLK_HZ(33000), .STABLE_MS(1)) u_bm_33 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_33));
    sensor_code_filter #(.SYS_CLK_HZ(63000), .STABLE_MS(1)) u_bm_63 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_63));
    sensor_code_filter #(.SYS_CLK_HZ(64000), .STABLE_MS(1)) u_bm_64 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_64));
    sensor_code_filter #(.SYS_CLK_HZ(65000), .STABLE_MS(1)) u_bm_65 (.clk(clk), .rst_n_sync(rst_n), .code_sync(bm_in), .code_stable(bm_out_65));

    initial clk = 1'b0;
    always #50 clk = ~clk;      // 任意周期,算法只数拍

    //-------------------------------------------------------------------------
    // 检查任务
    //-------------------------------------------------------------------------
    task check_stable;
        input [2:0]       exp;
        input [8*60-1:0]  label;
        begin
            checks = checks + 1;
            if (code_stable !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s: stable=%b expected %b", label, code_stable, exp);
            end else begin
                $display("  ok: %0s (stable=%b)", label, code_stable);
            end
        end
    endtask

    task check_eq3;
        input [2:0] act, exp;
        input [8*60-1:0] label;
        begin
            checks = checks + 1;
            if (act !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s: actual=%b expected=%b", label, act, exp);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 驱动码字 c 持续 n 拍,每个采样沿检查 stable 落在 allowed 集合内
    // (bit i = 码值 i 允许)。返回时的采样已完成。
    //-------------------------------------------------------------------------
    task drive_watch;
        input [2:0] c;
        input integer n;
        input [7:0] allowed;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                code_sync = c;
                @(posedge clk);
                #1;
                if (!allowed[code_stable]) begin
                    leak_cnt = leak_cnt + 1;
                    errors  = errors + 1;
                    $display("FAIL: leak stable=%b while driving %0b (allowed=%b)",
                             code_stable, c, allowed);
                end
            end
        end
    endtask

    // 精确 off-by-one:前 N-1 拍 stable 必须保持 prev,第 N 拍允许变成 next
    task drive_threshold;
        input [2:0] c;
        input [2:0] prev;
        input [2:0] next;
        integer k;
        begin
            for (k = 1; k <= N; k = k + 1) begin
                code_sync = c;
                @(posedge clk);
                #1;
                checks = checks + 1;
                if (k < N) begin
                    if (code_stable !== prev) begin
                        errors = errors + 1;
                        $display("FAIL: off-by-one: updated at cycle %0d (stable=%b)", k, code_stable);
                    end
                end else begin
                    if (code_stable !== next) begin
                        errors = errors + 1;
                        $display("FAIL: off-by-one: not updated at cycle %0d (stable=%b)", k, code_stable);
                    end
                end
            end
            checks = checks + 1;
            if (code_stable !== next) begin
                errors = errors + 1;
                $display("FAIL: threshold drive ended with stable=%b", code_stable);
            end
        end
    endtask

    initial begin
        checks   = 0;
        errors   = 0;
        leak_cnt = 0;
        clk      = 1'b0;
        rst_n    = 1'b0;
        code_sync    = 3'b000;
        code_sync_bp = 3'b000;

        $display("TB_SENSOR_CODE_FILTER: start (STABLE_CYCLES=%0d)", N);

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        //---------------------------------------------------------------------
        // T1:复位后 000
        //---------------------------------------------------------------------
        $display("T1: reset state");
        drive_watch(3'b000, 4, 8'b0000_0001);
        check_stable(3'b000, "T1 stable == 000 after reset");

        //---------------------------------------------------------------------
        // T2:000 -> 001,off-by-one(9 拍不更新,第 10 拍更新)
        //---------------------------------------------------------------------
        $display("T2: 000 -> 001 with off-by-one");
        drive_threshold(3'b001, 3'b000, 3'b001);

        //---------------------------------------------------------------------
        // T3:001 -> 111,中间码 011/101 各 5 拍(短),不得泄漏
        //---------------------------------------------------------------------
        $display("T3: 001 -> {011 short} -> {101 short} -> 111 (atomic)");
        drive_watch(3'b011, 5, 8'b0000_0010);   // 只允许 001
        drive_watch(3'b101, 5, 8'b0000_0010);   // 只允许 001
        drive_watch(3'b111, N - 1, 8'b0000_0010);
        drive_watch(3'b111, 1, 8'b0000_0010 | 8'b1000_0000);
        check_stable(3'b111, "T3 stable == 111 after atomic update");

        //---------------------------------------------------------------------
        // T4:短毛刺(001 持续 3 拍 < 门限)不更新,且之后 111 照常保持
        //---------------------------------------------------------------------
        $display("T4: short glitch rejected");
        drive_watch(3'b001, 3, 8'b1000_0000);   // 只允许 111
        drive_watch(3'b111, N, 8'b1000_0000);
        check_stable(3'b111, "T4 stable still 111 after glitch");

        //---------------------------------------------------------------------
        // T6(先做回到原值):101×5(候选) -> 111×3(回 stable,清零)
        //                    -> 101×9(重新数,不更新) -> 第 10 拍更新
        //---------------------------------------------------------------------
        $display("T6: return-to-stable clears the counter");
        drive_watch(3'b101, 5, 8'b1000_0000);
        drive_watch(3'b111, 3, 8'b1000_0000);   // 回到 stable:candidate 清回
        drive_watch(3'b101, N - 1, 8'b1000_0000);
        drive_watch(3'b101, 1, 8'b1000_0000 | 8'b0010_0000);
        check_stable(3'b101, "T6 stable == 101 after fresh full threshold");

        //---------------------------------------------------------------------
        // T5:candidate 改变使计数重新开始:
        //     110×9(差一拍) -> 011×1(换候选,计数作废重记 1)
        //     -> 011×8(累计 2..9,不更新) -> 011 第 10 拍更新
        //     若计数未重新开始,011 的第 1 拍(count=10)就会立即更新并被
        //     泄漏监视抓到。
        //---------------------------------------------------------------------
        $display("T5: candidate change restarts the count");
        drive_watch(3'b110, N - 1, 8'b0010_0000);   // 差一拍,不更新
        drive_watch(3'b011, 1,     8'b0010_0000);   // 换候选:计数作废重记 1
        drive_watch(3'b011, N - 2, 8'b0010_0000);   // 累计 2..9,不更新
        drive_watch(3'b011, 1,     8'b0010_0000 | 8'b0000_1000);
        check_stable(3'b011, "T5 stable == 011 after restarted full threshold");

        //---------------------------------------------------------------------
        // T4b:回静音 011 -> 000
        //---------------------------------------------------------------------
        $display("T4b: 011 -> 000 with off-by-one");
        drive_threshold(3'b000, 3'b011, 3'b000);

        //---------------------------------------------------------------------
        // T7:ENABLE=0 纯直通(立即跟随,毛刺也直通)
        //---------------------------------------------------------------------
        $display("T7: ENABLE=0 bypass instance follows input directly");
        code_sync_bp = 3'b101;
        @(posedge clk); #1;
        checks = checks + 1;
        if (code_stable_bp !== 3'b101) begin
            errors = errors + 1;
            $display("FAIL: bypass did not follow input (got %b)", code_stable_bp);
        end else begin
            $display("  ok: bypass follows input immediately (101)");
        end
        code_sync_bp = 3'b010;
        @(posedge clk); #1;
        checks = checks + 1;
        if (code_stable_bp !== 3'b010) begin
            errors = errors + 1;
            $display("FAIL: bypass glitch not passed through (got %b)", code_stable_bp);
        end else begin
            $display("  ok: bypass passes short codes through (010)");
        end

        //---------------------------------------------------------------------
        // T8: 2 的幂次邻域位宽边界矩阵回归 (N = 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65)
        //---------------------------------------------------------------------
        $display("T8: power-of-2 boundary matrix verification");
        bm_in = 3'b000;
        repeat (10) @(posedge clk);
        #1;
        check_eq3(bm_out_7,  3'b000, "T8 reset 7");
        check_eq3(bm_out_8,  3'b000, "T8 reset 8");
        check_eq3(bm_out_9,  3'b000, "T8 reset 9");
        check_eq3(bm_out_15, 3'b000, "T8 reset 15");
        check_eq3(bm_out_16, 3'b000, "T8 reset 16");
        check_eq3(bm_out_17, 3'b000, "T8 reset 17");
        check_eq3(bm_out_31, 3'b000, "T8 reset 31");
        check_eq3(bm_out_32, 3'b000, "T8 reset 32");
        check_eq3(bm_out_33, 3'b000, "T8 reset 33");
        check_eq3(bm_out_63, 3'b000, "T8 reset 63");
        check_eq3(bm_out_64, 3'b000, "T8 reset 64");
        check_eq3(bm_out_65, 3'b000, "T8 reset 65");

        // 驱动 3'b001，在各门限拍分别验证 threshold-1 (仍为 000) 与 threshold (变为 001)
        begin : T8_DRIVE
            integer cyc_idx;
            for (cyc_idx = 1; cyc_idx <= 66; cyc_idx = cyc_idx + 1) begin
                bm_in = 3'b001;
                @(posedge clk); #1;
                // 校验 7, 8, 9
                if (cyc_idx == 6)  check_eq3(bm_out_7,  3'b000, "T8 N=7 at cyc 6 (threshold-1)");
                if (cyc_idx == 7)  check_eq3(bm_out_7,  3'b001, "T8 N=7 at cyc 7 (threshold)");
                if (cyc_idx == 7)  check_eq3(bm_out_8,  3'b000, "T8 N=8 at cyc 7 (threshold-1)");
                if (cyc_idx == 8)  check_eq3(bm_out_8,  3'b001, "T8 N=8 at cyc 8 (threshold)");
                if (cyc_idx == 8)  check_eq3(bm_out_9,  3'b000, "T8 N=9 at cyc 8 (threshold-1)");
                if (cyc_idx == 9)  check_eq3(bm_out_9,  3'b001, "T8 N=9 at cyc 9 (threshold)");

                // 校验 15, 16, 17
                if (cyc_idx == 14) check_eq3(bm_out_15, 3'b000, "T8 N=15 at cyc 14 (threshold-1)");
                if (cyc_idx == 15) check_eq3(bm_out_15, 3'b001, "T8 N=15 at cyc 15 (threshold)");
                if (cyc_idx == 15) check_eq3(bm_out_16, 3'b000, "T8 N=16 at cyc 15 (threshold-1)");
                if (cyc_idx == 16) check_eq3(bm_out_16, 3'b001, "T8 N=16 at cyc 16 (threshold)");
                if (cyc_idx == 16) check_eq3(bm_out_17, 3'b000, "T8 N=17 at cyc 16 (threshold-1)");
                if (cyc_idx == 17) check_eq3(bm_out_17, 3'b001, "T8 N=17 at cyc 17 (threshold)");

                // 校验 31, 32, 33
                if (cyc_idx == 30) check_eq3(bm_out_31, 3'b000, "T8 N=31 at cyc 30 (threshold-1)");
                if (cyc_idx == 31) check_eq3(bm_out_31, 3'b001, "T8 N=31 at cyc 31 (threshold)");
                if (cyc_idx == 31) check_eq3(bm_out_32, 3'b000, "T8 N=32 at cyc 31 (threshold-1)");
                if (cyc_idx == 32) check_eq3(bm_out_32, 3'b001, "T8 N=32 at cyc 32 (threshold)");
                if (cyc_idx == 32) check_eq3(bm_out_33, 3'b000, "T8 N=33 at cyc 32 (threshold-1)");
                if (cyc_idx == 33) check_eq3(bm_out_33, 3'b001, "T8 N=33 at cyc 33 (threshold)");

                // 校验 63, 64, 65
                if (cyc_idx == 62) check_eq3(bm_out_63, 3'b000, "T8 N=63 at cyc 62 (threshold-1)");
                if (cyc_idx == 63) check_eq3(bm_out_63, 3'b001, "T8 N=63 at cyc 63 (threshold)");
                if (cyc_idx == 63) check_eq3(bm_out_64, 3'b000, "T8 N=64 at cyc 63 (threshold-1)");
                if (cyc_idx == 64) check_eq3(bm_out_64, 3'b001, "T8 N=64 at cyc 64 (threshold)");
                if (cyc_idx == 64) check_eq3(bm_out_65, 3'b000, "T8 N=65 at cyc 64 (threshold-1)");
                if (cyc_idx == 65) check_eq3(bm_out_65, 3'b001, "T8 N=65 at cyc 65 (threshold)");
            end
        end

        // 验证短毛刺 (5 拍 < 7) 被所有实例全部滤除
        bm_in = 3'b011;
        repeat (5) @(posedge clk);
        #1;
        check_eq3(bm_out_7,  3'b001, "T8 glitch rejected 7");
        check_eq3(bm_out_8,  3'b001, "T8 glitch rejected 8");
        check_eq3(bm_out_9,  3'b001, "T8 glitch rejected 9");
        check_eq3(bm_out_15, 3'b001, "T8 glitch rejected 15");
        check_eq3(bm_out_16, 3'b001, "T8 glitch rejected 16");
        check_eq3(bm_out_17, 3'b001, "T8 glitch rejected 17");
        check_eq3(bm_out_31, 3'b001, "T8 glitch rejected 31");
        check_eq3(bm_out_32, 3'b001, "T8 glitch rejected 32");
        check_eq3(bm_out_33, 3'b001, "T8 glitch rejected 33");
        check_eq3(bm_out_63, 3'b001, "T8 glitch rejected 63");
        check_eq3(bm_out_64, 3'b001, "T8 glitch rejected 64");
        check_eq3(bm_out_65, 3'b001, "T8 glitch rejected 65");

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("TB_SENSOR_CODE_FILTER: PASS (checks=%0d, errors=0, leaks=0, sim_time=%0t)",
                     checks, $time);
        end else begin
            $display("TB_SENSOR_CODE_FILTER: FAIL (checks=%0d, errors=%0d, leaks=%0d, sim_time=%0t)",
                     checks, errors, leak_cnt, $time);
        end

        $finish;
    end

endmodule
