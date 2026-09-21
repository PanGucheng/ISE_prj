//=============================================================================
// tb_pressure_frame_capture.v — pressure_frame_capture 验收(P5 计划 Commit A)
//
// 覆盖(§24):
//   A 复位           全输出 0、valid=0
//   B no valid       不断改 ADC 输入但 valid=0 -> frame 必须保持旧数据
//   C valid pulse    输入 1234/3456/5678 -> 同一拍原子出现三路新值
//   D 第二帧         全部替换为新值,确认无通道串位
//   E valid 严格 1 clk 宽
//
// 诊断文本全 ASCII。判定行:TB_PRESSURE_FRAME_CAPTURE: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_pressure_frame_capture;

    reg         clk;
    reg         rst_n;
    reg  [15:0] ch0, ch1, ch2;
    reg         valid;
    wire [15:0] f0, f1, f2;
    wire        frame_valid;

    integer checks;
    integer errors;

    pressure_frame_capture u_dut (
        .clk              (clk),
        .rst_n_sync       (rst_n),
        .adc_ch0_raw      (ch0),
        .adc_ch1_raw      (ch1),
        .adc_ch2_raw      (ch2),
        .adc_sample_valid (valid),
        .frame_ch0_raw    (f0),
        .frame_ch1_raw    (f1),
        .frame_ch2_raw    (f2),
        .frame_valid      (frame_valid)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task check32;
        input [15:0] got;
        input [15:0] exp;
        input [8*56-1:0] label;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s: got %0h expected %0h", label, got, exp);
            end else begin
                $display("  ok: %0s (%0h)", label, got);
            end
        end
    endtask

    task check_flag;
        input      cond;
        input [8*56-1:0] label;
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

    integer k;

    initial begin
        checks = 0;
        errors = 0;
        clk  = 1'b0;
        rst_n= 1'b0;
        ch0  = 16'h0000; ch1 = 16'h0000; ch2 = 16'h0000;
        valid= 1'b0;

        $display("TB_PRESSURE_FRAME_CAPTURE: start");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        //---------------------------------------------------------------------
        // A:复位后全 0
        //---------------------------------------------------------------------
        $display("T1: reset state");
        check32(f0, 16'h0000, "T1 frame_ch0 == 0");
        check32(f1, 16'h0000, "T1 frame_ch1 == 0");
        check32(f2, 16'h0000, "T2 frame_ch2 == 0");
        check_flag(frame_valid === 1'b0, "T1 frame_valid == 0");

        //---------------------------------------------------------------------
        // B:no valid -> frame 保持(输入随便变)
        //---------------------------------------------------------------------
        $display("T2: inputs change without valid -> frame holds");
        for (k = 0; k < 10; k = k + 1) begin
            @(negedge clk);
            ch0 = ch0 + 16'h0101;
            ch1 = ch1 + 16'h0202;
            ch2 = ch2 + 16'h0303;
            valid = 1'b0;
        end
        repeat (3) @(negedge clk);
        check32(f0, 16'h0000, "T2 frame_ch0 still 0");
        check32(f1, 16'h0000, "T2 frame_ch1 still 0");
        check32(f2, 16'h0000, "T2 frame_ch2 still 0");
        check_flag(frame_valid === 1'b0, "T2 no fake frame_valid");

        //---------------------------------------------------------------------
        // C:valid 单脉冲 -> 原子锁存(在锁存沿 P1 之后 1ns 采样)
        //---------------------------------------------------------------------
        $display("T3: atomic latch on valid pulse");
        @(negedge clk);
        ch0 = 16'h1234; ch1 = 16'h3456; ch2 = 16'h5678;
        valid = 1'b1;                   // DUT 在下一个 posedge(P1)锁存
        @(posedge clk);
        #1;                             // P1 后 1ns:新帧 + frame_valid 同沿
        check32(f0, 16'h1234, "T3 frame_ch0 == 1234");
        check32(f1, 16'h3456, "T3 frame_ch1 == 3456");
        check32(f2, 16'h5678, "T3 frame_ch2 == 5678");
        check_flag(frame_valid === 1'b1, "T3 frame_valid == 1 with the new frame");
        @(negedge clk);                 // 清 valid(下一 posedge 起 frame_valid 回 0)
        valid = 1'b0;
        @(posedge clk);
        #1;
        check_flag(frame_valid === 1'b0, "T3 frame_valid exactly 1 clk wide");
        check32(f0, 16'h1234, "T3 frame holds after valid deassert");

        //---------------------------------------------------------------------
        // D:第二帧整体替换 + 通道不串位
        //---------------------------------------------------------------------
        $display("T4: second frame replaces everything");
        @(negedge clk);
        ch0 = 16'h0AAA; ch1 = 16'h0BBB; ch2 = 16'h0CCC;
        valid = 1'b1;
        @(posedge clk);
        #1;
        check32(f0, 16'h0AAA, "T4 frame_ch0 == 0AAA (no cross-wiring)");
        check32(f1, 16'h0BBB, "T4 frame_ch1 == 0BBB");
        check32(f2, 16'h0CCC, "T4 frame_ch2 == 0CCC");

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("TB_PRESSURE_FRAME_CAPTURE: PASS (checks=%0d, errors=0)", checks);
        end else begin
            $display("TB_PRESSURE_FRAME_CAPTURE: FAIL (checks=%0d, errors=%0d)", checks, errors);
        end

        $finish;
    end

endmodule
