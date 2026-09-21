//=============================================================================
// tb_tone_generator.v
// tone_generator test:
//   1) measured half-period count and theoretical output frequency of all seven
//      notes C4..B4 (frequency error must be < 1%);
//   2) measured half period equals the integer rounding used by the RTL formula;
//   3) strict silence while note_code = 0;
//   4) phase restart on note change (output cleared, full new half period).
//
// The simulation clock parameter TB_SYS_CLK_HZ is 1 MHz (overrides the DUT
// default) to keep the run short. It has nothing to do with the board crystal;
// the frequency verdict compares against the real nominal note frequencies.
//
// NOTE: all diagnostics are ASCII on purpose. ISim on the Win7 build host runs
// with an ANSI (GBK) code page and garbles non-ASCII text passed through task
// arguments, which would make the run log unreadable.
//
// Verdict line: TB_TONE_GENERATOR: PASS/FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_tone_generator;

    parameter integer TB_SYS_CLK_HZ = 1000000;   // simulation system clock

    localparam integer GUARD_CYCLES = 2000000;   // edge-wait bound, avoids hangs

    reg        clk;
    reg        rst_n;
    reg  [2:0] note_code;
    wire       audio_out;

    integer checks;
    integer errors;
    integer cycle_count;

    integer n_meas;
    integer meas_ok;
    real    expected_hz;
    real    measured_hz;
    real    err_pct;

    tone_generator #(
        .SYS_CLK_HZ (TB_SYS_CLK_HZ)
    ) u_dut (
        .clk        (clk),
        .rst_n_sync (rst_n),
        .note_code  (note_code),
        .audio_out  (audio_out)
    );

    // Simulation clock: 10 ns period
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Cycle counter, used to measure the half period
    initial cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    //-------------------------------------------------------------------------
    // Measure the number of clock cycles between two audio_out transitions.
    // Sampling happens 1 ns after posedge clk, so non-blocking updates are done.
    //-------------------------------------------------------------------------
    task measure_half_period;
        output integer cycles;
        output integer ok;
        integer        edges;
        integer        guard;
        integer        c0;
        integer        c1;
        reg            prev;
        begin
            cycles = 0;
            ok     = 0;
            edges  = 0;
            guard  = 0;
            c0     = 0;
            c1     = 0;
            prev   = audio_out;

            while ((edges < 2) && (guard < GUARD_CYCLES)) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
                if (audio_out !== prev) begin
                    prev  = audio_out;
                    edges = edges + 1;
                    if (edges == 1) begin
                        c0 = cycle_count;
                    end else begin
                        c1 = cycle_count;
                    end
                end
            end

            if (edges == 2) begin
                cycles = c1 - c0;
                ok     = 1;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Check one note: measured frequency must be within 1% of nominal.
    // f_cHz is the nominal frequency in units of 0.01 Hz (no real task args).
    //-------------------------------------------------------------------------
    task check_note;
        input [2:0]      code;
        input integer    f_cHz;
        input [8*64-1:0] label;
        begin
            note_code = code;
            repeat (4) @(posedge clk);      // let note change / phase restart take effect

            measure_half_period(n_meas, meas_ok);
            checks = checks + 1;

            if (!meas_ok) begin
                errors = errors + 1;
                $display("FAIL: %0s note_code=%0d no audio_out toggle detected", label, code);
            end else begin
                expected_hz = f_cHz / 100.0;
                measured_hz = TB_SYS_CLK_HZ / (2.0 * n_meas);
                err_pct     = ((measured_hz - expected_hz) / expected_hz) * 100.0;

                if ((err_pct > 1.0) || (err_pct < -1.0)) begin
                    errors = errors + 1;
                    $display("FAIL: %0s note_code=%0d half_period=%0d f_out=%.4f Hz expected=%.2f Hz err=%.4f%%",
                             label, code, n_meas, measured_hz, expected_hz, err_pct);
                end else begin
                    $display("  ok: %0s note_code=%0d half_period=%0d f_out=%.4f Hz expected=%.2f Hz err=%.4f%%",
                             label, code, n_meas, measured_hz, expected_hz, err_pct);
                end
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Silence check: with note_code = 0, audio_out must stay 0
    //-------------------------------------------------------------------------
    task check_silence;
        input integer    cycles;
        input [8*64-1:0] label;
        integer          i;
        reg              bad;
        begin
            note_code = 3'd0;
            repeat (4) @(posedge clk);
            bad = 1'b0;

            for (i = 0; i < cycles; i = i + 1) begin
                @(posedge clk);
                #1;
                if (audio_out !== 1'b0) begin
                    bad = 1'b1;
                end
            end

            checks = checks + 1;
            if (bad) begin
                errors = errors + 1;
                $display("FAIL: %0s audio_out is not 0 while note_code=0", label);
            end else begin
                $display("  ok: %0s audio_out stays 0 for %0d cycles", label, cycles);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Phase restart check: after a note change the output must be cleared and
    // then toggle after exactly one half period of the new note.
    //-------------------------------------------------------------------------
    task check_phase_restart;
        integer hp_expected;
        integer first_edge;
        integer ok;
        integer c0;
        integer guard;
        reg     prev;
        begin
            note_code = 3'd1;                     // play C4 first
            repeat (20) @(posedge clk);

            note_code = 3'd2;                     // switch to D4
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (audio_out !== 1'b0) begin
                errors = errors + 1;
                $display("FAIL: audio_out not cleared within 1 cycle after note change");
            end else begin
                $display("  ok: audio_out cleared immediately after note change (phase restart)");
            end

            // First half period of the new note must equal the D4 half period
            hp_expected = (TB_SYS_CLK_HZ * 10 + 2937) / (2 * 2937);

            first_edge = 0;
            ok         = 0;
            guard      = 0;
            prev       = audio_out;
            c0         = cycle_count;
            while ((ok == 0) && (guard < GUARD_CYCLES)) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
                if (audio_out !== prev) begin
                    prev       = audio_out;
                    first_edge = cycle_count - c0;
                    ok         = 1;
                end
            end

            checks = checks + 1;
            if (ok == 0) begin
                errors = errors + 1;
                $display("FAIL: no toggle detected after phase restart");
            end else if (first_edge != hp_expected) begin
                errors = errors + 1;
                $display("FAIL: phase restart half_period=%0d expected=%0d", first_edge, hp_expected);
            end else begin
                $display("  ok: phase restart half_period=%0d (matches RTL formula)", first_edge);
            end
        end
    endtask

    initial begin
        checks    = 0;
        errors    = 0;
        rst_n     = 1'b0;
        note_code = 3'd0;

        $display("TB_TONE_GENERATOR: start (TB_SYS_CLK_HZ=%0d Hz)", TB_SYS_CLK_HZ);

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        check_silence(20000, "idle after reset");

        check_note(3'd1, 26162, "C4 261.62Hz");
        check_note(3'd2, 29367, "D4 293.67Hz");
        check_note(3'd3, 32963, "E4 329.63Hz");
        check_note(3'd4, 34923, "F4 349.23Hz");
        check_note(3'd5, 39199, "G4 391.99Hz");
        check_note(3'd6, 44000, "A4 440.00Hz");
        check_note(3'd7, 49388, "B4 493.88Hz");

        check_phase_restart;

        check_silence(5000, "after playing");

        if (errors == 0) begin
            $display("TB_TONE_GENERATOR: PASS (checks=%0d, errors=0, sim_time=%0t)", checks, $time);
        end else begin
            $display("TB_TONE_GENERATOR: FAIL (checks=%0d, errors=%0d, sim_time=%0t)", checks, errors, $time);
        end

        $finish;
    end

endmodule
