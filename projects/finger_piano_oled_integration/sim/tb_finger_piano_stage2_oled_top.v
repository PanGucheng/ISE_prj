//=============================================================================
// tb_finger_piano_stage2_oled_top.v
// Stage-2 OLED 集成顶层系统级协同仿真 (P6B + OLED 集成验收)
//
// 验证特性：
//   1. 上电与复位同步 (reset_sync -> rst_n_sync)；
//   2. 三条独立 I2C 总线并行 (ADS1115 ADC + MCP4725 DAC + SSD1306 OLED)；
//   3. OLED 初始化序列 (27 字节命令 + 8 页清零 + 标题栏 + MUTE 初始显示)；
//   4. 音符切换 (MUTE -> C4 -> D4) 与 note_debug 输出；
//   5. DAC 样点逐样点评分：MUTE 恒为 12'h800 偏置，发声时正弦振幅范围覆盖 (256~3840)；
//   6. ADC 转换帧检查：AIN0/1/2 持续解算为 1000/2000/3000，且无总线错误；
//   7. 并行性与真实 NACK 故障隔离：在真实 OLED I2C 事务 ACK 槽注入 NACK，
//      验证 OLED 控制器检测 NACK、发出 STOP、置位 oled_error 停机、释放总线，
//      且此过程中 ADC 轮询与 DAC 音频样点完全不受影响、持续正常运行；
//   8. 运行途中复位：三条 I2C 总线均释放为高阻开漏状态。
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
    // 背景持续监视器：ADC 帧收集与 DAC 样点评分
    //-------------------------------------------------------------------------
    integer adc_frame_cnt = 0;
    reg [15:0] last_adc_ch0 = 16'd0;
    reg [15:0] last_adc_ch1 = 16'd0;
    reg [15:0] last_adc_ch2 = 16'd0;

    always @(posedge clk) begin
        if (rst_n && u_top.u_piano.u_sys.GEN_ADC_ON.u_ads1115.adc_sample_valid) begin
            adc_frame_cnt <= adc_frame_cnt + 1;
            last_adc_ch0  <= u_top.u_piano.u_sys.GEN_ADC_ON.u_ads1115.adc_ch0_raw;
            last_adc_ch1  <= u_top.u_piano.u_sys.GEN_ADC_ON.u_ads1115.adc_ch1_raw;
            last_adc_ch2  <= u_top.u_piano.u_sys.GEN_ADC_ON.u_ads1115.adc_ch2_raw;
        end
    end

    integer dac_mute_errors = 0;
    integer dac_active_samples = 0;
    reg [11:0] dac_min_sample = 12'hFFF;
    reg [11:0] dac_max_sample = 12'h000;
    reg track_dac_active = 1'b0;

    always @(posedge clk) begin
        if (rst_n && u_top.u_piano.u_sys.GEN_DAC_ON.u_dac_pipeline.dds_valid_debug) begin
            if (note_debug == 3'b000) begin
                if (u_top.u_piano.u_sys.GEN_DAC_ON.u_dac_pipeline.dds_code_debug !== 12'h800) begin
                    dac_mute_errors <= dac_mute_errors + 1;
                end
            end else if (track_dac_active) begin
                dac_active_samples <= dac_active_samples + 1;
                if (u_top.u_piano.u_sys.GEN_DAC_ON.u_dac_pipeline.dds_code_debug < dac_min_sample)
                    dac_min_sample <= u_top.u_piano.u_sys.GEN_DAC_ON.u_dac_pipeline.dds_code_debug;
                if (u_top.u_piano.u_sys.GEN_DAC_ON.u_dac_pipeline.dds_code_debug > dac_max_sample)
                    dac_max_sample <= u_top.u_piano.u_sys.GEN_DAC_ON.u_dac_pipeline.dds_code_debug;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 仿真测试流程
    //-------------------------------------------------------------------------
    integer errors = 0;
    integer prev_dac_cnt = 0;
    integer prev_adc_cnt = 0;
    integer nack_scl_edges = 0;

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
        track_dac_active = 1'b0;

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

        // 1. 检查 MUTE 下 DAC 样点逐样点评分
        if (dac_write_cnt == 0) begin
            $display("[TB] ERROR: DAC write count is 0!");
            errors = errors + 1;
        end else if (dac_mute_errors > 0) begin
            $display("[TB] ERROR: DAC mute code error: %0d non-0x800 samples detected!", dac_mute_errors);
            errors = errors + 1;
        end else begin
            $display("[TB] DAC MUTE verified: %0d writes recorded, all 12'h800 midpoint.", dac_write_cnt);
        end

        // 2. 检查 ADC 转换帧接收与通道读数
        if (adc_frame_cnt == 0) begin
            $display("[TB] ERROR: No ADC conversion frames received!");
            errors = errors + 1;
        end else if (last_adc_ch0 !== 16'd1000 || last_adc_ch1 !== 16'd2000 || last_adc_ch2 !== 16'd3000) begin
            $display("[TB] ERROR: ADC conversion value mismatch! CH0=%0d (exp 1000), CH1=%0d (exp 2000), CH2=%0d (exp 3000)",
                     last_adc_ch0, last_adc_ch1, last_adc_ch2);
            errors = errors + 1;
        end else begin
            $display("[TB] ADC conversion frames verified: %0d frames received, CH0=1000, CH1=2000, CH2=3000.", adc_frame_cnt);
        end

        // 3. 切换音符到 C4 (001) 并开启 DAC 动态波形统计
        $display("[TB] Applying sensor input C4 (001)...");
        track_dac_active = 1'b1;
        apply_sensor(3'b001);
        if (note_debug !== 3'b001) begin
            $display("[TB] ERROR: note_debug expected 001, got %b", note_debug);
            errors = errors + 1;
        end else begin
            $display("[TB] note_debug 001 verified.");
        end

        // 等待 OLED 完成 C4 音符刷新 (4 页 x 64 字节 ≈ 32 ms ≈ 400k 周期)
        repeat (500000) @(posedge clk);

        // 校验 C4 下 DAC 动态正弦波形统计
        if (dac_active_samples < 200) begin
            $display("[TB] ERROR: Too few active DAC samples recorded: %0d", dac_active_samples);
            errors = errors + 1;
        end else if (dac_min_sample > 12'd1000 || dac_max_sample < 12'd3000 ||
                     dac_min_sample < 12'd256  || dac_max_sample > 12'd3840) begin
            $display("[TB] ERROR: DAC sine wave span out of bounds! min=%0d (exp <=1000, >=256), max=%0d (exp >=3000, <=3840)",
                     dac_min_sample, dac_max_sample);
            errors = errors + 1;
        end else begin
            $display("[TB] DAC active waveform verified: %0d samples, min=%0d, max=%0d (proper sine oscillation).",
                     dac_active_samples, dac_min_sample, dac_max_sample);
        end

        // 4. 快速回跳测试：D4 (010) -> E4 (011) -> D4 (010)
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

        // 等待 D4 刷新完成回到 IDLE
        repeat (500000) @(posedge clk);

        // 5. 错误隔离测试：在真实 OLED I2C 事务中注入 NACK
        $display("[TB] Testing OLED error isolation with REAL NACK injection during active transaction...");
        
        // 触发一次新的音符切换 (切到 E4 / 3'b011)，使 OLED 控制器启动新的刷新事务
        sensor_async = 3'b011;
        repeat (STABLE_CYC + 200) @(posedge clk);

        // 等待 OLED 控制器离开 IDLE 并产生 SCL 活跃时钟 (有界循环)
        begin : WAIT_OLED_BUSY
            integer w_cnt;
            w_cnt = 0;
            while (oled_scl !== 1'b0 && w_cnt < 200000) begin
                @(posedge clk);
                w_cnt = w_cnt + 1;
            end
            if (oled_scl === 1'b0) begin
                $display("[TB] OLED I2C bus active transmission detected (SCL low). Injecting NACK now...");
            end else begin
                $display("[TB] ERROR: Timeout waiting for OLED I2C transaction to start!");
                errors = errors + 1;
            end
        end

        // 注入 NACK，并精确统计 SCL 边沿与等待 oled_error (有界循环)
        oled_inject_nack = 1'b1;
        nack_scl_edges   = 0;
        begin : WAIT_NACK_ERR
            integer n_cnt;
            reg last_scl;
            n_cnt = 0;
            last_scl = oled_scl;
            while (u_top.u_oled_ctrl.oled_error !== 1'b1 && n_cnt < 200000) begin
                @(posedge clk);
                if (last_scl === 1'b1 && oled_scl === 1'b0) begin
                    nack_scl_edges = nack_scl_edges + 1;
                end
                last_scl = oled_scl;
                n_cnt = n_cnt + 1;
            end
            oled_inject_nack = 1'b0;

            if (u_top.u_oled_ctrl.oled_error === 1'b1) begin
                $display("[TB] oled_error asserted as expected! SCL falling edges during injection=%0d", nack_scl_edges);
            end else begin
                $display("[TB] ERROR: Timeout waiting for oled_error upon NACK! edges=%0d, seq_state=%0d",
                         nack_scl_edges, u_top.u_oled_ctrl.seq_state);
                errors = errors + 1;
            end
        end

        // 严格断言故障注入生效且硬件保护动作完备
        if (nack_scl_edges == 0) begin
            $display("[TB] ERROR: NACK injection occurred while SCL had 0 edges (no actual transaction)!");
            errors = errors + 1;
        end else begin
            $display("[TB] NACK injected during active transaction confirmed (SCL edges=%0d).", nack_scl_edges);
        end

        if (u_top.u_oled_ctrl.oled_error !== 1'b1) begin
            $display("[TB] ERROR: u_oled_ctrl.oled_error is not 1!");
            errors = errors + 1;
        end

        if (u_top.u_oled_ctrl.init_done !== 1'b0) begin
            $display("[TB] ERROR: u_oled_ctrl.init_done is not cleared to 0!");
            errors = errors + 1;
        end

        // 等待 STOP 完成，检查总线释放回高阻 (外部上拉为 1'b1)
        repeat (100) @(posedge clk);
        if (oled_scl !== 1'b1 || oled_sda !== 1'b1) begin
            $display("[TB] ERROR: OLED I2C bus not cleanly released after error: SCL=%b, SDA=%b",
                     oled_scl, oled_sda);
            errors = errors + 1;
        end else begin
            $display("[TB] OLED I2C bus cleanly released to high-Z after error.");
        end

        // 6. 确认在 OLED 严重停机故障期间，ADC 和 DAC 持续完全不受干扰地正常运行
        $display("[TB] Verifying ADC and DAC continuous operation during OLED error state...");
        begin
            prev_dac_cnt = dac_write_cnt;
            prev_adc_cnt = adc_frame_cnt;
            repeat (60000) @(posedge clk);

            if (dac_write_cnt <= prev_dac_cnt + 5) begin
                $display("[TB] ERROR: DAC stopped or degraded during OLED error state! writes=%0d -> %0d",
                         prev_dac_cnt, dac_write_cnt);
                errors = errors + 1;
            end else begin
                $display("[TB] DAC continues streaming normally during OLED error (%0d writes added).",
                         dac_write_cnt - prev_dac_cnt);
            end

            if (adc_frame_cnt <= prev_adc_cnt) begin
                $display("[TB] ERROR: ADC polling stopped during OLED error state! frames=%0d -> %0d",
                         prev_adc_cnt, adc_frame_cnt);
                errors = errors + 1;
            end else begin
                $display("[TB] ADC continues polling normally during OLED error (%0d frames added).",
                         adc_frame_cnt - prev_adc_cnt);
            end

            if (u_top.u_piano.u_sys.GEN_ADC_ON.u_ads1115.adc_error !== 1'b0) begin
                $display("[TB] ERROR: ADC reported unexpected error during OLED failure!");
                errors = errors + 1;
            end
        end

        // 7. 途中复位测试：复位时验证三总线释放
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
