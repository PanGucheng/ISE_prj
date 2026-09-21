//=============================================================================
// tb_ads1115_ctrl.v — ads1115_ctrl 验收(P1 计划 B 阶段,任务书 §28)
//
// 覆盖项(P1 计划要求):
//   1) 自动三通道轮询:三个 adc_sample_valid 逐一到达,raw 分别等于
//      模型返回的 AIN0/AIN1/AIN2 值(1234h/3456h/5678h);
//   2) 地址:模型观测到 7'h48;
//   3) 三路配置字:CH0 = C3E3、CH1 = D3E3、CH2 = E3E3(默认 PGA/DR);
//   4) pointer 使用:Config 写与 OS 轮询用 01,Conversion 读用 00;
//   5) 读阶段经过 RESTART(无中间 STOP 的重复起始);
//   6) MSB/LSB 顺序:由模型移位方向与 raw 值匹配间接证明;
//   7) 地址 NACK -> error_code = 1;pointer/数据 NACK -> error_code = 2
//      (controller 内映射,master 只报 NACK);
//   8) 转换永不完成 -> controller 的 OS 等待超时 -> error_code = 4;
//   9) 正常帧无多余 error 脉冲;错误恢复后重新出有效帧;
//  10) ENABLE=0 的实例:SCL/SDA 无任何边沿,sample_valid/busy/error 恒 0。
//
// ISim 的 pullup 只模拟逻辑上拉,不是 4.7 kΩ + 总线电容的上升沿模型。
// 诊断文本全 ASCII。判定行:TB_ADS1115_CTRL: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_ads1115_ctrl;

    localparam integer FRAME_GUARD  = 200000;   // 等一帧的周期上限
    localparam integer ERROR_GUARD  = 200000;   // 等一个 error 的周期上限
    localparam integer QUIET_CYCLES = 150000;   // ENABLE=0 安静观测窗口

    integer checks;
    integer errors;
    reg [2:0] ecode;

    reg clk;
    reg rst_n;      // 低有效复位(与工程其它 TB 一致)

    // DUT(ENABLE=1)总线
    wire        scl;
    wire        sda;
    wire [15:0] ch0_raw, ch1_raw, ch2_raw;
    wire        sample_valid, busy, err;
    wire [2:0]  err_code;

    // DUT(ENABLE=0)总线
    wire        scl2, sda2;
    wire [15:0] ch0_raw2, ch1_raw2, ch2_raw2;
    wire        sample_valid2, busy2, err2;
    wire [2:0]  err_code2;

    // 模型注入与观测
    reg  nack_addr_en;
    reg  nack_data_en;
    reg  conv_never_done;

    pullup pu_scl1 (scl);
    pullup pu_sda1 (sda);
    pullup pu_scl2 (scl2);
    pullup pu_sda2 (sda2);

    ads1115_ctrl #(
        .ENABLE(1'b1)
    ) u_dut (
        .clk              (clk),
        .rst_n_sync       (rst_n),
        .adc_i2c_scl      (scl),
        .adc_i2c_sda      (sda),
        .adc_ch0_raw      (ch0_raw),
        .adc_ch1_raw      (ch1_raw),
        .adc_ch2_raw      (ch2_raw),
        .adc_sample_valid (sample_valid),
        .adc_busy         (busy),
        .adc_error        (err),
        .error_code       (err_code)
    );

    ads1115_ctrl #(
        .ENABLE(1'b0)
    ) u_dut_off (
        .clk              (clk),
        .rst_n_sync       (rst_n),
        .adc_i2c_scl      (scl2),
        .adc_i2c_sda      (sda2),
        .adc_ch0_raw      (ch0_raw2),
        .adc_ch1_raw      (ch1_raw2),
        .adc_ch2_raw      (ch2_raw2),
        .adc_sample_valid (sample_valid2),
        .adc_busy         (busy2),
        .adc_error        (err2),
        .error_code       (err_code2)
    );

    ads1115_model #(
        .DEVICE_ADDR(7'h48),
        .CONV_CYCLES(2000)
    ) u_model (
        .clk             (clk),
        .rst             (~rst_n),   // 模型内部为高有效
        .nack_addr_en    (nack_addr_en),
        .nack_data_en    (nack_data_en),
        .conv_never_done (conv_never_done),
        .scl             (scl),
        .sda             (sda)
    );

    // 仿真时钟 10 ns
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // 事件计数
    //-------------------------------------------------------------------------
    integer valid_cnt;
    integer err_cnt;
    integer bus2_edges;      // ENABLE=0 总线边沿计数
    reg     scl2_q, sda2_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_cnt = 0;
            err_cnt   = 0;
        end else begin
            if (sample_valid === 1'b1) valid_cnt = valid_cnt + 1;
            if (err         === 1'b1) err_cnt   = err_cnt   + 1;
        end
    end

    always @(posedge clk) begin
        scl2_q <= scl2;
        sda2_q <= sda2;
        if ((scl2 !== scl2_q) || (sda2 !== sda2_q)) begin
            bus2_edges = bus2_edges + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 检查任务
    //-------------------------------------------------------------------------
    task check_eq32;
        input integer    got;
        input integer    exp;
        input [8*72-1:0] label;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s: got %0h expected %0h", label, got, exp);
            end else begin
                $display("  ok: %0s (%0h)", label, got);
            end
        end
    endtask

    task check_true;
        input            cond;
        input [8*72-1:0] label;
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

    //-------------------------------------------------------------------------
    // 等待 adc_sample_valid(有界)
    //-------------------------------------------------------------------------
    task wait_valid;
        input integer max_cycles;
        integer c0;
        integer v0;
        begin
            v0 = valid_cnt;
            c0 = 0;
            while ((valid_cnt == v0) && (c0 < max_cycles)) begin
                @(posedge clk);
                c0 = c0 + 1;
            end
            checks = checks + 1;
            if (valid_cnt == v0) begin
                errors = errors + 1;
                $display("FAIL: no adc_sample_valid within %0d cycles", max_cycles);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 等待 adc_error(有界),并返回 error_code
    //-------------------------------------------------------------------------
    task wait_error;
        input integer max_cycles;
        output [2:0] code;
        integer c0;
        integer e0;
        begin
            e0 = err_cnt;
            c0 = 0;
            while ((err_cnt == e0) && (c0 < max_cycles)) begin
                @(posedge clk);
                c0 = c0 + 1;
            end
            checks = checks + 1;
            if (err_cnt == e0) begin
                errors = errors + 1;
                $display("FAIL: no adc_error within %0d cycles", max_cycles);
            end
            code = err_code;
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        checks          = 0;
        errors          = 0;
        valid_cnt       = 0;
        err_cnt         = 0;
        bus2_edges      = 0;
        scl2_q          = 1'b1;
        sda2_q          = 1'b1;
        nack_addr_en    = 1'b0;
        nack_data_en    = 1'b0;
        conv_never_done = 1'b0;
        clk             = 1'b0;
        rst_n           = 1'b0;

        $display("TB_ADS1115_CTRL: start");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        //---------------------------------------------------------------------
        // 帧 1:CH0 -> CH1 -> CH2 完整一轮(sample_valid 在帧末脉冲)
        //---------------------------------------------------------------------
        $display("T1: frame 1 (CH0/CH1/CH2)");
        wait_valid(FRAME_GUARD);
        check_eq32(ch0_raw, 16'h1234, "T1 adc_ch0_raw == 0x1234 (MSB first)");
        check_eq32(u_model.cfg_mux100, 16'hC3E3, "T1 config word CH0 (MUX=100) == 0xC3E3");
        check_eq32(u_model.cfg_mux101, 16'hD3E3, "T1 config word CH1 (MUX=101) == 0xD3E3");
        check_eq32(u_model.cfg_mux110, 16'hE3E3, "T1 config word CH2 (MUX=110) == 0xE3E3");
        check_eq32(u_model.last_addr, 7'h48,   "T1 device address == 0x48");
        check_true(u_model.restart_cnt >= 2,   "T1 repeated START seen (poll + read)");
        check_true(u_model.ptr01_cnt >= 3,     "T1 pointer 01 used (config write + polls)");
        check_eq32(u_model.ptr00_cnt, 3,       "T1 pointer 00 used once per channel (3)");
        check_eq32(err_cnt, 0,                 "T1 no error in clean frame");

        //---------------------------------------------------------------------
        // 帧 2:第二轮扫描
        //---------------------------------------------------------------------
        $display("T2: frame 2");
        wait_valid(FRAME_GUARD);
        check_eq32(ch1_raw, 16'h3456, "T2 adc_ch1_raw == 0x3456");
        check_eq32(u_model.cfg_mux101, 16'hD3E3, "T2 config word CH1 still 0xD3E3");
        check_eq32(u_model.ptr00_cnt, 6,       "T2 pointer 00 count now 6");

        //---------------------------------------------------------------------
        // 帧 3:第三轮扫描
        //---------------------------------------------------------------------
        $display("T3: frame 3");
        wait_valid(FRAME_GUARD);
        check_eq32(ch2_raw, 16'h5678, "T3 adc_ch2_raw == 0x5678");
        check_eq32(u_model.cfg_mux110, 16'hE3E3, "T3 config word CH2 still 0xE3E3");
        check_eq32(u_model.ptr00_cnt, 9,       "T3 pointer 00 count now 9");
        check_eq32(err_cnt, 0,                 "T3 still no error after 3 frames");
        check_true(busy === 1'b1,              "T3 controller continuously scanning (busy=1)");

        //---------------------------------------------------------------------
        // 地址 NACK -> ADDR_NACK(1),恢复后重新出帧
        //---------------------------------------------------------------------
        $display("T4: address NACK -> error_code 1");
        nack_addr_en = 1'b1;
        wait_error(ERROR_GUARD, ecode);
        check_eq32(ecode, 3'd1, "T4 address NACK mapped to error_code 1");
        nack_addr_en = 1'b0;
        wait_valid(FRAME_GUARD);
        check_eq32(err_code, 3'd0, "T4 error_code cleared by next good frame");
        check_eq32(ch0_raw, 16'h1234, "T4 CH0 still correct after recovery");

        //---------------------------------------------------------------------
        // 数据/pointer NACK -> DATA_NACK(2),恢复
        //---------------------------------------------------------------------
        $display("T5: data NACK -> error_code 2");
        nack_data_en = 1'b1;
        wait_error(ERROR_GUARD, ecode);
        check_eq32(ecode, 3'd2, "T5 data NACK mapped to error_code 2");
        nack_data_en = 1'b0;
        wait_valid(FRAME_GUARD);
        check_eq32(err_code, 3'd0, "T5 error_code cleared by next good frame");

        //---------------------------------------------------------------------
        // 转换永不完成 -> OS 等待超时 -> 4,恢复
        //---------------------------------------------------------------------
        $display("T6: conversion never done -> wait timeout error_code 4");
        conv_never_done = 1'b1;
        wait_error(ERROR_GUARD + 40000, ecode);
        check_eq32(ecode, 3'd4, "T6 OS wait timeout mapped to error_code 4");
        conv_never_done = 1'b0;
        wait_valid(FRAME_GUARD);
        check_eq32(err_code, 3'd0, "T6 error_code cleared by next good frame");
        check_eq32(ch1_raw, 16'h3456, "T6 CH1 still correct after recovery");

        //---------------------------------------------------------------------
        // ENABLE=0:无任何总线边沿与输出活动
        //---------------------------------------------------------------------
        $display("T7: ENABLE=0 instance stays silent");
        begin : T7_BLOCK
            integer c;
            integer edges0;
            edges0 = bus2_edges;
            c = 0;
            while (c < QUIET_CYCLES) begin
                @(posedge clk);
                c = c + 1;
            end
            check_eq32(bus2_edges - edges0, 0, "T7 no SCL/SDA edges on bus 2");
            check_true(sample_valid2 === 1'b0, "T7 sample_valid2 == 0");
            check_true(busy2         === 1'b0, "T7 busy2 == 0");
            check_true(err2          === 1'b0, "T7 error2 == 0");
            check_true(err_code2     === 3'd0, "T7 err_code2 == 0");
            check_true((scl2 === 1'b1) && (sda2 === 1'b1),
                       "T7 bus 2 pulled high (released)");
        end

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("TB_ADS1115_CTRL: PASS (checks=%0d, errors=0, sim_time=%0t)",
                     checks, $time);
        end else begin
            $display("TB_ADS1115_CTRL: FAIL (checks=%0d, errors=%0d, sim_time=%0t)",
                     checks, errors, $time);
        end

        $finish;
    end

endmodule
