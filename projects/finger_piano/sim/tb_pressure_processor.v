//=============================================================================
// tb_pressure_processor.v — pressure_processor 验收(P5 计划 Commit C)
//
// 覆盖(§25/§26/§17):
//   T1 复位:全 0、valid=0;
//   T2 端到端:CH0=FFFF(-1)/CH1=1000/CH2=2000,ZERO=10/100/200
//              -> P0=0 / P1=900 / P2=1800,valid 单 clk;
//   T3 通道独立性:只改 CH0 -> 只有 P0 变(防 CH1->ch2 之类接线错);
//   T4 负码 + 零点饱和组合不出绕回。
//
// 诊断文本全 ASCII。判定行:TB_PRESSURE_PROCESSOR: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_pressure_processor;

    reg         clk;
    reg         rst_n;
    reg  [15:0] ch0, ch1, ch2;
    reg         valid;
    wire [14:0] p0, p1, p2;
    wire        pressure_valid;

    integer checks;
    integer errors;

    pressure_processor #(
        .CH0_ZERO (15'd10),
        .CH1_ZERO (15'd100),
        .CH2_ZERO (15'd200)
    ) u_dut (
        .clk              (clk),
        .rst_n_sync       (rst_n),
        .adc_ch0_raw      (ch0),
        .adc_ch1_raw      (ch1),
        .adc_ch2_raw      (ch2),
        .adc_sample_valid (valid),
        .pressure_ch0     (p0),
        .pressure_ch1     (p1),
        .pressure_ch2     (p2),
        .pressure_valid   (pressure_valid)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task push_frame;
        input [15:0] a;
        input [15:0] b;
        input [15:0] c;
        begin
            @(negedge clk);
            ch0 = a; ch1 = b; ch2 = c;
            valid = 1'b1;
            @(posedge clk);
            #1;                     // 帧更新 + valid 同沿,1ns 后采样
            @(negedge clk);
            valid = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task check3;
        input [14:0]     e0;
        input [14:0]     e1;
        input [14:0]     e2;
        input [8*56-1:0] label;
        begin
            checks = checks + 1;
            if ((p0 !== e0) || (p1 !== e1) || (p2 !== e2)) begin
                errors = errors + 1;
                $display("FAIL: %0s: got (%0d,%0d,%0d) expected (%0d,%0d,%0d)",
                         label, p0, p1, p2, e0, e1, e2);
            end else begin
                $display("  ok: %0s: P=(%0d,%0d,%0d)", label, p0, p1, p2);
            end
        end
    endtask

    initial begin
        checks = 0;
        errors = 0;
        clk    = 1'b0;
        rst_n  = 1'b0;
        ch0 = 16'h0000; ch1 = 16'h0000; ch2 = 16'h0000;
        valid = 1'b0;

        $display("TB_PRESSURE_PROCESSOR: start");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        //---------------------------------------------------------------------
        // T1:复位后全 0 且 valid=0
        //---------------------------------------------------------------------
        $display("T1: reset state");
        check3(15'd0, 15'd0, 15'd0, "T1 all pressures 0 after reset");
        checks = checks + 1;
        if (pressure_valid !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: T1 pressure_valid != 0 after reset");
        end else begin
            $display("  ok: T1 pressure_valid == 0 after reset");
        end

        //---------------------------------------------------------------------
        // T2:端到端(§25):FFFF/1000/2000 + ZERO 10/100/200
        //---------------------------------------------------------------------
        $display("T2: signed clamp + zero correction end to end");
        push_frame(16'hFFFF, 16'd1000, 16'd2000);
        check3(15'd0, 15'd900, 15'd1800, "T2 P=(0,900,1800)");
        checks = checks + 1;
        if (pressure_valid !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: T2 pressure_valid not 1 clk wide");
        end else begin
            $display("  ok: T2 pressure_valid was exactly 1 clk");
        end

        //---------------------------------------------------------------------
        // T3:通道独立性(§26):只改 CH0
        //---------------------------------------------------------------------
        $display("T3: channel independence (only CH0 changes)");
        ch0 = 16'd5000;                     // 不发 valid,先改输入
        push_frame(16'd5000, 16'd1000, 16'd2000);
        check3(15'd4990, 15'd900, 15'd1800, "T3 only P0 changed (4990)");

        //---------------------------------------------------------------------
        // T4:负码 + 大零点:饱和不出绕回
        //---------------------------------------------------------------------
        $display("T4: negative and underflow saturation");
        push_frame(16'hFFF0, 16'd50, 16'h8000);
        // CH0 -16 -> 0;CH1 50-100 下溢 -> 0;CH2 0x8000 符号位为 1 -> 0
        check3(15'd0, 15'd0, 15'd0, "T4 negative/underflow all clamp to 0");

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("TB_PRESSURE_PROCESSOR: PASS (checks=%0d, errors=0)", checks);
        end else begin
            $display("TB_PRESSURE_PROCESSOR: FAIL (checks=%0d, errors=%0d)", checks, errors);
        end

        $finish;
    end

endmodule
