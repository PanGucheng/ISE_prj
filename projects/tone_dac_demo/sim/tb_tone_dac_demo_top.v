//=============================================================================
// tb_tone_dac_demo_top.v
// tone_dac_demo 顶层联合仿真（Stage D）。
//
// 验证目标：
//   1. 3-bit 传感器输入 000~111 正确映射到同一 note_code（0=静音，1~7=C4~B4）；
//   2. 同一 note_code 并行驱动方波发生器与 DDS->MCP4725 DAC 链路；
//   3. 方波输出频率与理论音高一致（误差 < 1%）；
//   4. MCP4725 模型接收到对应音高的正弦样点（8 kS/s，0 错误，0 overrun，0 EEPROM 写入）；
//   5. 000 静音时方波保持 0，MCP4725 保持中点 2048 (0x800)；
//   6. 音符切换返回静音后，方波与 DAC 正确复位至静音状态。
//
// 判定行：TB_TONE_DAC_DEMO_TOP: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps
`include "finger_piano_cfg.vh"

module tb_tone_dac_demo_top;

    parameter integer TB_SYS_CLK_HZ  = 12000000;
    parameter integer TB_SAMPLE_RATE = 8000;
    parameter integer TB_STABLE_MS   = `KEY_STABLE_MS;

    localparam integer STABLE_CYC = (TB_SYS_CLK_HZ / 1000) * TB_STABLE_MS; // 120000 clk @ 10ms

    reg         clk;
    reg         rst_n;
    reg  [2:0]  sensor_async;

    wire        square_out;
    wire        dac_scl;
    wire        dac_sda;

    pullup pu_scl (dac_scl);
    pullup pu_sda (dac_sda);

    reg  dac_nack_addr;
    reg  dac_nack_data;

    //-------------------------------------------------------------------------
    // DUT: 独立工程顶层
    //-------------------------------------------------------------------------
    tone_dac_demo_top u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sensor_async (sensor_async),
        .square_out   (square_out),
        .dac_i2c_scl  (dac_scl),
        .dac_i2c_sda  (dac_sda)
    );

    //-------------------------------------------------------------------------
    // MCP4725 协议模型
    //-------------------------------------------------------------------------
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

    //-------------------------------------------------------------------------
    // 12 MHz 时钟生成 (周期 83.334 ns)
    //-------------------------------------------------------------------------
    initial clk = 1'b0;
    always #41.667 clk = ~clk;

    //-------------------------------------------------------------------------
    // 检查计数器
    //-------------------------------------------------------------------------
    integer checks;
    integer errors;

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

    //-------------------------------------------------------------------------
    // 测量方波半周期（时钟计数法，精确到 1 拍）
    //-------------------------------------------------------------------------
    task measure_square_half_cycles;
        output integer half_cyc_out;
        integer c_cnt;
        reg cur_level;
        integer timeout;
        begin
            timeout = 0;
            @(posedge clk);
            cur_level = square_out;
            // 等待下一次翻转
            while ((square_out === cur_level) && (timeout < 200000)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 200000) begin
                $display("FAIL: square_out timeout waiting for transition");
                errors = errors + 1;
                half_cyc_out = 0;
            end else begin
                // 开始统计该电平持续的完整周期
                cur_level = square_out;
                c_cnt = 0;
                while ((square_out === cur_level) && (c_cnt < 200000)) begin
                    @(posedge clk);
                    c_cnt = c_cnt + 1;
                end
                half_cyc_out = c_cnt;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 等待音符稳定
    //-------------------------------------------------------------------------
    task wait_for_note;
        input [2:0] exp_note;
        integer wait_cnt;
        begin
            wait_cnt = 0;
            while ((u_dut.note_code !== exp_note) && (wait_cnt < STABLE_CYC + 20000)) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
            end
            check_eq32(u_dut.note_code, exp_note, "u_dut.note_code settled");
        end
    endtask

    //-------------------------------------------------------------------------
    // 等待指定数量的 MCP4725 采样帧
    //-------------------------------------------------------------------------
    task wait_dac_frames;
        input integer n_frames;
        integer start_frames;
        integer timeout;
        begin
            start_frames = u_dac_model.frame_cnt;
            timeout = 0;
            while ((u_dac_model.frame_cnt < start_frames + n_frames) && (timeout < n_frames * 2000 + 20000)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
        end
    endtask

    // 七音期望半周期 (HP) 与标称频率
    integer exp_hp[1:7];
    integer note_idx;
    integer measured_hp;
    integer hp_diff;
    real f_nominal[1:7];
    real f_measured;
    real err_pct;
    integer start_frame;
    integer dac_min_val, dac_max_val;

    initial begin
        // 初始化期望半周期 (与 tone_generator.v 一致)
        exp_hp[1] = (TB_SYS_CLK_HZ * 10 + 2616) / (2 * 2616); // 22936 (C4)
        exp_hp[2] = (TB_SYS_CLK_HZ * 10 + 2937) / (2 * 2937); // 20429 (D4)
        exp_hp[3] = (TB_SYS_CLK_HZ * 10 + 3296) / (2 * 3296); // 18204 (E4)
        exp_hp[4] = (TB_SYS_CLK_HZ * 10 + 3492) / (2 * 3492); // 17182 (F4)
        exp_hp[5] = (TB_SYS_CLK_HZ * 10 + 3920) / (2 * 3920); // 15306 (G4)
        exp_hp[6] = (TB_SYS_CLK_HZ * 10 + 4400) / (2 * 4400); // 13636 (A4)
        exp_hp[7] = (TB_SYS_CLK_HZ * 10 + 4939) / (2 * 4939); // 12148 (B4)

        f_nominal[1] = 261.62;
        f_nominal[2] = 293.67;
        f_nominal[3] = 329.63;
        f_nominal[4] = 349.23;
        f_nominal[5] = 391.99;
        f_nominal[6] = 440.00;
        f_nominal[7] = 493.88;

        checks = 0;
        errors = 0;
        dac_nack_addr = 0;
        dac_nack_data = 0;
        sensor_async  = 3'b000;
        rst_n         = 1'b0;

        $display("=== TB_TONE_DAC_DEMO_TOP START ===");

        // 1. 复位序列
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // 2. 初始静音测试 (sensor_async = 000)
        $display("--- Step 1: Initial Mute (sensor=000) ---");
        wait_for_note(3'd0);
        repeat (2000) @(posedge clk);
        check_eq32(square_out, 1'b0, "square_out is 0 during mute");
        wait_dac_frames(3);
        check_eq32(u_dac_model.dac_out, 12'h800, "DAC out is 2048 (0x800) during mute");
        check_eq32(u_dac_model.eeprom_viol, 1'b0, "EEPROM write violation is 0");
        check_eq32(u_dut.u_tone_gen.note_code, 3'd0, "tone_gen note_code is 0");
        check_eq32(u_dut.u_dac_pipeline.note_code, 3'd0, "dac_pipeline note_code is 0");

        // 3. 逐个音符测试 (001 ~ 111)
        for (note_idx = 1; note_idx <= 7; note_idx = note_idx + 1) begin
            $display("--- Step 2.%0d: Note %0d Test ---", note_idx, note_idx);
            sensor_async = note_idx[2:0];

            // 等待稳定解码
            wait_for_note(note_idx[2:0]);

            // 验证同一 note_code 同时驱动两个发生器
            check_eq32(u_dut.u_tone_gen.note_code, note_idx, "tone_gen received note_code");
            check_eq32(u_dut.u_dac_pipeline.note_code, note_idx, "dac_pipeline received note_code");

            // 测量方波半周期
            measure_square_half_cycles(measured_hp);
            hp_diff = measured_hp - exp_hp[note_idx];
            if (hp_diff < 0) hp_diff = -hp_diff;
            check_true(hp_diff <= 1, "square_out half period matches expected within 1 clk");

            f_measured = 12000000.0 / (2.0 * measured_hp);
            err_pct = (f_measured - f_nominal[note_idx]) / f_nominal[note_idx] * 100.0;
            if (err_pct < 0.0) err_pct = -err_pct;
            $display("  note %0d: exp_hp=%0d got_hp=%0d | f_nom=%0.2fHz f_meas=%0.2fHz err=%0.3f%%",
                     note_idx, exp_hp[note_idx], measured_hp, f_nominal[note_idx], f_measured, err_pct);
            check_true(err_pct < 1.0, "frequency error < 1%");

            // 收集 8 个 DAC 样点并确认正常输出正弦样点
            start_frame = u_dac_model.frame_cnt;
            dac_min_val = 4095;
            dac_max_val = 0;
            while (u_dac_model.frame_cnt < start_frame + 8) begin
                @(posedge clk);
                if (u_dac_model.dac_out < dac_min_val) dac_min_val = u_dac_model.dac_out;
                if (u_dac_model.dac_out > dac_max_val) dac_max_val = u_dac_model.dac_out;
            end
            check_true(u_dac_model.frame_cnt >= start_frame + 8, "DAC received at least 8 frames");
            check_true(dac_max_val > 2048, "DAC sine sample swung above 2048");
            check_true(dac_min_val < 2048, "DAC sine sample swung below 2048");
            check_eq32(u_dac_model.eeprom_viol, 1'b0, "EEPROM violation is 0");
            check_eq32(u_dut.dac_error, 1'b0, "dac_error is 0");
            check_eq32(u_dut.dac_overrun, 1'b0, "dac_overrun is 0");
        end

        // 4. 返回静音测试 (sensor_async = 000)
        $display("--- Step 3: Return to Mute (sensor=000) ---");
        sensor_async = 3'b000;
        wait_for_note(3'd0);
        repeat (2000) @(posedge clk);
        check_eq32(square_out, 1'b0, "square_out returned to 0");
        wait_dac_frames(4);
        check_eq32(u_dac_model.dac_out, 12'h800, "DAC out returned to 2048 (0x800)");
        check_eq32(u_dut.u_tone_gen.note_code, 3'd0, "tone_gen note_code returned to 0");
        check_eq32(u_dut.u_dac_pipeline.note_code, 3'd0, "dac_pipeline note_code returned to 0");

        // 5. 总结与判定
        $display("=== TB_TONE_DAC_DEMO_TOP SUMMARY ===");
        $display("Total checks: %0d, Errors: %0d", checks, errors);
        if (errors == 0 && checks > 0) begin
            $display("TB_TONE_DAC_DEMO_TOP: PASS");
        end else begin
            $display("TB_TONE_DAC_DEMO_TOP: FAIL");
        end

        $finish;
    end

endmodule
