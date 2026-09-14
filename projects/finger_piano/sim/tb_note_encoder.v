//=============================================================================
// tb_note_encoder.v
// note_encoder priority encoder test (pure combinational, no clock).
//
// Coverage:
//   0000000 -> 0 (no note)
//   7 single keys -> 1..7
//   all pressed -> 1 (highest priority)
//   2+3 -> 2
//   6+7 -> 6
//   3+5+7 -> 3
//
// NOTE: all diagnostics are ASCII on purpose. ISim on the Win7 build host runs
// with an ANSI (GBK) code page and garbles non-ASCII text passed through task
// arguments, which would make the run log unreadable.
//
// Verdict line: TB_NOTE_ENCODER: PASS/FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_note_encoder;

    reg  [6:0] key_stable;
    wire [2:0] note_code;

    integer checks;
    integer errors;

    note_encoder u_dut (
        .key_stable (key_stable),
        .note_code  (note_code)
    );

    task check;
        input [6:0]      keys;
        input [2:0]      expected;
        input [8*64-1:0] label;
        begin
            key_stable = keys;
            #1;
            checks = checks + 1;
            if (note_code !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s key_stable=%b -> note_code=%0d (expected %0d)",
                         label, keys, note_code, expected);
            end else begin
                $display("  ok: %0s key_stable=%b -> note_code=%0d", label, keys, note_code);
            end
        end
    endtask

    initial begin
        checks     = 0;
        errors     = 0;
        key_stable = 7'b0000000;

        $display("TB_NOTE_ENCODER: start (priority 1 > 2 > 3 > 4 > 5 > 6 > 7)");

        check(7'b0000000, 3'd0, "none");
        check(7'b0000001, 3'd1, "key1 (C4)");
        check(7'b0000010, 3'd2, "key2 (D4)");
        check(7'b0000100, 3'd3, "key3 (E4)");
        check(7'b0001000, 3'd4, "key4 (F4)");
        check(7'b0010000, 3'd5, "key5 (G4)");
        check(7'b0100000, 3'd6, "key6 (A4)");
        check(7'b1000000, 3'd7, "key7 (B4)");

        check(7'b1111111, 3'd1, "all pressed -> highest priority 1");
        check(7'b0000110, 3'd2, "2+3 -> 2");
        check(7'b0011000, 3'd4, "4+5 -> 4");
        check(7'b1100000, 3'd6, "6+7 -> 6");
        check(7'b0010100, 3'd3, "3+5+7 -> 3");
        check(7'b0101010, 3'd2, "2+4+6 -> 2");
        check(7'b1111110, 3'd2, "all but key1 -> 2");

        if (errors == 0) begin
            $display("TB_NOTE_ENCODER: PASS (checks=%0d, errors=0)", checks);
        end else begin
            $display("TB_NOTE_ENCODER: FAIL (checks=%0d, errors=%0d)", checks, errors);
        end

        $finish;
    end

endmodule
