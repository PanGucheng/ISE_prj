//=============================================================================
// tb_bin_to_dec_volt.v
// 单元测试: 验证 16-bit 原始码到十进制电压 (4 位小数) 转换
//=============================================================================

`timescale 1ns / 1ps

module tb_bin_to_dec_volt;

    reg        clk;
    reg        rst_n_sync;
    reg        start;
    reg [15:0] raw_code;
    wire       done;
    wire [3:0] d_volt;
    wire [3:0] d_tenths;
    wire [3:0] d_hundredths;
    wire [3:0] d_thousandths;
    wire [3:0] d_tenthousands;

    bin_to_dec_volt u_dut (
        .clk              (clk),
        .rst_n_sync       (rst_n_sync),
        .start            (start),
        .raw_code         (raw_code),
        .done             (done),
        .d_volt           (d_volt),
        .d_tenths         (d_tenths),
        .d_hundredths     (d_hundredths),
        .d_thousandths    (d_thousandths),
        .d_tenthousands   (d_tenthousands)
    );

    always #41.667 clk = ~clk; // 12 MHz

    task test_val;
        input [15:0] code;
        input [3:0]  exp_v;
        input [3:0]  exp_t;
        input [3:0]  exp_h;
        input [3:0]  exp_m;
        input [3:0]  exp_tm;
        begin
            @(posedge clk);
            raw_code <= code;
            start    <= 1'b1;
            @(posedge clk);
            start    <= 1'b0;

            @(posedge done);
            @(posedge clk);
            $display("[TEST] raw=%0d (0x%04X) -> %0d.%0d%0d%0d%0d V (exp: %0d.%0d%0d%0d%0d)",
                code, code, d_volt, d_tenths, d_hundredths, d_thousandths, d_tenthousands,
                exp_v, exp_t, exp_h, exp_m, exp_tm);

            if (d_volt !== exp_v || d_tenths !== exp_t || d_hundredths !== exp_h ||
                d_thousandths !== exp_m || d_tenthousands !== exp_tm) begin
                $display("ERROR: mismatch for raw=%0d!", code);
                $finish;
            end
        end
    endtask

    initial begin
        clk = 0;
        rst_n_sync = 0;
        start = 0;
        raw_code = 0;

        #200;
        @(posedge clk);
        rst_n_sync <= 1;
        #100;

        // 1) 0 V
        test_val(16'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0);

        // 2) 7376 (实测值 0x1CD0: 7376 * 125 = 922,000 uV -> 0.9220 V)
        test_val(16'd7376, 4'd0, 4'd9, 4'd2, 4'd2, 4'd0);

        // 3) 8000 (8000 * 125 = 1,000,000 uV -> 1.0000 V)
        test_val(16'd8000, 4'd1, 4'd0, 4'd0, 4'd0, 4'd0);

        // 4) 26400 (26400 * 125 = 3,300,000 uV -> 3.3000 V)
        test_val(16'd26400, 4'd3, 4'd3, 4'd0, 4'd0, 4'd0);

        // 5) 32767 (满量程 32767 * 125 = 4,095,875 uV -> 4.0958 V)
        test_val(16'd32767, 4'd4, 4'd0, 4'd9, 4'd5, 4'd8);

        // 6) 负数钳位 0 V (-5)
        test_val(16'hFFFB, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0);

        $display("PASS: All bin_to_dec_volt tests passed!");
        $finish;
    end

endmodule
