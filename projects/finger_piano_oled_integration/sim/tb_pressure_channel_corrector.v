//=============================================================================
// tb_pressure_channel_corrector.v — pressure_channel_corrector 验收
// (P5 计划 Commit B,§22/§23)
//
// 覆盖:
//   - 计划给定的 9 行真值表(负码钳 0、零点减法、下溢饱和);
//   - 零点参数化:非零 ZERO_OFFSET 实例的行为;
//   - 大负码不取绝对值(-100 不能变成 +100);
//   - 15 位无符号减法不绕回(raw <= zero 时结果为 0,而不是 32767...)。
//
// 诊断文本全 ASCII。判定行:TB_PRESSURE_CHANNEL_CORRECTOR: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_pressure_channel_corrector;

    integer checks;
    integer errors;

    // 实例 1:ZERO_OFFSET = 0
    reg  [15:0] raw0;
    wire [14:0] corr0;
    pressure_channel_corrector #(.ZERO_OFFSET(15'd0)) u_c0 (
        .raw_code (raw0), .corrected_code (corr0)
    );

    // 实例 2:ZERO_OFFSET = 100
    reg  [15:0] raw100;
    wire [14:0] corr100;
    pressure_channel_corrector #(.ZERO_OFFSET(15'd100)) u_c100 (
        .raw_code (raw100), .corrected_code (corr100)
    );

    task check_pair;
        input [15:0]     raw;
        input [14:0]     exp0;
        input [14:0]     exp100;
        input [8*40-1:0] note;
        begin
            raw0   = raw;
            raw100 = raw;
            #10;
            checks = checks + 1;
            if (corr0 !== exp0) begin
                errors = errors + 1;
                $display("FAIL: zero=0   raw=%0h (%0s): got %0d expected %0d",
                         raw, note, corr0, exp0);
            end
            checks = checks + 1;
            if (corr100 !== exp100) begin
                errors = errors + 1;
                $display("FAIL: zero=100 raw=%0h (%0s): got %0d expected %0d",
                         raw, note, corr100, exp100);
            end
        end
    endtask

    initial begin
        checks = 0;
        errors = 0;
        raw0   = 16'h0000;
        raw100 = 16'h0000;

        $display("TB_PRESSURE_CHANNEL_CORRECTOR: start");

        // 计划 §22 真值表(zero=0 一列;zero=100 一列按公式推)
        // raw,      exp(zero=0), exp(zero=100)
        check_pair(16'h0000, 15'd0,     15'd0, "0");
        check_pair(16'h0001, 15'd1,     15'd0, "1");        // underflow -> 0
        check_pair(16'h7FFF, 15'd32767, 15'd32667, "max positive");
        check_pair(16'hFFFF, 15'd0,     15'd0, "-1 clamped");  // 负码钳 0
        check_pair(16'hFF00, 15'd0,     15'd0, "-256 clamped");
        check_pair(16'd100,  15'd100,   15'd0, "100/100");     // raw == zero -> 0
        check_pair(16'd99,   15'd99,    15'd0, "99/100");      // underflow -> 0
        check_pair(16'd101,  15'd101,   15'd1, "101/100");
        check_pair(16'd1000, 15'd1000,  15'd900, "1000/100");

        // 下溢饱和专项:不会绕回成大数
        raw0 = 16'd50; raw100 = 16'd50;
        #10;
        checks = checks + 1;
        if (corr100 > 15'd100) begin
            errors = errors + 1;
            $display("FAIL: unsigned wrap detected: %0d", corr100);
        end else begin
            $display("  ok: no unsigned underflow wrap (50-100 -> %0d)", corr100);
        end

        // 大负码不取绝对值专项:-100(0xFF9C)不能变成 +100 的压力
        raw0 = 16'hFF9C;
        #10;
        checks = checks + 1;
        if (corr0 !== 15'd0) begin
            errors = errors + 1;
            $display("FAIL: negative code -100 became pressure %0d (abs value bug)", corr0);
        end else begin
            $display("  ok: negative code -100 clamped to 0 (no abs)");
        end

        if (errors == 0) begin
            $display("TB_PRESSURE_CHANNEL_CORRECTOR: PASS (checks=%0d, errors=0)", checks);
        end else begin
            $display("TB_PRESSURE_CHANNEL_CORRECTOR: FAIL (checks=%0d, errors=%0d)", checks, errors);
        end

        $finish;
    end

endmodule
