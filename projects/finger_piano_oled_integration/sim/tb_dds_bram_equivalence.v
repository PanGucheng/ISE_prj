`timescale 1ns/1ps

// Compare every output clock with the frozen pre-BRAM DDS, including the
// minimum divider and note changes before/on/after the sample clock.
module dds_bram_equivalence_case #(parameter integer DIV = 2) (
    output reg done,
    output reg failed
);
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg [2:0] note = 3'd6;
    wire [11:0] actual, reference, disabled_code;
    wire actual_valid, reference_valid, disabled_valid;
    integer cycle, samples, segment, offset, changes;
    reg [2:0] previous_note;
    dds_sine_generator #(.SYS_CLK_HZ(DIV*8000), .SAMPLE_RATE_HZ(8000), .ENABLE(1)) dut
        (.clk(clk), .rst_n_sync(rst_n), .note_code(note), .dac_code(actual), .dac_code_valid(actual_valid));
    dds_sine_generator_reference #(.SYS_CLK_HZ(DIV*8000), .SAMPLE_RATE_HZ(8000), .ENABLE(1)) golden
        (.clk(clk), .rst_n_sync(rst_n), .note_code(note), .dac_code(reference), .dac_code_valid(reference_valid));
    dds_sine_generator #(.SYS_CLK_HZ(DIV*8000), .SAMPLE_RATE_HZ(8000), .ENABLE(0)) disabled
        (.clk(clk), .rst_n_sync(rst_n), .note_code(note), .dac_code(disabled_code), .dac_code_valid(disabled_valid));

    initial begin
        done = 0; failed = 0; samples = 0; changes = 0; previous_note = note;
        repeat (3) @(negedge clk);
        rst_n = 1;
        // First 32 periods exercise nonzero phase; then eight notes including
        // mute at all three edge offsets, followed by an asynchronous reset.
        for (cycle = 0; cycle < 144*DIV; cycle = cycle+1) begin
            if (cycle >= 32*DIV && cycle < 128*DIV) begin
                segment = (cycle - 32*DIV) / (4*DIV);
                case (segment % 3)
                    0: offset = DIV-2; // preceding edge (also DIV=2)
                    1: offset = DIV-1; // exact sample edge
                    2: offset = 0;     // following edge
                endcase
                if ((cycle % (4*DIV)) == offset) note = (segment+1) % 8;
            end
            if (note != previous_note) changes = changes+1;
            previous_note = note;
            if (cycle == 132*DIV) rst_n = 0;
            if (cycle == 132*DIV+2) rst_n = 1;
            @(posedge clk);
            #1;
            if ({actual_valid, actual} !== {reference_valid, reference} ||
                disabled_code !== 12'h800 || disabled_valid !== 1'b0) begin
                $display("ERROR: DDS DIV=%0d cycle=%0d note=%0d actual=%b/%h reference=%b/%h", DIV, cycle, note, actual_valid, actual, reference_valid, reference);
                failed = 1;
            end
            if (actual_valid === 1'b1) samples = samples+1;
            @(negedge clk);
        end
        if (samples < 130 || changes < 20) begin
            $display("ERROR: vacuous DDS check DIV=%0d samples=%0d changes=%0d", DIV, samples, changes);
            failed = 1;
        end
        $display("DDS_EQ DIV=%0d cycles=%0d samples=%0d changes=%0d failed=%0d", DIV, cycle, samples, changes, failed);
        done = 1;
    end
endmodule

module tb_dds_bram_equivalence;
    wire [3:0] done, failed;
    dds_bram_equivalence_case #(.DIV(2)) c2 (.done(done[0]), .failed(failed[0]));
    dds_bram_equivalence_case #(.DIV(7)) c7 (.done(done[1]), .failed(failed[1]));
    dds_bram_equivalence_case #(.DIV(125)) c125 (.done(done[2]), .failed(failed[2]));
    dds_bram_equivalence_case #(.DIV(1500)) c1500 (.done(done[3]), .failed(failed[3]));
    reg clk = 0;
    always #5 clk = ~clk;
    reg [7:0] addr = 0;
    wire [11:0] sync_code, golden_code;
    integer i, errors;
    reg [11:0] held_code;
    sine_rom_12bit_sync rom (.clk(clk), .phase_addr(addr), .sine_code(sync_code));
    sine_lut_12bit golden_rom (.phase_addr(addr), .sine_code(golden_code));
    initial begin
        errors = 0;
        // Read every phase, also assert the output holds between clock edges.
        @(posedge clk); #1;
        for (i = 0; i < 256; i = i+1) begin
            @(negedge clk);
            held_code = sync_code;
            addr = i;
            #1;
            if (sync_code !== held_code) errors = errors+1;
            @(posedge clk); #1;
            if (sync_code !== golden_code) begin
                $display("ERROR: ROM address=%0d actual=%h reference=%h", i, sync_code, golden_code);
                errors = errors+1;
            end
        end
        wait (&done);
        if (errors != 0 || failed != 0)
            $display("TB_DDS_BRAM_EQUIVALENCE: FAIL rom_errors=%0d dds_failed=%b", errors, failed);
        else
            $display("TB_DDS_BRAM_EQUIVALENCE: PASS phases=256 dividers=2,7,125,1500");
        $finish;
    end
    initial begin
        #3000000;
        $display("TB_DDS_BRAM_EQUIVALENCE: FAIL watchdog");
        $finish;
    end
endmodule
