`timescale 1ns/1ps
module tb_uart_reporter_equivalence;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    wire tx_new, tx_old;
    tri1 adc_sda_new, dac_sda_new, oled_sda_new;
    tri1 adc_sda_old, dac_sda_old, oled_sda_old;
    reg [15:0] ch0 = 16'h1234, ch1 = 16'hABCD, ch2 = 16'h8F09;
    reg [2:0] error_code = 0, note_code = 0;
    reg adc_valid = 0, adc_error = 0, oled_done = 0, oled_error = 0;
    reg [22:0] heartbeat = 1;
    integer cycle, errors, bytes_checked, adc_messages;
    reg [5:0] observed_types;
    finger_piano_stage2_oled_top #(.UART_BAUD_RATE(3000000)) dut
        (.clk(clk), .rst_n(rst_n), .sensor_async(3'd0), .uart_tx(tx_new),
         .adc_i2c_sda(adc_sda_new), .dac_i2c_sda(dac_sda_new), .oled_i2c_sda(oled_sda_new));
    finger_piano_stage2_oled_top_reference #(.UART_BAUD_RATE(3000000)) golden
        (.clk(clk), .rst_n(rst_n), .sensor_async(3'd0), .uart_tx(tx_old),
         .adc_i2c_sda(adc_sda_old), .dac_i2c_sda(dac_sda_old), .oled_i2c_sda(oled_sda_old));

    initial begin
        force dut.piano_adc_ch0_raw = ch0; force golden.piano_adc_ch0_raw = ch0;
        force dut.piano_adc_ch1_raw = ch1; force golden.piano_adc_ch1_raw = ch1;
        force dut.piano_adc_ch2_raw = ch2; force golden.piano_adc_ch2_raw = ch2;
        force dut.piano_adc_error_code = error_code; force golden.piano_adc_error_code = error_code;
        force dut.piano_note_debug = note_code; force golden.piano_note_debug = note_code;
        force dut.piano_adc_sample_valid = adc_valid; force golden.piano_adc_sample_valid = adc_valid;
        force dut.piano_adc_error = adc_error; force golden.piano_adc_error = adc_error;
        force dut.oled_init_done = oled_done; force golden.oled_init_done = oled_done;
        force dut.oled_error = oled_error; force golden.oled_error = oled_error;
        force dut.heartbeat_cnt = heartbeat; force golden.heartbeat_cnt = heartbeat;
        errors = 0; bytes_checked = 0; adc_messages = 0; observed_types = 0;
        repeat (6) @(negedge clk);
        rst_n = 1;
        for (cycle = 0; cycle < 30000; cycle = cycle+1) begin
            // Change raw samples during transmission to detect loss of the
            // per-channel snapshot, and exercise both numeric/alphabetic hex.
            ch0 = ch0+16'h123; ch1 = ch1-16'h321; ch2 = ch2+16'h5AB;
            adc_valid = (cycle % 97 == 0);
            heartbeat = (cycle % 3000 == 500) ? 0 : 1;
            oled_done = (cycle >= 700);
            oled_error = (cycle >= 900 && cycle < 1000);
            adc_error = (cycle % 3000 == 1800);
            error_code = (cycle / 3000) % 6;
            if (cycle % 3000 == 2000) note_code = (note_code == 7) ? 0 : note_code+1;
            // Reset while an ADC report is in flight, then exercise restart.
            if (cycle == 15500) rst_n = 0;
            if (cycle == 15510) rst_n = 1;
            @(posedge clk); #1;
            if (tx_new !== tx_old || dut.uart_tx_valid !== golden.uart_tx_valid) begin
                $display("ERROR: UART timing mismatch cycle=%0d", cycle);
                errors = errors+1;
            end
            if (dut.uart_tx_valid) begin
                bytes_checked = bytes_checked+1;
                if (dut.uart_tx_byte !== golden.uart_tx_byte) begin
                    $display("ERROR: UART byte cycle=%0d actual=%h expected=%h", cycle, dut.uart_tx_byte, golden.uart_tx_byte);
                    errors = errors+1;
                end
                case (golden.send_msg_type)
                    1: observed_types[0] = 1;
                    2: observed_types[1] = 1;
                    3: observed_types[2] = 1;
                    4: observed_types[3] = 1;
                    5: observed_types[4] = 1;
                    6: begin
                        observed_types[5] = 1;
                        if (golden.ch_idx == 2 && golden.step_idx == 11) adc_messages = adc_messages+1;
                    end
                endcase
            end
            @(negedge clk);
        end
        if (errors == 0 && bytes_checked > 400 && adc_messages >= 5 && observed_types == 6'b111111)
            $display("TB_UART_REPORTER_EQUIVALENCE: PASS bytes=%0d adc_messages=%0d types=%b", bytes_checked, adc_messages, observed_types);
        else
            $display("TB_UART_REPORTER_EQUIVALENCE: FAIL errors=%0d bytes=%0d adc_messages=%0d types=%b", errors, bytes_checked, adc_messages, observed_types);
        $finish;
    end
    initial begin
        #400000;
        $display("TB_UART_REPORTER_EQUIVALENCE: FAIL watchdog");
        $finish;
    end
endmodule
