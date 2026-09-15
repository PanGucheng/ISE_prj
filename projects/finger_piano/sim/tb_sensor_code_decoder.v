//=============================================================================
// tb_sensor_code_decoder.v — sensor_code_decoder 验收(P2 计划 Commit A)
//
// 遍历全部 2^3 = 8 个编码,逐一核对编码表:
//   000->0, 001->1, 010->2, 011->3, 100->4, 101->5, 110->6, 111->7
// (000 = 静音,001~111 = 唱名 1~7)。
//
// 诊断文本全 ASCII。判定行:TB_SENSOR_CODE_DECODER: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_sensor_code_decoder;

    integer checks;
    integer errors;
    integer i;
    reg  [2:0] code;
    wire [2:0] note;

    sensor_code_decoder u_dut (
        .sensor_code (code),
        .note_code   (note)
    );

    task check_note;
        input [2:0] c;
        input [2:0] n;
        begin
            checks = checks + 1;
            if (note !== n) begin
                errors = errors + 1;
                $display("FAIL: code=%b expect note=%0d got note=%0d", c, n, note);
            end else begin
                $display("  ok: code=%b -> note=%0d", c, note);
            end
        end
    endtask

    initial begin
        checks = 0;
        errors = 0;
        code   = 3'b000;

        $display("TB_SENSOR_CODE_DECODER: start");

        for (i = 0; i < 8; i = i + 1) begin
            code = i[2:0];
            #10;                       // 组合逻辑稳定
            check_note(code, i[2:0]);
        end

        if (errors == 0) begin
            $display("TB_SENSOR_CODE_DECODER: PASS (checks=%0d, errors=0)", checks);
        end else begin
            $display("TB_SENSOR_CODE_DECODER: FAIL (checks=%0d, errors=%0d)", checks, errors);
        end

        $finish;
    end

endmodule
