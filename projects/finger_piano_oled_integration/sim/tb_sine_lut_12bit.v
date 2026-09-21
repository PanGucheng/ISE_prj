//=============================================================================
// tb_sine_lut_12bit.v — sine_lut_12bit 验收(P3 计划 Commit B,§17)
//
// 对 phase = 0..255 全部遍历:
//   1) 范围:256 <= code <= 3840,且无 X/Z;
//   2) 四个象限关键点:0->2048、64->3840、128->2048、192->256(精确);
//   3) 半周期反对称:code[p] + code[p+128] = 4096(容差 <= 1 LSB);
//   4) 四分之一波单调不减:phase 0->64;
//   5) 独立数学复核(TB 可用 real):code[p] 与
//      round(2048 + 1792*sin(2*pi*p/256)) 逐点对照,容差 <= 1 LSB
//      (该检查与 RTL 常量表相互独立,防止"表-文档-TB 三处同错")。
//
// 诊断文本全 ASCII。判定行:TB_SINE_LUT_12BIT: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_sine_lut_12bit;

    integer checks;
    integer errors;
    integer p;
    real    expect_real;
    integer expect_code;

    reg  [7:0]  phase_addr;
    wire [11:0] sine_code;

    sine_lut_12bit u_dut (
        .phase_addr (phase_addr),
        .sine_code  (sine_code)
    );

    task check_range;
        input [7:0] a;
        begin
            checks = checks + 1;
            if ((sine_code < 12'd256) || (sine_code > 12'd3840) ||
                (sine_code === 12'hxxx)) begin
                errors = errors + 1;
                $display("FAIL: range phase=%0d code=%h", a, sine_code);
            end
        end
    endtask

    task check_exact;
        input [7:0]  a;
        input [11:0] exp;
        begin
            checks = checks + 1;
            if (sine_code !== exp) begin
                errors = errors + 1;
                $display("FAIL: key point phase=%0d code=%0d expected %0d", a, sine_code, exp);
            end else begin
                $display("  ok: key point phase=%0d -> %0d", a, sine_code);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 独立 sine 参考(ISim 不支持 $sin,用 real 泰勒级数自算:
    // sin(x) = x - x^3/3! + x^5/5! - ...,x 限制在 [0, pi/2],6 项足够)
    //-------------------------------------------------------------------------
    function real sin_ref;
        input real x;
        real x2, term, s;
        integer n;
        begin
            s    = x;
            term = x;
            x2   = x * x;
            for (n = 1; n <= 6; n = n + 1) begin
                term = -term * x2 / ((2.0 * n) * (2.0 * n + 1.0));
                s    = s + term;
            end
            sin_ref = s;
        end
    endfunction

    // sin(2*pi*p/256),象限约简后调用 sin_ref
    function real sine256;
        input integer p;
        integer q, r, eff;
        real a, s;
        begin
            q = (p / 64) % 4;
            r = p % 64;
            if ((q == 1) || (q == 3)) eff = 64 - r;
            else                      eff = r;
            a = 3.14159265358979323846 / 2.0 * eff / 64.0;
            s = sin_ref(a);
            if ((q == 2) || (q == 3)) s = -s;
            sine256 = s;
        end
    endfunction

    initial begin
        checks = 0;
        errors = 0;
        p      = 0;
        phase_addr = 8'd0;

        $display("TB_SINE_LUT_12BIT: start");

        //---------------------------------------------------------------------
        // 四个象限关键点(精确)
        //---------------------------------------------------------------------
        phase_addr = 8'd0;   #10; check_exact(8'd0,   12'd2048);
        phase_addr = 8'd64;  #10; check_exact(8'd64,  12'd3840);
        phase_addr = 8'd128; #10; check_exact(8'd128, 12'd2048);
        phase_addr = 8'd192; #10; check_exact(8'd192, 12'd256);

        //---------------------------------------------------------------------
        // 全 256 相位遍历:范围检查
        //---------------------------------------------------------------------
        for (p = 0; p < 256; p = p + 1) begin
            phase_addr = p[7:0];
            #10;
            check_range(p[7:0]);
        end

        //---------------------------------------------------------------------
        // 反对称与数学复核(第二次遍历,直接成对读取)
        //---------------------------------------------------------------------
        for (p = 0; p < 128; p = p + 1) begin : ANTI
            reg [11:0] code_p;
            phase_addr = p[7:0];
            #10;
            code_p = sine_code;
            phase_addr = p[7:0] + 8'd128;
            #10;
            checks = checks + 1;
            if ((code_p + sine_code > 13'd4097) ||
                (code_p + sine_code < 13'd4095)) begin
                errors = errors + 1;
                $display("FAIL: antisym p=%0d: %0d + %0d != 4096+-1",
                         p, code_p, sine_code);
            end
        end

        for (p = 0; p < 256; p = p + 1) begin
            phase_addr = p[7:0];
            #10;
            expect_real = 2048.0 + 1792.0 * sine256(p);
            // 四舍五入(与 RTL 生成脚本一致:floor(x+0.5))
            expect_code = $rtoi(expect_real + 0.5);
            checks = checks + 1;
            if ((sine_code > expect_code + 1) || (sine_code < expect_code - 1) ||
                (sine_code === 12'hxxx)) begin
                errors = errors + 1;
                $display("FAIL: math p=%0d code=%0d expected~%0d", p, sine_code, expect_code);
            end
        end

        //---------------------------------------------------------------------
        // 四分之一波单调不减:phase 0..64
        //---------------------------------------------------------------------
        begin : MONO
            reg [11:0] prev;
            integer q;
            phase_addr = 8'd0;
            #10;
            prev = sine_code;
            for (q = 1; q <= 64; q = q + 1) begin
                phase_addr = q[7:0];
                #10;
                checks = checks + 1;
                if ((sine_code < prev) || (sine_code === 12'hxxx)) begin
                    errors = errors + 1;
                    $display("FAIL: monotonic phase=%0d code=%0d prev=%0d", q, sine_code, prev);
                end
                prev = sine_code;
            end
        end

        if (errors == 0) begin
            $display("TB_SINE_LUT_12BIT: PASS (checks=%0d, errors=0)", checks);
        end else begin
            $display("TB_SINE_LUT_12BIT: FAIL (checks=%0d, errors=%0d)", checks, errors);
        end

        $finish;
    end

endmodule
