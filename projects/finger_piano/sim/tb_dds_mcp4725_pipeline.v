//=============================================================================
// tb_dds_mcp4725_pipeline.v — DDS→MCP4725 端到端验收(P4 计划 Commit B~D)
//
// 四套仿真共用本 TB,由 TB_MODE 区分(P4 计划 §37):
//   dds_mcp4725_pipeline          TB_MODE=0  基础端到端(快速时钟)
//   dds_mcp4725_pipeline_12m      TB_MODE=1  真实 12 MHz 吞吐(4096 样点)
//   dds_mcp4725_pipeline_error    TB_MODE=2  NACK/mid-tx reset/过载恢复
//                                            (地址用 7'h61 证明可参数化,§31)
//   dds_mcp4725_pipeline_disabled TB_MODE=3  ENABLE=0 静默
//
// Scoreboard(§13/§14/§21):DDS 每个样点(dac_code_valid)压入 expected
// 队列;MCP4725 模型每完成一次 Fast Write 弹出队首逐一比对——防止样点错位、
// 重复旧值、丢样后整体错位、字节拆分错误。附加统计:
//   - ready 时序(§20):每个 dds_valid 采样沿 dac_ready 必须为 1;
//   - 事务延迟(§19):valid -> write 完成最大延迟 < 采样周期;
//   - EEPROM 违规计数(§30)恒 0。
//
// 诊断文本全 ASCII。判定行:TB_DDS_MCP4725_PIPELINE: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_dds_mcp4725_pipeline;

    parameter integer TB_SYS_CLK_HZ     = 12000000;
    parameter integer TB_SAMPLE_RATE_HZ = 8000;
    parameter integer TB_DAC_I2C_HZ     = 333333;
    parameter [6:0]   TB_ADDR           = 7'h60;
    parameter integer TB_MODE           = 0;   // 0 basic/1 throughput/2 error/3 disabled

    localparam integer SAMPLE_DIV = TB_SYS_CLK_HZ / TB_SAMPLE_RATE_HZ;
    localparam integer TB_ENABLE  = (TB_MODE == 3) ? 0 : 1;

    reg         clk;
    reg         rst_n;
    reg  [2:0]  note_code;
    wire        scl, sda;
    wire        dac_busy, dac_error, dac_overrun;
    wire [11:0] dds_code_debug;
    wire        dds_valid_debug;
    wire        dac_ready_debug;

    pullup pu_scl (scl);
    pullup pu_sda (sda);

    dds_mcp4725_pipeline #(
        .SYS_CLK_HZ     (TB_SYS_CLK_HZ),
        .SAMPLE_RATE_HZ (TB_SAMPLE_RATE_HZ),
        .DAC_I2C_HZ     (TB_DAC_I2C_HZ),
        .MCP4725_ADDR   (TB_ADDR),
        .ENABLE         (TB_ENABLE)
    ) u_pipe (
        .clk            (clk),
        .rst_n_sync     (rst_n),
        .note_code      (note_code),
        .dac_i2c_scl    (scl),
        .dac_i2c_sda    (sda),
        .dac_busy       (dac_busy),
        .dac_error      (dac_error),
        .dac_overrun    (dac_overrun),
        .dds_code_debug (dds_code_debug),
        .dds_valid_debug(dds_valid_debug),
        .dac_ready_debug(dac_ready_debug)
    );

    mcp4725_model #(
        .DEVICE_ADDR (TB_ADDR)
    ) u_model (
        .clk          (clk),
        .rst          (~rst_n),
        .nack_addr_en (nack_addr_en),
        .nack_data_en (nack_data_en),
        .scl          (scl),
        .sda          (sda)
    );

    reg nack_addr_en, nack_data_en;

    //-------------------------------------------------------------------------
    // 过载故障注入(§29,仅 mode 2):独立 controller 直接高速刺激,
    // 证明 valid && !ready -> overrun 置位且 pending 不被覆盖
    //-------------------------------------------------------------------------
    reg  [11:0] oo_code;
    reg         oo_valid;
    wire        oo_ready, oo_busy, oo_err, oo_over;
    wire [2:0]  oo_ecode;
    wire        oo_scl, oo_sda;

    pullup pu_oscl (oo_scl);
    pullup pu_osda (oo_sda);

    mcp4725_ctrl #(
        .ENABLE     (1),
        .I2C_ADDR   (7'h60),
        .SYS_CLK_HZ (TB_SYS_CLK_HZ),
        .I2C_HZ     (TB_DAC_I2C_HZ)
    ) u_ctrl_oob (
        .clk            (clk),
        .rst_n_sync     (rst_n),
        .dac_code       (oo_code),
        .dac_code_valid (oo_valid),
        .dac_code_ready (oo_ready),
        .dac_busy       (oo_busy),
        .dac_error      (oo_err),
        .dac_overrun    (oo_over),
        .error_code     (oo_ecode),
        .dac_i2c_scl    (oo_scl),
        .dac_i2c_sda    (oo_sda)
    );

    mcp4725_model #(
        .DEVICE_ADDR (7'h60)
    ) u_model_oob (
        .clk          (clk),
        .rst          (~rst_n),
        .nack_addr_en (1'b0),
        .nack_data_en (1'b0),
        .scl          (oo_scl),
        .sda          (oo_sda)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer checks;
    integer errors;

    //-------------------------------------------------------------------------
    // Scoreboard(§13/§21)+ 延迟(§19)+ ready(§20)监视
    //-------------------------------------------------------------------------
    reg [11:0] exp_mem [0:4095];
    reg [31:0] push_time [0:4095];
    reg [11:0] captured_mem [0:4095];
    integer tail, head, captured_n;
    integer sb_mismatch, dropped, err_pulses, ready_fail;
    real    max_lat;
    integer writes_total;
    reg [31:0] prev_frames;
    reg        prev_err;
    reg [31:0] lat_this;

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            tail = 0; head = 0; captured_n = 0;
            sb_mismatch = 0; dropped = 0; err_pulses = 0; ready_fail = 0;
            max_lat = 0.0; writes_total = 0; prev_frames = 32'd0;
            prev_err = 1'b0; lat_this = 32'd0;
        end else begin
            // 错误脉冲:NACK 丢弃当前样点(§27 不重传),scoreboard 跳过
            if (dac_error === 1'b1) begin
                if (prev_err !== 1'b1) begin
                    err_pulses = err_pulses + 1;
                    if (head < tail) begin
                        head = head + 1;      // 该样点失败,跳过期望值
                        dropped = dropped + 1;
                    end
                end
            end
            prev_err = (dac_error === 1'b1);

            // MCP4725 写完成:弹出一个期望样点比对
            if (u_model.frame_cnt > prev_frames) begin
                writes_total = writes_total + 1;
                captured_mem[captured_n] = u_model.dac_out;
                captured_n = captured_n + 1;
                if (head < tail) begin
                    lat_this = $time - push_time[head % 4096];
                    if (lat_this > max_lat) max_lat = lat_this;
                    checks = checks + 1;
                    if (exp_mem[head % 4096] !== u_model.dac_out) begin
                        sb_mismatch = sb_mismatch + 1;
                        $display("FAIL: scoreboard idx=%0d expected=%0h captured=%0h",
                                 head, exp_mem[head % 4096], u_model.dac_out);
                    end
                    head = head + 1;
                end else begin
                    sb_mismatch = sb_mismatch + 1;
                    $display("FAIL: extra MCP write with empty scoreboard");
                end
                prev_frames = u_model.frame_cnt;
            end else if (u_model.frame_cnt < prev_frames) begin
                prev_frames = u_model.frame_cnt;   // 复位
            end

            // DDS 样点推入(在写比对之后,同一沿同时发生时先弹后压)
            if (dds_valid_debug === 1'b1) begin
                if (tail < 4096) begin
                    exp_mem[tail]    = dds_code_debug;
                    push_time[tail]  = $time;
                end
                tail = tail + 1;
            end

            // ready 时序(§20):每个 dds_valid 沿 ready 必须为 1
            if ((dds_valid_debug === 1'b1) && (dac_ready_debug !== 1'b1)) begin
                ready_fail = ready_fail + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 静音期望检查:note=0 期间压入的样点必须全是 0x800(§23)
    //-------------------------------------------------------------------------
    integer mute_expect_cnt;
    always @(posedge clk) begin
        if ((rst_n === 1'b1) && (TB_ENABLE != 0) &&
            (dds_valid_debug === 1'b1) && (note_code === 3'd0) &&
            (dds_code_debug !== 12'h800)) begin
            mute_expect_cnt = mute_expect_cnt + 1;
            $display("FAIL: mute sample %0h != 0x800", dds_code_debug);
        end
    end

    //-------------------------------------------------------------------------
    // 检查任务
    //-------------------------------------------------------------------------
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
    // 按样点数驱动一个音符段,并等待全部写入完成(带超时)
    //-------------------------------------------------------------------------
    task run_note;
        input [2:0] n;
        input integer n_samples;
        integer t0;
        integer g;
        begin
            @(negedge clk);
            note_code = n;
            t0 = tail;
            g = 0;
            while ((tail < t0 + n_samples) && (g < n_samples * SAMPLE_DIV + 4 * SAMPLE_DIV)) begin
                @(posedge clk);
                g = g + 1;
            end
            checks = checks + 1;
            if (tail < t0 + n_samples) begin
                errors = errors + 1;
                $display("FAIL: note %0d generated only %0d of %0d samples",
                         n, tail - t0, n_samples);
            end
            // 等队列清空(全部写完)
            g = 0;
            while ((head < tail) && (g < n_samples * SAMPLE_DIV + 4 * SAMPLE_DIV)) begin
                @(posedge clk);
                g = g + 1;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 捕获流的零交叉抽检(§38,观察点在 I2C 接收后的 DAC 码序列)
    //-------------------------------------------------------------------------
    task check_captured_freq;
        input integer start_idx;
        input integer n_samples;
        input integer f_cHz;          // 标称频率(0.01 Hz)
        integer k;
        integer crossings;
        real f_nom, f_meas, err_pct;
        begin
            crossings = 0;
            for (k = 1; k < n_samples; k = k + 1) begin
                if ((captured_mem[start_idx + k - 1] < 12'd2048) &&
                    (captured_mem[start_idx + k]     >= 12'd2048)) begin
                    crossings = crossings + 1;
                end
            end
            f_nom  = f_cHz / 100.0;
            f_meas = crossings * 8000.0 / n_samples;
            err_pct = (f_meas - f_nom) / f_nom * 100.0;
            checks = checks + 1;
            if ((err_pct > 1.0) || (err_pct < -1.0)) begin
                errors = errors + 1;
                $display("FAIL: captured freq f=%f nom=%f err=%f (crossings=%0d)",
                         f_meas, f_nom, err_pct, crossings);
            end else begin
                $display("  ok: captured freq f=%f nom=%f err=%f",
                         f_meas, f_nom, err_pct);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer i;
    integer g;
    integer idx_mark;
    reg [11:0] cap_mark;

    initial begin
        checks = 0;
        errors = 0;
        tail = 0; head = 0; captured_n = 0;
        sb_mismatch = 0; dropped = 0; err_pulses = 0; ready_fail = 0;
        max_lat = 0.0; writes_total = 0; prev_frames = 32'd0;
        prev_err = 1'b0; lat_this = 32'd0;
        mute_expect_cnt = 0;
        nack_addr_en = 1'b0;
        nack_data_en = 1'b0;
        clk       = 1'b0;
        rst_n     = 1'b0;
        note_code = 3'd0;

        $display("TB_DDS_MCP4725_PIPELINE: start (MODE=%0d CLK=%0d ADDR=%0h ENABLE=%0d)",
                 TB_MODE, TB_SYS_CLK_HZ, TB_ADDR, TB_ENABLE);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        //=====================================================================
        // MODE 3:ENABLE=0(§32)
        //=====================================================================
        if (TB_MODE == 3) begin : DISABLED
            integer c;
            c = 0;
            while (c < 5000) begin
                @(posedge clk);
                #1;
                c = c + 1;
                checks = checks + 1;
                if ((scl !== 1'b1) || (sda !== 1'b1)) begin
                    errors = errors + 1;
                    $display("FAIL: bus not released in disabled mode");
                end
                if ((dac_busy !== 1'b0) || (dac_error !== 1'b0) ||
                    (dac_overrun !== 1'b0) || (dds_valid_debug !== 1'b0)) begin
                    errors = errors + 1;
                    $display("FAIL: disabled outputs not quiet");
                end
            end
            $display("  ok: ENABLE=0 bus released and quiet for %0d cycles", c);
            if (errors == 0) begin
                $display("TB_DDS_MCP4725_PIPELINE: PASS (checks=%0d, errors=0)", checks);
            end else begin
                $display("TB_DDS_MCP4725_PIPELINE: FAIL (checks=%0d, errors=%0d)", checks, errors);
            end
            $finish;
        end

        //---------------------------------------------------------------------
        // A:复位/空闲(§36-A/§24)
        //---------------------------------------------------------------------
        $display("T1: reset / idle");
        check_true((scl === 1'b1) && (sda === 1'b1), "T1 bus released (pulled high)");
        check_true(dac_busy    === 1'b0, "T1 dac_busy == 0");
        check_true(dac_overrun === 1'b0, "T1 dac_overrun == 0");

        if (TB_MODE == 0) begin : BASIC
            //-----------------------------------------------------------------
            // B:静音 128 样点(§15)
            //-----------------------------------------------------------------
            $display("T2: mute 128 samples");
            run_note(3'd0, 128);
            check_true(mute_expect_cnt == 0, "T2 all mute samples == 0x800");

            //-----------------------------------------------------------------
            // C:七音各 128 样点,逐样点 scoreboard(§16)
            //-----------------------------------------------------------------
            $display("T3: seven notes x 128 samples");
            run_note(3'd1, 128);
            run_note(3'd2, 128);
            run_note(3'd3, 128);
            run_note(3'd4, 128);
            run_note(3'd5, 128);
            run_note(3'd6, 128);
            run_note(3'd7, 128);

            //-----------------------------------------------------------------
            // C':切换边界(§22):note 切换后下一个样点是中点 0x800
            //-----------------------------------------------------------------
            $display("T4: note transition restart sample");
            idx_mark = tail;
            run_note(3'd0, 3);
            checks = checks + 1;
            if (exp_mem[idx_mark] !== 12'h800) begin
                errors = errors + 1;
                $display("FAIL: first sample after note switch = %0h (expected 800)",
                         exp_mem[idx_mark]);
            end else begin
                $display("  ok: first sample after switch == 0x800");
            end

            //-----------------------------------------------------------------
            // E:note transition 序列 C4 -> A4 -> B4 -> mute(§36-E)
            //-----------------------------------------------------------------
            $display("T6: transition sequence C4 -> A4 -> B4 -> mute");
            run_note(3'd1, 128);
            run_note(3'd6, 128);
            run_note(3'd7, 128);
            run_note(3'd0, 128);
            check_true(mute_expect_cnt == 0, "T6 mute samples still all 0x800");
        end

        if (TB_MODE == 1) begin : THROUGHPUT
            //-----------------------------------------------------------------
            // D:真实 12 MHz 吞吐 4096 样点(§17/§18):mute+C4+A4+B4+mute
            //-----------------------------------------------------------------
            $display("T7: throughput 7168 samples at 12 MHz / 8 kS/s / ~333 kHz I2C");
            run_note(3'd0, 512);
            idx_mark = captured_n;
            run_note(3'd1, 2048);
            check_captured_freq(idx_mark, 2048, 26162);   // C4 抽检(§38)
            idx_mark = captured_n;
            run_note(3'd6, 2048);
            check_captured_freq(idx_mark, 2048, 44000);   // A4 抽检
            idx_mark = captured_n;
            run_note(3'd7, 2048);
            check_captured_freq(idx_mark, 2048, 49388);   // B4 抽检
            run_note(3'd0, 512);
        end

        if (TB_MODE == 2) begin : ERROR
            //-----------------------------------------------------------------
            // F1:地址 NACK(§26):错误脉冲、丢弃当前样点、不重传、可恢复
            //-----------------------------------------------------------------
            $display("T2: address NACK -> error, drop, recover");
            run_note(3'd0, 4);              // 正常基线
            nack_addr_en = 1'b1;
            idx_mark = tail;                // 被丢弃的期望样点序号
            run_note(3'd0, 2);              // 触发 NACK
            nack_addr_en = 1'b0;
            run_note(3'd0, 4);              // 恢复
            check_true(err_pulses >= 1,     "T2 dac_error pulsed on addr NACK");
            check_true(dropped    >= 1,     "T2 failed sample dropped (no retransmit)");
            check_true(dac_busy   === 1'b0, "T2 controller not stuck busy");
            run_note(3'd5, 8);              // 恢复后继续正常写

            //-----------------------------------------------------------------
            // F2:数据 NACK(§26)
            //-----------------------------------------------------------------
            $display("T3: data NACK -> error, drop, recover");
            nack_data_en = 1'b1;
            run_note(3'd0, 2);
            nack_data_en = 1'b0;
            run_note(3'd0, 4);
            check_true(err_pulses >= 2,     "T3 dac_error pulsed on data NACK");

            //-----------------------------------------------------------------
            // F4:过载故障(§29):独立 controller 高速刺激,overrun 置位
            // 且 pending 不被覆盖(发出的仍是先接受的样点)
            //-----------------------------------------------------------------
            $display("T5: forced overrun on out-of-band controller");
            oo_code  = 12'hA57;
            oo_valid = 1'b1;
            @(posedge clk);                      // A accepted (ready=1)
            oo_code  = 12'h123;
            @(posedge clk);                      // B rejected (ready=0)
            oo_valid = 1'b0;
            @(negedge clk);
            check_true(oo_over === 1'b1, "T5 overrun set by fast push");
            begin : F4_WAIT
                integer w;
                w = 0;
                while ((oo_busy !== 1'b0) && (w < 8 * SAMPLE_DIV)) begin
                    @(posedge clk);
                    w = w + 1;
                end
            end
            @(negedge clk);
            check_eq32(u_model_oob.dac_out, 12'hA57,
                       "T5 pending sample A transmitted (not overwritten)");
            run_note(3'd0, 4);

            //-----------------------------------------------------------------
            // F3:mid-transaction reset(§25)
            //-----------------------------------------------------------------
            $display("T4: mid-transaction reset");
            run_note(3'd1, 2);
            @(negedge clk);
            note_code = 3'd7;
            begin : WAIT_TX
                integer w;
                w = 0;
                while ((dac_busy !== 1'b1) && (w < 4 * SAMPLE_DIV)) begin
                    @(posedge clk);
                    w = w + 1;
                end
            end
            @(negedge clk);
            rst_n = 1'b0;                   // I2C 事务进行中复位
            repeat (20) @(posedge clk);
            check_true((scl === 1'b1) && (sda === 1'b1),
                       "T4 bus released by mid-tx reset");
            check_true(dac_busy === 1'b0,   "T4 busy == 0 after reset");
            rst_n = 1'b1;
            repeat (10) @(posedge clk);
            run_note(3'd2, 16);             // 复位后完整新 Fast Write 序列
            check_true(sb_mismatch == 0,    "T4 scoreboard clean after reset recovery");
        end

        //---------------------------------------------------------------------
        // 汇总(所有模式)
        //---------------------------------------------------------------------
        check_eq32(sb_mismatch, 0,      "scoreboard per-sample mismatches");
        if (TB_MODE != 2) begin
            check_eq32(err_pulses, 0,   "no dac_error in normal path");
            check_eq32(dropped,    0,   "no dropped samples in normal path");
        end else begin
            check_true(err_pulses >= 1, "error mode did produce expected errors");
            check_true(dropped   >= 1,  "error mode did drop the failed samples");
        end
        check_true(ready_fail == 0,     "dac_ready==1 at every dds_valid (section 20)");
        check_true(u_model.eeprom_viol === 1'b0, "no EEPROM write on the whole path");
        check_eq32(u_model.last_addr, TB_ADDR,   "I2C address == parameter value");

        // $time 单位是 ns(时钟周期 10 ns),换算成拍数再比较
        checks = checks + 1;
        if ((max_lat / 10.0) >= SAMPLE_DIV) begin
            errors = errors + 1;
            $display("FAIL: max latency %0.1f ns (%0.1f clk) >= sample period %0d clk",
                     max_lat, max_lat / 10.0, SAMPLE_DIV);
        end else if (writes_total > 0) begin
            $display("  ok: max latency %0.1f ns (%0.1f clk) < sample period %0d clk",
                     max_lat, max_lat / 10.0, SAMPLE_DIV);
        end

        if (TB_MODE == 1) begin
            check_eq32(tail,         7168, "DDS samples generated");
            check_eq32(writes_total, 7168, "MCP4725 Fast Writes completed");
            check_eq32(head,         7168, "scoreboard samples consumed");
            check_true(dac_overrun === 1'b0, "dac_overrun == 0");
        end

        if (errors == 0) begin
            $display("TB_DDS_MCP4725_PIPELINE: PASS (checks=%0d, errors=0, sim_time=%0t)",
                     checks, $time);
        end else begin
            $display("TB_DDS_MCP4725_PIPELINE: FAIL (checks=%0d, errors=%0d, sim_time=%0t)",
                     checks, errors, $time);
        end

        $finish;
    end

endmodule
