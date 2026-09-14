//=============================================================================
// tb_finger_piano_top.v
// Top level integration test:
//   1) after reset with no key pressed: key_debug=0, note_debug=0, audio_out=0;
//   2) single note 1..7: window based filter verdict + note code + audio
//      frequency (error < 1%) + silence after release;
//   3) short glitch (300 cycles < 1000 cycle stable threshold) must be rejected;
//   4) melody "Twinkle Twinkle": 1 1 5 5 6 6 5 / 4 4 3 3 2 2 1:
//      every note is checked, and every note must really be released
//      (key_debug / note_debug return to 0) so that repeated notes are two
//      independent key presses (1 -> 0 -> 1) instead of one long press that
//      the digital filter would merge;
//   5) input polarity: selected by parameter TB_KEY_ACTIVE_HIGH. Run the same
//      testbench a second time with fuse --generic_top "TB_KEY_ACTIVE_HIGH=0"
//      to prove active-low inputs behave identically.
//
// Window based filter verdict (never assumes "valid exactly at cycle N"):
//   key_in passes a two stage synchronizer and then the digital filter, so the
//   reaction time is deterministic but delayed:
//     - at STABLE_CYCLES - 1 cycles after the press: must still be inactive;
//     - at STABLE_CYCLES + SYNC_MARGIN cycles after the press: must be active.
//
// Simulation parameters (1 MHz, 1 ms) only shorten the run; they are unrelated
// to the board crystal.
//
// NOTE: all diagnostics are ASCII on purpose. ISim on the Win7 build host runs
// with an ANSI (GBK) code page and garbles non-ASCII text passed through task
// arguments, which would make the run log unreadable.
//
// Verdict line: TB_FINGER_PIANO_TOP: PASS/FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_finger_piano_top;

    parameter integer TB_SYS_CLK_HZ      = 1000000;   // simulation system clock
    parameter integer TB_STABLE_MS       = 1;         // simulation stable time (ms)
    parameter integer TB_KEY_ACTIVE_HIGH = 1;         // 1 = pressed is high

    localparam integer STABLE_CYCLES = (TB_SYS_CLK_HZ / 1000) * TB_STABLE_MS;  // 1000
    localparam integer SYNC_MARGIN   = 8;      // 2 sync FF + filter FF + scheduling
    localparam integer HOLD_CYCLES   = 20000;  // 20 ms equivalent per note
    localparam integer RELEASE_GAP   = 2000;   // >= 2 ms equivalent between notes
    localparam integer GLITCH_CYCLES = 300;    // must be < STABLE_CYCLES
    localparam integer MELODY_LEN    = 14;
    localparam integer GUARD_CYCLES  = 200000; // wait bound, avoids hangs

    reg        clk;
    reg        rst_n;
    reg  [6:0] key_in;
    wire       audio_out;
    wire [6:0] key_debug;
    wire [2:0] note_debug;

    integer checks;
    integer errors;
    integer cycle_count;

    integer n_meas;
    integer meas_ok;
    real    expected_hz;
    real    measured_hz;
    real    err_pct;

    // Twinkle Twinkle: 1 1 5 5 6 6 5  4 4 3 3 2 2 1
    reg [2:0] melody [0:MELODY_LEN-1];

    finger_piano_top #(
        .SYS_CLK_HZ        (TB_SYS_CLK_HZ),
        .KEY_STABLE_MS     (TB_STABLE_MS),
        .KEY_FILTER_ENABLE (1),
        .KEY_ACTIVE_HIGH   (TB_KEY_ACTIVE_HIGH)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .key_in     (key_in),
        .audio_out  (audio_out),
        .key_debug  (key_debug),
        .note_debug (note_debug)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    //-------------------------------------------------------------------------
    // Stimulus tasks: key level follows TB_KEY_ACTIVE_HIGH
    //-------------------------------------------------------------------------
    task press_key;
        input integer idx;   // 0..6
        begin
            if (TB_KEY_ACTIVE_HIGH != 0) begin
                key_in[idx] = 1'b1;
            end else begin
                key_in[idx] = 1'b0;
            end
        end
    endtask

    task release_key;
        input integer idx;   // 0..6
        begin
            if (TB_KEY_ACTIVE_HIGH != 0) begin
                key_in[idx] = 1'b0;
            end else begin
                key_in[idx] = 1'b1;
            end
        end
    endtask

    task release_all;
        begin
            if (TB_KEY_ACTIVE_HIGH != 0) begin
                key_in = 7'b0000000;
            end else begin
                key_in = 7'b1111111;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Basic wait / check tasks
    //-------------------------------------------------------------------------
    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
            end
        end
    endtask

    task wait_note;
        input [2:0]     expected;
        input integer   max_cycles;
        output integer  ok;
        integer         i;
        begin
            ok = 0;
            for (i = 0; i < max_cycles; i = i + 1) begin
                @(posedge clk);
                #1;
                if (note_debug === expected) begin
                    ok = 1;
                    i  = max_cycles;      // stop the loop
                end
            end
        end
    endtask

    task check_note_code;
        input [2:0]      expected;
        input [8*64-1:0] label;
        begin
            checks = checks + 1;
            if (note_debug !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s note_debug=%0d expected=%0d (cycle %0d)",
                         label, note_debug, expected, cycle_count);
            end else begin
                $display("  ok: %0s note_debug=%0d", label, note_debug);
            end
        end
    endtask

    task check_key_debug;
        input [6:0]      expected;
        input [8*64-1:0] label;
        begin
            checks = checks + 1;
            if (key_debug !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s key_debug=%b expected=%b (cycle %0d)",
                         label, key_debug, expected, cycle_count);
            end else begin
                $display("  ok: %0s key_debug=%b", label, key_debug);
            end
        end
    endtask

    task check_silence;
        input integer    cycles;
        input [8*64-1:0] label;
        integer          i;
        reg              bad;
        begin
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
                $display("FAIL: %0s audio_out is not 0 for %0d cycles", label, cycles);
            end else begin
                $display("  ok: %0s audio_out stays 0 for %0d cycles", label, cycles);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Audio half period measurement and frequency verdict
    // (independent method, same as tb_tone_generator)
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

    task measure_and_check;
        input [2:0]   code;
        input integer f_cHz;
        begin
            expected_hz = f_cHz / 100.0;
            measure_half_period(n_meas, meas_ok);
            checks = checks + 1;

            if (!meas_ok) begin
                errors = errors + 1;
                $display("FAIL: note %0d no audio_out toggle detected", code);
            end else begin
                measured_hz = TB_SYS_CLK_HZ / (2.0 * n_meas);
                err_pct     = ((measured_hz - expected_hz) / expected_hz) * 100.0;
                if ((err_pct > 1.0) || (err_pct < -1.0)) begin
                    errors = errors + 1;
                    $display("FAIL: note %0d half_period=%0d f_out=%.4f Hz expected=%.2f Hz err=%.4f%%",
                             code, n_meas, measured_hz, expected_hz, err_pct);
                end else begin
                    $display("  ok: note %0d half_period=%0d f_out=%.4f Hz expected=%.2f Hz err=%.4f%%",
                             code, n_meas, measured_hz, expected_hz, err_pct);
                end
            end
        end
    endtask

    function integer freq_cHz;
        input integer code;
        begin
            case (code)
                1:       freq_cHz = 26162;   // C4  261.62 Hz
                2:       freq_cHz = 29367;   // D4  293.67 Hz
                3:       freq_cHz = 32963;   // E4  329.63 Hz
                4:       freq_cHz = 34923;   // F4  349.23 Hz
                5:       freq_cHz = 39199;   // G4  391.99 Hz
                6:       freq_cHz = 44000;   // A4  440.00 Hz
                7:       freq_cHz = 49388;   // B4  493.88 Hz
                default: freq_cHz = 0;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // Single note test: window verdict + frequency spot check + release silence
    //-------------------------------------------------------------------------
    task test_single_note;
        input integer idx;         // 0..6
        integer       i;
        reg [6:0]     exp_key;
        reg [2:0]     code;
        integer       ok;
        begin
            exp_key = 7'b0000001;
            for (i = 0; i < idx; i = i + 1) begin
                exp_key = exp_key << 1;
            end
            code = idx + 1;

            $display("-- single note test: key_in[%0d] -> note %0d --", idx, code);

            press_key(idx);

            // Window lower bound: stable time not reached yet, must be inactive
            wait_cycles(STABLE_CYCLES - 1);
            #1;
            check_note_code(3'd0, "window-low(999 cycles) must still be silent");
            check_key_debug(7'b0000000, "window-low(999 cycles) key_debug");

            // Window upper bound: stable time + sync margin passed, must be active
            wait_cycles(SYNC_MARGIN + 1);
            #1;
            check_note_code(code, "window-high(1008 cycles) must be valid");
            check_key_debug(exp_key, "window-high(1008 cycles) key_debug");

            // Frequency spot check
            measure_and_check(code, freq_cHz(code));

            // Release: must return to silence
            release_key(idx);
            wait_cycles(STABLE_CYCLES + SYNC_MARGIN);
            #1;
            check_note_code(3'd0, "after release note_debug");
            check_key_debug(7'b0000000, "after release key_debug");
            check_silence(2000, "after release audio_out");

            wait_cycles(RELEASE_GAP);
        end
    endtask

    //-------------------------------------------------------------------------
    // Glitch rejection: a pulse shorter than the stable threshold must be ignored
    //-------------------------------------------------------------------------
    task test_glitch;
        begin
            $display("-- glitch rejection test: %0d cycle pulse < %0d cycle threshold --",
                     GLITCH_CYCLES, STABLE_CYCLES);
            press_key(0);
            wait_cycles(GLITCH_CYCLES);
            release_key(0);
            wait_cycles(STABLE_CYCLES + SYNC_MARGIN + 16);
            #1;
            check_note_code(3'd0, "glitch rejected note_debug");
            check_key_debug(7'b0000000, "glitch rejected key_debug");
            check_silence(1000, "glitch rejected audio_out");
            wait_cycles(RELEASE_GAP);
        end
    endtask

    //-------------------------------------------------------------------------
    // Twinkle Twinkle melody test
    //-------------------------------------------------------------------------
    task play_melody;
        integer   i;
        integer   note;
        integer   ok;
        integer   prev_note;
        integer   repeats;
        reg [2:0] code;
        begin
            $display("-- melody test: 1 1 5 5 6 6 5 / 4 4 3 3 2 2 1 --");
            prev_note = 0;
            repeats   = 0;

            for (i = 0; i < MELODY_LEN; i = i + 1) begin
                note = melody[i];
                code = note[2:0];

                if (note == prev_note) begin
                    repeats = repeats + 1;
                    $display("   (repeated note %0d: key_stable must go 1 -> 0 -> 1)", note);
                end

                press_key(note - 1);
                wait_note(code, STABLE_CYCLES + 200, ok);
                checks = checks + 1;
                if (!ok) begin
                    errors = errors + 1;
                    $display("FAIL: melody step %0d note %0d never became valid (note_debug=%0d)",
                             i, note, note_debug);
                end else begin
                    $display("  ok: melody step %0d note %0d valid (cycle %0d)", i, note, cycle_count);
                end

                // Frequency spot check on the first occurrence of each note
                if (note != prev_note) begin
                    measure_and_check(code, freq_cHz(note));
                end

                // Hold: verify the note does not drift, mid and end of hold
                wait_cycles(HOLD_CYCLES / 2);
                #1;
                check_note_code(code, "melody hold mid");

                wait_cycles(HOLD_CYCLES - (HOLD_CYCLES / 2));
                #1;
                check_note_code(code, "melody hold end");

                // Release: must observe 0 again, so repeated notes really are
                // two independent presses (key_stable goes 1 -> 0 -> 1)
                release_key(note - 1);
                wait_note(3'd0, STABLE_CYCLES + 200, ok);
                checks = checks + 1;
                if (!ok) begin
                    errors = errors + 1;
                    $display("FAIL: melody step %0d note %0d did not release (note_debug=%0d)",
                             i, note, note_debug);
                end else begin
                    $display("  ok: melody step %0d note %0d released -> 0 (cycle %0d)",
                             i, note, cycle_count);
                end

                // Release gap: at least a full stable release, so the next same
                // note is a new key event rather than one continued press
                wait_cycles(RELEASE_GAP);

                prev_note = note;
            end

            $display("   repeated notes in melody: %0d, all passed through a full release", repeats);
        end
    endtask

    //-------------------------------------------------------------------------
    // Main flow
    //-------------------------------------------------------------------------
    initial begin
        checks = 0;
        errors = 0;
        rst_n  = 1'b0;
        key_in = 7'b0000000;
        release_all();      // set inputs to the idle level for this polarity

        melody[0]  = 3'd1;  melody[1]  = 3'd1;  melody[2]  = 3'd5;
        melody[3]  = 3'd5;  melody[4]  = 3'd6;  melody[5]  = 3'd6;
        melody[6]  = 3'd5;  melody[7]  = 3'd4;  melody[8]  = 3'd4;
        melody[9]  = 3'd3;  melody[10] = 3'd3;  melody[11] = 3'd2;
        melody[12] = 3'd2;  melody[13] = 3'd1;

        $display("TB_FINGER_PIANO_TOP: start (SYS_CLK_HZ=%0d, STABLE_MS=%0d, STABLE_CYCLES=%0d, SYNC_MARGIN=%0d, KEY_ACTIVE_HIGH=%0d)",
                 TB_SYS_CLK_HZ, TB_STABLE_MS, STABLE_CYCLES, SYNC_MARGIN, TB_KEY_ACTIVE_HIGH);

        // Reset and idle state
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
        #1;

        $display("-- reset, no key --");
        check_note_code(3'd0, "reset note_debug");
        check_key_debug(7'b0000000, "reset key_debug");
        check_silence(20000, "idle after reset");

        // Single notes 1..7
        test_single_note(0);
        test_single_note(1);
        test_single_note(2);
        test_single_note(3);
        test_single_note(4);
        test_single_note(5);
        test_single_note(6);

        // Glitch rejection
        test_glitch;

        // Twinkle Twinkle
        play_melody;

        // Wrap up
        release_all();
        wait_cycles(STABLE_CYCLES + SYNC_MARGIN);
        #1;
        $display("-- wrap up --");
        check_note_code(3'd0, "final note_debug");
        check_key_debug(7'b0000000, "final key_debug");
        check_silence(5000, "final audio_out");

        if (errors == 0) begin
            $display("TB_FINGER_PIANO_TOP: PASS (checks=%0d, errors=0, polarity=%0d, sim_time=%0t)",
                     checks, TB_KEY_ACTIVE_HIGH, $time);
        end else begin
            $display("TB_FINGER_PIANO_TOP: FAIL (checks=%0d, errors=%0d, polarity=%0d, sim_time=%0t)",
                     checks, errors, TB_KEY_ACTIVE_HIGH, $time);
        end

        $finish;
    end

endmodule
