//=============================================================================
// tb_ads1115_pressure_pipeline.v — ADS1115 -> pressure 全链路验收
// (P5 计划 Commit D,§46/§47,纯仿真)
//
// 链路:ads1115_model(预设 ADC 码,不模拟 FSR/TL084/RC 模拟行为,§48)
//       -> ads1115_ctrl(I2C 采集)
//       -> pressure_processor(帧锁存 + 符号钳位 + 零点校正)
//
// 模型给出:CH0 = 16'hFFFF(负码,-1)、CH1 = 1000、CH2 = 2500;
// 零点:CH0_ZERO = 0、CH1_ZERO = 100、CH2_ZERO = 200。
// 期望:pressure = 0 / 900 / 2300 —— 证明 I2C 字节序 + signed code +
// 帧锁存 + 零点校正全链路正确。
//
// 诊断文本全 ASCII。判定行:TB_ADS1115_PRESSURE_PIPELINE: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_ads1115_pressure_pipeline;

    reg         clk;
    reg         rst_n;
    wire        scl, sda;
    wire [15:0] ch0_raw, ch1_raw, ch2_raw;
    wire        sample_valid, adc_busy, adc_error;
    wire [2:0]  adc_err_code;
    wire [14:0] p0, p1, p2;
    wire        pressure_valid;

    reg nack_addr_en, nack_data_en;

    pullup pu_scl (scl);
    pullup pu_sda (sda);

    ads1115_ctrl #(
        .ENABLE (1)
    ) u_adc (
        .clk              (clk),
        .rst_n_sync       (rst_n),
        .adc_i2c_scl      (scl),
        .adc_i2c_sda      (sda),
        .adc_ch0_raw      (ch0_raw),
        .adc_ch1_raw      (ch1_raw),
        .adc_ch2_raw      (ch2_raw),
        .adc_sample_valid (sample_valid),
        .adc_busy         (adc_busy),
        .adc_error        (adc_error),
        .error_code       (adc_err_code)
    );

    ads1115_model #(
        .DEVICE_ADDR (7'h48),
        .CONV_CYCLES (2000),
        .VAL_AIN0    (16'hFFFF),   // 负码(-1):零附近噪声
        .VAL_AIN1    (16'd1000),
        .VAL_AIN2    (16'd2500)
    ) u_model (
        .clk             (clk),
        .rst             (~rst_n),
        .nack_addr_en    (nack_addr_en),
        .nack_data_en    (nack_data_en),
        .conv_never_done (1'b0),
        .scl             (scl),
        .sda             (sda)
    );

    pressure_processor #(
        .CH0_ZERO (15'd0),
        .CH1_ZERO (15'd100),
        .CH2_ZERO (15'd200)
    ) u_pressure (
        .clk              (clk),
        .rst_n_sync       (rst_n),
        .adc_ch0_raw      (ch0_raw),
        .adc_ch1_raw      (ch1_raw),
        .adc_ch2_raw      (ch2_raw),
        .adc_sample_valid (sample_valid),
        .pressure_ch0     (p0),
        .pressure_ch1     (p1),
        .pressure_ch2     (p2),
        .pressure_valid   (pressure_valid)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer checks;
    integer errors;
    integer frame_cnt;

    task check_true;
        input            cond;
        input [8*56-1:0] label;
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

    task check3;
        input [14:0]     e0;
        input [14:0]     e1;
        input [14:0]     e2;
        input [8*56-1:0] label;
        begin
            checks = checks + 1;
            if ((last_p0 !== e0) || (last_p1 !== e1) || (last_p2 !== e2)) begin
                errors = errors + 1;
                $display("FAIL: %0s: got (%0d,%0d,%0d) expected (%0d,%0d,%0d)",
                         label, last_p0, last_p1, last_p2, e0, e1, e2);
            end else begin
                $display("  ok: %0s: P=(%0d,%0d,%0d)", label, last_p0, last_p1, last_p2);
            end
        end
    endtask

    // 记录每个 pressure_valid 时的三路输出(用于最后一次检查)
    reg [14:0] last_p0, last_p1, last_p2;
    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            frame_cnt = 0;
            last_p0 = 0; last_p1 = 0; last_p2 = 0;
        end else begin
            if (pressure_valid === 1'b1) begin
                frame_cnt  = frame_cnt + 1;
                last_p0    = p0;
                last_p1    = p1;
                last_p2    = p2;
            end
        end
    end

    initial begin
        checks = 0;
        errors = 0;
        frame_cnt = 0;
        nack_addr_en = 1'b0;
        nack_data_en = 1'b0;
        clk  = 1'b0;
        rst_n= 1'b0;
        last_p0 = 0; last_p1 = 0; last_p2 = 0;

        $display("TB_ADS1115_PRESSURE_PIPELINE: start");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        //---------------------------------------------------------------------
        // 等三轮完整扫描帧(每帧含转换等待 + OS 轮询 + 三通道读)
        //---------------------------------------------------------------------
        begin : WAIT_FRAMES
            integer g;
            g = 0;
            while ((frame_cnt < 3) && (g < 200000)) begin
                @(posedge clk);
                g = g + 1;
            end
            checks = checks + 1;
            if (frame_cnt < 3) begin
                errors = errors + 1;
                $display("FAIL: only %0d frames in 200k cycles", frame_cnt);
            end else begin
                $display("  ok: 3 complete scan frames captured");
            end
        end

        //---------------------------------------------------------------------
        // 端到端数值(§47):负码 -> 0;零点校正 -> 900 / 2300
        //---------------------------------------------------------------------
        check3(15'd0,    15'd900, 15'd2300, "P=(0,900,2300) after full frames");
        check_true(adc_err_code === 3'd0, "no ADC error in normal path");

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("TB_ADS1115_PRESSURE_PIPELINE: PASS (checks=%0d, errors=0, frames=%0d)",
                     checks, frame_cnt);
        end else begin
            $display("TB_ADS1115_PRESSURE_PIPELINE: FAIL (checks=%0d, errors=%0d, frames=%0d)",
                     checks, errors, frame_cnt);
        end

        $finish;
    end

endmodule
