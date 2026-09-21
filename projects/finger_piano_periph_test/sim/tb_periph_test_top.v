//=============================================================================
// tb_periph_test_top.v
// P9 ADS1115 ADC UART 调试版本顶层联合仿真测试台
//
// 覆盖用例 (TB_MODE):
//   0: 正常 ADC UART 报文验证 (首帧门控、ASCII 比对、心跳、DAC 释放)
//   1: 地址 NACK 错误报文验证 (ADC ERROR CODE=1、DAC 释放)
//   2: 真实 1 Hz Heartbeat 参数接线与周期验证
//
// 判定行: TB_PERIPH_TEST_TOP: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_periph_test_top;

    parameter integer TB_MODE              = 0;
    parameter integer TB_HEARTBEAT_HALF_CYC = 2000;
    parameter integer TB_REPORT_CYCLES     = 50000;

    reg         clk;
    reg         rst_n;
    reg         adc_nack_addr;
    wire        adc_scl, adc_sda;
    wire        dac_scl, dac_sda;
    wire        uart_tx, dbg_heartbeat, dbg_unused;

    pullup pu_ascl (adc_scl);
    pullup pu_asda (adc_sda);
    pullup pu_dscl (dac_scl);
    pullup pu_dsda (dac_sda);

    periph_test_top #(
        .HEARTBEAT_HALF_CYC (TB_HEARTBEAT_HALF_CYC),
        .REPORT_CYCLES      (TB_REPORT_CYCLES),
        .UART_BAUD_RATE     (115200)
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .adc_i2c_scl   (adc_scl),
        .adc_i2c_sda   (adc_sda),
        .dac_i2c_scl   (dac_scl),
        .dac_i2c_sda   (dac_sda),
        .uart_tx       (uart_tx),
        .dbg_heartbeat (dbg_heartbeat),
        .dbg_unused    (dbg_unused)
    );

    ads1115_model #(
        .DEVICE_ADDR (7'h48),
        .CONV_CYCLES (2000),
        .VAL_AIN0    (16'h1234),
        .VAL_AIN1    (16'h3456),
        .VAL_AIN2    (16'h5678)
    ) u_adc_model (
        .clk             (clk),
        .rst             (~rst_n),
        .nack_addr_en    (adc_nack_addr),
        .nack_data_en    (1'b0),
        .conv_never_done (1'b0),
        .scl             (adc_scl),
        .sda             (adc_sda)
    );

    // DAC 模型挂在 DAC 总线上, 用于严密监控是否有任何非法 DAC 传输
    mcp4725_model #(
        .DEVICE_ADDR (7'h60)
    ) u_dac_model (
        .clk          (clk),
        .rst          (~rst_n),
        .nack_addr_en (1'b0),
        .nack_data_en (1'b0),
        .scl          (dac_scl),
        .sda          (dac_sda)
    );

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

    //-------------------------------------------------------------------------
    // UART 接收解析任务 (115200 baud @ 12 MHz = 104 拍/bit)
    //-------------------------------------------------------------------------
    task recv_byte;
        output [7:0] data;
        output       ok;
        integer bi;
        begin
            ok = 1;
            while (uart_tx !== 1'b0) @(posedge clk);
            repeat (52) @(posedge clk); // 半个 bit 到 start bit 中心
            if (uart_tx !== 1'b0) ok = 0;
            for (bi = 0; bi < 8; bi = bi + 1) begin
                repeat (104) @(posedge clk);
                data[bi] = uart_tx;
            end
            repeat (104) @(posedge clk); // stop bit
            if (uart_tx !== 1'b1) ok = 0;
            repeat (52) @(posedge clk);  // 越过 stop bit
        end
    endtask

    reg [7:0] line_buf [0:63];
    task recv_line;
        output integer len;
        reg [7:0] b;
        reg       bok;
        integer   done;
        begin
            len = 0;
            done = 0;
            while (!done && len < 64) begin
                recv_byte(b, bok);
                if (bok) begin
                    line_buf[len] = b;
                    len = len + 1;
                    if (b == 8'h0A) begin // '\n'
                        done = 1;
                    end
                end else begin
                    $display("FAIL: Framing error while receiving line");
                    errors = errors + 1;
                    done = 1;
                end
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Heartbeat 周期检查
    //-------------------------------------------------------------------------
    task heartbeat_check;
        input integer half_cyc;
        reg  v0, v1;
        integer g;
        begin
            g = 0;
            v0 = dbg_heartbeat;
            while ((dbg_heartbeat === v0) && (g < 8 * half_cyc + 100000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(dbg_heartbeat !== v0, "heartbeat: output toggles");
            @(posedge clk);
            v1 = dbg_heartbeat;
            g = 0;
            while ((dbg_heartbeat === v1) && (g < 8 * half_cyc + 100000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(dbg_heartbeat !== v1, "heartbeat: second toggle (half period)");
            checks = checks + 1;
            if ((g < half_cyc - 4) || (g > half_cyc + 4)) begin
                errors = errors + 1;
                $display("FAIL: heartbeat half period %0d clk, expected ~%0d", g, half_cyc);
            end else begin
                $display("  ok: heartbeat half period %0d clk (target %0d)", g, half_cyc);
            end
        end
    endtask

    task verify_line_ok;
        input integer len;
        integer i;
        reg match;
        reg [7:0] exp [0:11];
        begin
            match = 1;
            check_eq32(len, 12, "normal FireWater report length == 12");
            // VAL_AIN0 = 16'h1234 = 4660. 4660 * 125 = 582500 uV -> 0.5825 V
            exp[0]="c"; exp[1]="h"; exp[2]="0"; exp[3]=":";
            exp[4]="0"; exp[5]="."; exp[6]="5"; exp[7]="8"; exp[8]="2"; exp[9]="5";
            exp[10]=8'h0D; exp[11]=8'h0A;

            for (i = 0; i < 12; i = i + 1) begin
                if (line_buf[i] !== exp[i]) begin
                    $display("FAIL: char[%0d] mismatch: got 0x%02X (%c), exp 0x%02X (%c)",
                             i, line_buf[i], line_buf[i], exp[i], exp[i]);
                    match = 0;
                end
            end
            check_true(match, "all 12 characters match expected FireWater report (ch0:0.5825)");
        end
    endtask

    task verify_line_err;
        input integer len;
        input [7:0] exp_code_char;
        integer i;
        reg match;
        reg [7:0] exp [0:17];
        begin
            match = 1;
            check_eq32(len, 18, "error report length == 18");
            exp[0]="A"; exp[1]="D"; exp[2]="C"; exp[3]=" "; exp[4]="E"; exp[5]="R"; exp[6]="R";
            exp[7]="O"; exp[8]="R"; exp[9]=" "; exp[10]="C"; exp[11]="O"; exp[12]="D"; exp[13]="E";
            exp[14]="="; exp[15]=exp_code_char; exp[16]=8'h0D; exp[17]=8'h0A;

            for (i = 0; i < 18; i = i + 1) begin
                if (line_buf[i] !== exp[i]) begin
                    $display("FAIL: char[%0d] mismatch: got 0x%02X (%c), exp 0x%02X (%c)",
                             i, line_buf[i], line_buf[i], exp[i], exp[i]);
                    match = 0;
                end
            end
            check_true(match, "all 18 characters match expected error report");
        end
    endtask

    integer rx_len;

    initial begin
        checks        = 0;
        errors        = 0;
        adc_nack_addr = 1'b0;

        $display("TB_PERIPH_TEST_TOP: start (mode=%0d, hb=%0d, rep=%0d)",
                 TB_MODE, TB_HEARTBEAT_HALF_CYC, TB_REPORT_CYCLES);

        rst_n = 1'b0;
        repeat (32) @(posedge clk);

        //---------------------------------------------------------------------
        // 复位态检查
        //-------------------------------------------------------------------------
        check_eq32(dbg_heartbeat, 1'b0, "reset: dbg_heartbeat == 0");
        check_eq32(dbg_unused,    1'b0, "reset: dbg_unused == 0");
        check_eq32(uart_tx,       1'b1, "reset: uart_tx idle 1");
        check_true((dac_scl === 1'b1) && (dac_sda === 1'b1), "reset: DAC bus pulled high (released)");
        check_true((adc_scl === 1'b1) && (adc_sda === 1'b1), "reset: ADC bus pulled high");

        //---------------------------------------------------------------------
        // 模式 0: 正常流程测试
        //-------------------------------------------------------------------------
        if (TB_MODE == 0) begin
            @(negedge clk);
            rst_n = 1'b1;

            // 1. 验证心跳
            heartbeat_check(TB_HEARTBEAT_HALF_CYC);

            // 2. 接收并验证首包正常 UART 报文
            $display("Waiting for ADC UART normal report...");
            recv_line(rx_len);
            verify_line_ok(rx_len);

            // 3. 验证 DAC 独立总线完全静默 (无事务, byte_active=0)
            check_eq32(u_dac_model.frame_cnt, 0, "DAC received 0 frames (completely disabled)");
            check_eq32(u_dac_model.byte_active, 0, "DAC bus idle");
            check_eq32(dbg_unused, 1'b0, "dbg_unused remains 0");
        end

        //---------------------------------------------------------------------
        // 模式 1: 地址 NACK 错误报文测试
        //-------------------------------------------------------------------------
        if (TB_MODE == 1) begin
            adc_nack_addr = 1'b1; // 注入地址 NACK

            @(negedge clk);
            rst_n = 1'b1;

            $display("Waiting for ADC ERROR report...");
            recv_line(rx_len);
            verify_line_err(rx_len, "1");

            check_eq32(u_dac_model.frame_cnt, 0, "DAC 0 frames during ADC error");
            check_eq32(dbg_unused, 1'b0, "dbg_unused remains 0");
        end

        //---------------------------------------------------------------------
        // 模式 2: 真实心跳参数测试
        //-------------------------------------------------------------------------
        if (TB_MODE == 2) begin
            @(negedge clk);
            rst_n = 1'b1;
            heartbeat_check(TB_HEARTBEAT_HALF_CYC);
        end

        $display("--------------------------------------------------");
        $display("TB_PERIPH_TEST_TOP: checks=%0d, errors=%0d", checks, errors);
        if (errors == 0) begin
            $display("TB_PERIPH_TEST_TOP: PASS");
        end else begin
            $display("TB_PERIPH_TEST_TOP: FAIL");
        end
        $finish;
    end

endmodule
