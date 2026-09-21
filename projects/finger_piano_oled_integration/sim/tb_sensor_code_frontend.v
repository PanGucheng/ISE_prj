//=============================================================================
// tb_sensor_code_frontend.v — sensor_code_frontend 验收(P2 计划 Commit C)
//
// 完整链路:async input -> 2FF sync -> vector filter -> decoder。
//
// 缩短参数(P2 计划 §19):SYS_CLK_HZ=10000,STABLE_MS=1 -> STABLE_CYCLES=10。
// TB_ACTIVE_HIGH 参数由 project.json generic 覆盖:
//   sensor_code_frontend_high  TB_ACTIVE_HIGH=1(默认)
//   sensor_code_frontend_low   TB_ACTIVE_HIGH=0
// 两套都跑,低有效模式同时核对极性映射:物理111->逻辑000(静音)、
// 物理110->逻辑001(C)、物理000->逻辑111(B)。
//
// 覆盖(§20):000->mute、001->C、011->E、111->B、111->000 回静音,以及
// 快速中间码 001 -> 011(短) -> 111:note_code 全程不得出现短暂 3。
//
// 诊断文本全 ASCII。判定行:TB_SENSOR_CODE_FRONTEND: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_sensor_code_frontend;

    localparam integer N = 10;   // STABLE_CYCLES(由参数推导)

    parameter integer TB_ACTIVE_HIGH = 1;

    reg         clk;
    reg         rst_n;
    reg  [2:0]  sensor_async;
    wire [2:0]  sensor_code_stable;
    wire [2:0]  note_code;

    integer checks;
    integer errors;

    sensor_code_frontend #(
        .SYS_CLK_HZ    (10000),
        .STABLE_MS     (1),
        .FILTER_ENABLE (1),
        .ACTIVE_HIGH   (TB_ACTIVE_HIGH)
    ) u_dut (
        .clk               (clk),
        .rst_n_sync        (rst_n),
        .sensor_async      (sensor_async),
        .sensor_code_stable(sensor_code_stable),
        .note_code         (note_code)
    );

    initial clk = 1'b0;
    always #50 clk = ~clk;

    //-------------------------------------------------------------------------
    // 按逻辑值驱动(ACTIVE_HIGH=0 时自动取反),持续 n 拍,每个采样沿检查
    // note_code 落在 allowed 集合(bit i = 音符 i 允许)
    //-------------------------------------------------------------------------
    task drive_logical_watch;
        input [2:0] logical_code;
        input integer n;
        input [7:0] allowed;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                sensor_async = TB_ACTIVE_HIGH ? logical_code : ~logical_code;
                @(posedge clk);
                #1;
                if (!allowed[note_code]) begin
                    errors = errors + 1;
                    $display("FAIL: leak note=%0d while driving logical %b (allowed=%b)",
                             note_code, logical_code, allowed);
                end
            end
        end
    endtask

    task check2;
        input [2:0]       stable_exp;
        input [2:0]       note_exp;
        input [8*56-1:0]  label;
        begin
            checks = checks + 1;
            if ((sensor_code_stable !== stable_exp) || (note_code !== note_exp)) begin
                errors = errors + 1;
                $display("FAIL: %0s: stable=%b note=%0d expected stable=%b note=%0d",
                         label, sensor_code_stable, note_code, stable_exp, note_exp);
            end else begin
                $display("  ok: %0s (stable=%b note=%0d)", label, sensor_code_stable, note_code);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        checks = 0;
        errors = 0;
        clk    = 1'b0;
        rst_n  = 1'b0;
        sensor_async = TB_ACTIVE_HIGH ? 3'b000 : 3'b111;   // 复位期给静音物理电平

        $display("TB_SENSOR_CODE_FRONTEND: start (TB_ACTIVE_HIGH=%0d, STABLE_CYCLES=%0d)",
                 TB_ACTIVE_HIGH, N);

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        //---------------------------------------------------------------------
        // T1:静音(逻辑 000,极性换算后驱动)
        //---------------------------------------------------------------------
        $display("T1: logical 000 -> mute");
        drive_logical_watch(3'b000, N + 6, 8'b0000_0001);
        check2(3'b000, 3'd0, "T1 stable=000 note=0 (mute)");

        //---------------------------------------------------------------------
        // T2:逻辑 001 -> C4(note 1)
        //---------------------------------------------------------------------
        $display("T2: logical 001 -> note 1 (C4)");
        drive_logical_watch(3'b001, N + 6, 8'b0000_0011);
        check2(3'b001, 3'd1, "T2 stable=001 note=1");

        //---------------------------------------------------------------------
        // T3:逻辑 011 -> E4(note 3)
        //---------------------------------------------------------------------
        $display("T3: logical 011 -> note 3 (E4)");
        drive_logical_watch(3'b011, N + 6, 8'b0000_1011);
        check2(3'b011, 3'd3, "T3 stable=011 note=3");

        //---------------------------------------------------------------------
        // T4:逻辑 111 -> B4(note 7)
        //---------------------------------------------------------------------
        $display("T4: logical 111 -> note 7 (B4)");
        drive_logical_watch(3'b111, N + 6, 8'b1000_1011);
        check2(3'b111, 3'd7, "T4 stable=111 note=7");

        //---------------------------------------------------------------------
        // T5:111 -> 000 回静音
        //---------------------------------------------------------------------
        $display("T5: logical 111 -> 000 (mute)");
        drive_logical_watch(3'b000, N + 6, 8'b1000_0001);
        check2(3'b000, 3'd0, "T5 stable=000 note=0");

        //---------------------------------------------------------------------
        // T6:快速中间码:逻辑 001 -> 011(短) -> 111
        //     note_code 只允许 1 -> 7,不得出现短暂 3
        //---------------------------------------------------------------------
        $display("T6: fast intermediate 001 -> {011 short} -> 111");
        drive_logical_watch(3'b001, N + 6, 8'b0000_0011);   // 回到 note 1
        drive_logical_watch(3'b011, 4,     8'b0000_0011);   // 短暂中间码
        drive_logical_watch(3'b111, N - 1, 8'b0000_0011);   // 仍不允许 3
        drive_logical_watch(3'b111, 6,     8'b1000_0011);   // 完成切换
        check2(3'b111, 3'd7, "T6 stable=111 note=7 (no transient 3)");

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("TB_SENSOR_CODE_FRONTEND: PASS (checks=%0d, errors=0, sim_time=%0t)",
                     checks, $time);
        end else begin
            $display("TB_SENSOR_CODE_FRONTEND: FAIL (checks=%0d, errors=%0d, sim_time=%0t)",
                     checks, errors, $time);
        end

        $finish;
    end

endmodule
