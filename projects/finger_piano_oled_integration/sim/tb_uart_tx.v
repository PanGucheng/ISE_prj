//=============================================================================
// tb_uart_tx.v
// UART TX 单测: 严格验证波特率与时序协议
// 验证要点:
//   1. 空闲态: idle = 1, tx_ready = 1
//   2. 起始位: start = 0, 持续 104 个 12 MHz 时钟周期
//   3. 数据位: 8 data bits, LSB first, 每一位持续 104 个时钟周期
//   4. 停止位: stop = 1, 持续 104 个时钟周期
//   5. 完成后: tx_ready 恢复 1, tx_pin 保持 1
//=============================================================================

`timescale 1ns/1ps

module tb_uart_tx;

    reg        clk;
    reg        rst_n_sync;
    reg  [7:0] tx_byte;
    reg        tx_valid;
    wire       tx_ready;
    wire       tx_pin;

    localparam integer CLK_HZ    = 12000000;
    localparam integer BAUD_RATE = 115200;
    localparam integer BIT_CYC   = CLK_HZ / BAUD_RATE; // 104

    uart_tx #(
        .CLK_HZ    (CLK_HZ),
        .BAUD_RATE (BAUD_RATE)
    ) u_dut (
        .clk        (clk),
        .rst_n_sync (rst_n_sync),
        .tx_byte    (tx_byte),
        .tx_valid   (tx_valid),
        .tx_ready   (tx_ready),
        .tx_pin     (tx_pin)
    );

    // 12 MHz 时钟 (半周期 41.667 ns)
    initial clk = 1'b0;
    always #41.667 clk = ~clk;

    integer checks;
    integer errors;

    task check_true;
        input            cond;
        input [8*60-1:0] label;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end else begin
                $display("  ok: %0s", label);
            end
        end
    endtask

    task check_eq32;
        input integer    got;
        input integer    exp;
        input [8*60-1:0] label;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s: got %0d expected %0d", label, got, exp);
            end else begin
                $display("  ok: %0s (%0d)", label, got);
            end
        end
    endtask

    // 发送一个字节并严格校验时序
    task send_and_verify_byte;
        input [7:0] byte_to_send;
        integer bit_i;
        integer count;
        begin
            $display("--- Testing byte 0x%02X ---", byte_to_send);
            check_eq32(tx_ready, 1'b1, "tx_ready is 1 before send");
            check_eq32(tx_pin,   1'b1, "tx_pin is idle high before send");

            @(negedge clk);
            tx_byte  = byte_to_send;
            tx_valid = 1'b1;
            @(negedge clk);
            tx_valid = 1'b0;

            // 1. 验证 Start bit
            check_eq32(tx_pin,   1'b0, "Start bit is 0");
            check_eq32(tx_ready, 1'b0, "tx_ready drops to 0 during transmission");

            count = 1; // 刚过去的那一拍已经处于 start bit
            while (count < BIT_CYC) begin
                @(posedge clk);
                #1;
                check_eq32(tx_pin, 1'b0, "Start bit remains 0");
                count = count + 1;
            end
            check_eq32(count, BIT_CYC, "Start bit duration == 104 clk");

            // 2. 验证 8 Data bits (LSB first)
            for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
                @(posedge clk);
                #1;
                check_eq32(tx_pin, byte_to_send[bit_i], "Data bit level");
                count = 1;
                while (count < BIT_CYC) begin
                    @(posedge clk);
                    #1;
                    check_eq32(tx_pin, byte_to_send[bit_i], "Data bit holding level");
                    count = count + 1;
                end
                check_eq32(count, BIT_CYC, "Data bit duration == 104 clk");
            end

            // 3. 验证 Stop bit
            @(posedge clk);
            #1;
            check_eq32(tx_pin, 1'b1, "Stop bit is 1");
            count = 1;
            while (count < BIT_CYC) begin
                @(posedge clk);
                #1;
                check_eq32(tx_pin, 1'b1, "Stop bit remains 1");
                count = count + 1;
            end
            check_eq32(count, BIT_CYC, "Stop bit duration == 104 clk");

            // 4. 验证完成与恢复 idle
            @(posedge clk);
            #1;
            check_eq32(tx_ready, 1'b1, "tx_ready restored to 1");
            check_eq32(tx_pin,   1'b1, "tx_pin remains idle 1");
            repeat (10) @(posedge clk);
        end
    endtask

    initial begin
        checks   = 0;
        errors   = 0;
        tx_byte  = 8'h00;
        tx_valid = 1'b0;
        rst_n_sync = 1'b0;

        $display("TB_UART_TX: start");

        repeat (16) @(posedge clk);
        check_eq32(tx_ready, 1'b1, "Reset state: tx_ready == 1");
        check_eq32(tx_pin,   1'b1, "Reset state: tx_pin == 1");

        @(negedge clk);
        rst_n_sync = 1'b1;
        repeat (16) @(posedge clk);

        // 测试典型字节: 0xA5 (10100101b), 0x5A (01011010b), 0x00, 0xFF
        send_and_verify_byte(8'hA5);
        send_and_verify_byte(8'h5A);
        send_and_verify_byte(8'h00);
        send_and_verify_byte(8'hFF);

        $display("--------------------------------------------------");
        $display("TB_UART_TX: checks=%0d, errors=%0d", checks, errors);
        if (errors == 0) begin
            $display("TB_UART_TX: PASS");
        end else begin
            $display("TB_UART_TX: FAIL");
        end
        $finish;
    end

endmodule
