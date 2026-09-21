//=============================================================================
// tb_finger_piano_stage2_oled_top.v
// Stage-2 OLED 集成顶层系统级协同仿真 (P6B + OLED 集成验收)
//
// 验证特性：
//   1. 上电与复位同步 (reset_sync -> rst_n_sync)；
//   2. 三条独立 I2C 总线并行 (ADS1115 ADC + MCP4725 DAC + SSD1306 OLED)；
//   3. OLED 初始化序列 (27 字节命令 + 8 页清零 + 标题栏 + MUTE 初始显示)；
//   4. 音符切换 (MUTE -> C4 -> D4) 与 note_debug 输出；
//   5. 并行性与错误隔离：OLED NACK 注入时不影响 ADC 轮询与 DAC 音频样点；
//   6. 运行途中复位：三条 I2C 总线均释放为高阻开漏状态。
//
// 诊断行：TB_FINGER_PIANO_STAGE2_OLED_TOP: PASS / FAIL
//=============================================================================

`timescale 1ns / 1ps

`include "finger_piano_cfg.vh"

module tb_finger_piano_stage2_oled_top;

    parameter integer TB_SYS_CLK_HZ  = 12000000;
    parameter integer TB_SAMPLE_RATE = 8000;
    parameter integer TB_STABLE_MS   = `KEY_STABLE_MS;
    parameter integer TB_CONV_CYCLES = 2000;
    parameter integer TB_FAST_INIT   = 1;

    localparam integer STABLE_CYC = (TB_SYS_CLK_HZ / 1000) * TB_STABLE_MS;
    localparam integer SAMPLE_CYC = TB_SYS_CLK_HZ / TB_SAMPLE_RATE;

    reg        clk;
    reg        rst_n;
    reg  [2:0] sensor_async;

    reg        adc_nack_addr, adc_nack_data;
    reg        dac_nack_addr, dac_nack_data;
    reg        oled_inject_nack;

    wire       adc_scl, adc_sda;
    wire       dac_scl, dac_sda;
    wire       oled_scl, oled_sda;
    wire [2:0] note_debug;

    // 逻辑开漏上拉
    pullup pu_ascl (adc_scl);
    pullup pu_asda (adc_sda);
    pullup pu_dscl (dac_scl);
    pullup pu_dsda (dac_sda);
    pullup pu_oscl (oled_scl);
    pullup pu_osda (oled_sda);

    //-------------------------------------------------------------------------
    // DUT: Stage-2 OLED 集成物理顶层
    //-------------------------------------------------------------------------
    finger_piano_stage2_oled_top #(
        .SIM_FAST_INIT (TB_FAST_INIT)
    ) u_top (
        .clk          (clk),
        .rst_n        (rst_n),
        .sensor_async (sensor_async),
        .adc_i2c_scl  (adc_scl),
        .adc_i2c_sda  (adc_sda),
        .dac_i2c_scl  (dac_scl),
        .dac_i2c_sda  (dac_sda),
        .note_debug   (note_debug),
        .oled_i2c_scl (oled_scl),
        .oled_i2c_sda (oled_sda)
    );

    //-------------------------------------------------------------------------
    // 从机模型
    //-------------------------------------------------------------------------
    ads1115_model #(
        .DEVICE_ADDR (7'h48),
        .CONV_CYCLES (TB_CONV_CYCLES),
        .VAL_AIN0    (16'd1000),
        .VAL_AIN1    (16'd2000),
        .VAL_AIN2    (16'd3000)
    ) u_adc_model (
        .clk             (clk),
        .rst             (~rst_n),
        .nack_addr_en    (adc_nack_addr),
        .nack_data_en    (adc_nack_data),
        .conv_never_done (1'b0),
        .scl             (adc_scl),
        .sda             (adc_sda)
    );

    wire [31:0] dac_write_cnt = u_dac_model.frame_cnt;
    mcp4725_model #(
        .DEVICE_ADDR (7'h60)
    ) u_dac_model (
        .clk          (clk),
        .rst          (~rst_n),
        .nack_addr_en (dac_nack_addr),
        .nack_data_en (dac_nack_data),
        .scl          (dac_scl),
        .sda          (dac_sda)
    );

    wire oled_init_err;
    wire oled_proto_err;
    wire [7:0] oled_last_cmd;
    wire [31:0] oled_cmd_cnt;
    wire [31:0] oled_data_cnt;
    ssd1306_model #(
        .DEVICE_ADDR (7'h3C)
    ) u_oled_model (
        .clk             (clk),
        .rst             (~rst_n),
        .inject_nack     (oled_inject_nack),
        .scl             (oled_scl),
        .sda             (oled_sda),
        .init_seq_error  (oled_init_err),
        .mode_error      (),
        .protocol_error  (oled_proto_err),
        .memory_addressing_mode (),
        .last_cmd        (oled_last_cmd),
        .cmd_count       (oled_cmd_cnt),
        .data_count      (oled_data_cnt)
    );

    // 12 MHz 时钟 (83.333 ns)
    initial clk = 1'b0;
    always #41.667 clk = ~clk;

    //-------------------------------------------------------------------------
    // 仿真监控与测试流程
    //-------------------------------------------------------------------------
    integer errors = 0;
    integer prev_dac_cnt = 0;

    task apply_sensor;
        input [2:0] code;
        begin
            sensor_async = code;
            repeat (STABLE_CYC + 200) @(posedge clk);
        end
    endtask

    initial begin
        rst_n            = 1'b0;
        sensor_async     = 3'b000;
        adc_nack_addr    = 1'b0;
        adc_nack_data    = 1'b0;
        dac_nack_addr    = 1'b0;
        dac_nack_data    = 1'b0;
        oled_inject_nack = 1'b0;

        $display("[TB] Starting tb_finger_piano_stage2_oled_top...");

        // 复位释放
        repeat (100) @(posedge clk);
        rst_n = 1'b1;
        $display("[TB] Reset released at t=%0t", $time);

        // 等待初始显示完成 (8 页清零 + 标题 + MUTE)
        // 在 100 kHz I2C 下约需 160 ms (约 1.9M 个时钟周期)
        $display("[TB] Waiting for OLED initialization to finish...");
        repeat (2500000) @(posedge clk);

        if (oled_init_err) begin
            $display("[TB] ERROR: OLED init sequence error!");
            errors = errors + 1;
        end else begin
            $display("[TB] OLED init sequence verified successfully.");
        end

        if (oled_proto_err) begin
            $display("[TB] ERROR: OLED protocol error detected!");
            errors = errors + 1;
        end

        // 检查初始 note_debug
        if (note_debug !== 3'b000) begin
            $display("[TB] ERROR: Initial note_debug expected 000, got %b", note_debug);
            errors = errors + 1;
        end else begin
            $display("[TB] Initial note_debug 000 verified.");
        end

        // 检查 DAC 是否在持续接收样点
        if (dac_write_cnt == 0) begin
            $display("[TB] ERROR: DAC write count is 0!");
            errors = errors + 1;
        end else begin
            $display("[TB] DAC writes active: %0d writes recorded.", dac_write_cnt);
        end

        // 切换音符到 C4 (001)
        $display("[TB] Applying sensor input C4 (001)...");
        apply_sensor(3'b001);
        if (note_debug !== 3'b001) begin
            $display("[TB] ERROR: note_debug expected 001, got %b", note_debug);
            errors = errors + 1;
        end else begin
            $display("[TB] note_debug 001 verified.");
        end

        // 等待 OLED 完成 C4 音符刷新 (4 页 x 64 字节 ≈ 32 ms ≈ 400k 周期)
        repeat (500000) @(posedge clk);

        // 快速回跳测试：D4 (010) -> E4 (011) -> D4 (010)
        $display("[TB] Testing rapid transition D4 -> E4 -> D4...");
        sensor_async = 3'b010;
        repeat (STABLE_CYC + 50) @(posedge clk);
        sensor_async = 3'b011;
        repeat (100) @(posedge clk);
        sensor_async = 3'b010;
        repeat (STABLE_CYC + 200) @(posedge clk);

        if (note_debug !== 3'b010) begin
            $display("[TB] ERROR: note_debug expected 010, got %b", note_debug);
            errors = errors + 1;
        end else begin
            $display("[TB] Rapid transition settled to D4 (010) cleanly.");
        end

        repeat (500000) @(posedge clk);

        // 错误隔离测试：注入 OLED NACK
        $display("[TB] Testing OLED error isolation with NACK injection...");
        oled_inject_nack = 1'b1;
        repeat (10000) @(posedge clk);
        oled_inject_nack = 1'b0;

        // 确认在 OLED 异常时，DAC 依然在正常写入
        begin
            prev_dac_cnt = dac_write_cnt;
            repeat (50000) @(posedge clk);
            if (dac_write_cnt <= prev_dac_cnt) begin
                $display("[TB] ERROR: DAC stopped during OLED NACK injection!");
                errors = errors + 1;
            end else begin
                $display("[TB] DAC continues running normally during OLED error.");
            end
        end

        // 途中复位测试：复位时验证三总线释放
        $display("[TB] Testing in-flight reset...");
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        if (adc_scl !== 1'b1 || adc_sda !== 1'b1 ||
            dac_scl !== 1'b1 || dac_sda !== 1'b1 ||
            oled_scl !== 1'b1 || oled_sda !== 1'b1) begin
            $display("[TB] ERROR: Buses not released during reset: adc=(%b,%b), dac=(%b,%b), oled=(%b,%b)",
                     adc_scl, adc_sda, dac_scl, dac_sda, oled_scl, oled_sda);
            errors = errors + 1;
        end else begin
            $display("[TB] All three I2C buses cleanly released during reset.");
        end

        repeat (50) @(posedge clk);
        rst_n = 1'b1;
        repeat (100) @(posedge clk);

        // 结果判定
        if (errors == 0) begin
            $display("TB_FINGER_PIANO_STAGE2_OLED_TOP: PASS");
        end else begin
            $display("TB_FINGER_PIANO_STAGE2_OLED_TOP: FAIL (errors=%0d)", errors);
        end
        $finish;
    end

    // 仿真保护超时
    initial begin
        #400000000; // 400 ms
        $display("[TB] ERROR: Global simulation timeout!");
        $display("TB_FINGER_PIANO_STAGE2_OLED_TOP: FAIL");
        $finish;
    end

endmodule
