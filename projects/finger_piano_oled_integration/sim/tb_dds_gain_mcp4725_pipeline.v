//=============================================================================
// tb_dds_gain_mcp4725_pipeline.v — DDS→数字音量→MCP4725 端到端验收
// (P8 计划 Commit C,§13~§17)
//
// 真实 12 MHz / 8 kS/s / ~333 kHz,序列(P8 §13,另按 §15 分别覆盖两种
// mute 语义):
//
//   note=0 vol=7   512 帧   mute 语义 A:DDS 自身 0x800
//   C4   vol=1/4/7 各 512    音量阶梯(§14:切换不得改相位/ cadence)
//   A4   vol=2/6   各 512
//   B4   vol=7      512
//   note=5 vol=0   256 帧   mute 语义 B:DDS 仍播 G4,gain 压平为 2048
//
// 验证:
//   1. scoreboard:MCP4725 模型捕获流 == gain_ref(推入的 DDS 码, 推入时
//      的 volume_level)逐帧比对——推入侧同时记录样点与当时音量,音量
//      切换不会造成错位;
//   2. DDS 流独立锚定:C4 区(1536 帧,横跨 vol 1→4→7)、A4 区、B4 区
//      分别用滑动起点锁定后与独立 LUT 模型递推全比(§14:音量切换不
//      重启相位、不拉伸 cadence);
//   3. dds_valid 间隔全程恒 1500 拍(8 kS/s cadence 不变);
//   4. ready 时序、0 overrun / 0 I2C error / 0 EEPROM 写、末段捕获全
//      0x800。
//
// 诊断文本全 ASCII。判定行:TB_DDS_GAIN_MCP4725_PIPELINE: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_dds_gain_mcp4725_pipeline;

    parameter integer TB_SYS_CLK_HZ     = 12000000;
    parameter integer TB_SAMPLE_RATE_HZ = 8000;
    parameter integer TB_DAC_I2C_HZ     = 333333;

    localparam integer SAMPLE_CYC = TB_SYS_CLK_HZ / TB_SAMPLE_RATE_HZ;

    reg         clk;
    reg         rst_n;
    reg  [2:0]  note_code;
    reg  [2:0]  volume_level;
    wire        scl, sda;
    wire        dac_busy, dac_error, dac_overrun;
    wire [11:0] gain_code_debug;
    wire        dds_valid_debug;
    wire        dac_ready_debug;

    pullup pu_scl (scl);
    pullup pu_sda (sda);

    dds_gain_mcp4725_pipeline #(
        .SYS_CLK_HZ     (TB_SYS_CLK_HZ),
        .SAMPLE_RATE_HZ (TB_SAMPLE_RATE_HZ),
        .DAC_I2C_HZ     (TB_DAC_I2C_HZ),
        .MCP4725_ADDR   (7'h60),
        .ENABLE         (1)
    ) u_pipe (
        .clk             (clk),
        .rst_n_sync      (rst_n),
        .note_code       (note_code),
        .volume_level    (volume_level),
        .dac_i2c_scl     (scl),
        .dac_i2c_sda     (sda),
        .dac_busy        (dac_busy),
        .dac_error       (dac_error),
        .dac_overrun     (dac_overrun),
        .gain_code_debug (gain_code_debug),
        .dds_valid_debug (dds_valid_debug),
        .dac_ready_debug (dac_ready_debug)
    );

    mcp4725_model #(
        .DEVICE_ADDR (7'h60)
    ) u_model (
        .clk          (clk),
        .rst          (~rst_n),
        .nack_addr_en (1'b0),
        .nack_data_en (1'b0),
        .scl          (scl),
        .sda          (sda)
    );

    initial clk = 1'b0;
    always #41.667 clk = ~clk;   // 真实 12 MHz 节拍

    integer checks;
    integer errors;

    // DDS 原始码(gain 前的样点,push 侧观察)
    wire [11:0] gain_src_code = u_pipe.GEN_PIPE.dds_code;

    //-------------------------------------------------------------------------
    // 独立 gain 参考模型(P8 §10:floor 移位语义,与 RTL 一致)
    //-------------------------------------------------------------------------
    function integer fshift;
        input integer d;
        input integer n;
        begin
            if (d >= 0) fshift = d >> n;
            else        fshift = -(((-d) + (1 << n) - 1) >> n);
        end
    endfunction

    function integer ref_scaled;
        input integer delta;
        input integer lvl;
        begin
            case (lvl)
                0:       ref_scaled = 0;
                1:       ref_scaled = fshift(delta, 3);
                2:       ref_scaled = fshift(delta, 2);
                3:       ref_scaled = fshift(delta, 2) + fshift(delta, 3);
                4:       ref_scaled = fshift(delta, 1);
                5:       ref_scaled = fshift(delta, 1) + fshift(delta, 3);
                6:       ref_scaled = fshift(delta, 1) + fshift(delta, 2);
                default: ref_scaled = delta - fshift(delta, 3);
            endcase
        end
    endfunction

    function integer gain_ref;
        input integer code;
        input integer lvl;
        begin
            gain_ref = 2048 + ref_scaled(code - 2048, lvl);
        end
    endfunction

    //-------------------------------------------------------------------------
    // 独立 LUT 模型(8-bit 相位量化语义,与 P3 验收同一数学)
    //-------------------------------------------------------------------------
    function real sin_ref;
        input real x;
        real x2;
        real term;
        real s;
        integer n;
        begin
            s    = x;
            term = x;
            x2   = x * x;
            for (n = 1; n <= 6; n = n + 1) begin
                term = -term * x2 / ((2.0 * n) * (2.0 * n + 1.0));
                s    = s + term;
            end
            sin_ref = s;
        end
    endfunction

    function integer iround;
        input real v;
        begin
            if (v >= 0.0) iround = $rtoi(v + 0.5);
            else          iround = $rtoi(v - 0.5);
        end
    endfunction

    function integer lut256_expect;
        input integer p;   // 0..255
        integer q;
        integer r;
        integer eff;
        real a;
        real s;
        begin
            q = (p / 64) % 4;
            r = p % 64;
            if ((q == 1) || (q == 3)) eff = 64 - r;
            else                      eff = r;
            a = 3.14159265358979323846 / 2.0 * eff / 64.0;
            s = sin_ref(a);
            if ((q == 2) || (q == 3)) s = -s;
            lut256_expect = 2048 + iround(1792.0 * s);
        end
    endfunction

    function integer note_inc;
        input integer note;
        begin
            case (note)
                1:        note_inc = 548657;   // C4
                6:        note_inc = 922747;   // A4
                7:        note_inc = 1035741;  // B4
                default:  note_inc = 0;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // scoreboard:推入 {DDS 码, 当时音量};MCP 写完成时弹出比对
    //-------------------------------------------------------------------------
    reg [11:0] exp_dds  [0:4095];
    reg [2:0]  exp_lvl  [0:4095];
    reg [11:0] dds_mem  [0:4095];
    integer tail;
    integer head;
    integer sb_mismatch;
    integer err_pulses;
    integer ready_fail;
    reg [31:0] prev_frames;

    // cadence 监视
    integer    valid_cnt;
    integer    interval_bad;
    integer    last_valid_at;
    integer    gap;

    // 段边界(帧索引,stimulus 记录)
    integer idx_mute1_end;
    integer idx_a4_start;
    integer idx_b4_start;
    integer idx_mute2_start;

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            tail        = 0;
            head        = 0;
            sb_mismatch = 0;
            err_pulses  = 0;
            ready_fail  = 0;
            prev_frames = 32'd0;
            valid_cnt   = 0;
            interval_bad= 0;
            last_valid_at = 0;
        end else begin
            if (dac_error === 1'b1) err_pulses = err_pulses + 1;

            if (u_model.frame_cnt > prev_frames) begin
                prev_frames = u_model.frame_cnt;
                if (head < tail) begin
                    checks = checks + 1;
                    if (u_model.dac_out !== gain_ref(exp_dds[head], exp_lvl[head])) begin
                        sb_mismatch = sb_mismatch + 1;
                        if (sb_mismatch <= 5) begin
                            $display("FAIL: sb idx=%0d dds=%0d lvl=%0d: dac=%0d expected %0d",
                                     head, exp_dds[head], exp_lvl[head],
                                     u_model.dac_out, gain_ref(exp_dds[head], exp_lvl[head]));
                        end
                    end
                    head = head + 1;
                end else begin
                    sb_mismatch = sb_mismatch + 1;
                    $display("FAIL: extra MCP write with empty scoreboard");
                end
            end else if (u_model.frame_cnt < prev_frames) begin
                prev_frames = u_model.frame_cnt;
            end

            if (dds_valid_debug === 1'b1) begin
                if (tail <= 4095) begin
                    exp_dds[tail] = gain_src_code;
                    exp_lvl[tail] = volume_level;
                    dds_mem[tail] = gain_src_code;
                end
                tail = tail + 1;
                valid_cnt = valid_cnt + 1;
                if (valid_cnt > 1) begin
                    gap = $time - last_valid_at;
                    // 恒 1500 拍 x 83.334 ns(容差 1 拍)
                    if ((gap < 124990) || (gap > 125010)) interval_bad = interval_bad + 1;
                end
                last_valid_at = $time;
                if (dac_ready_debug !== 1'b1) ready_fail = ready_fail + 1;
            end
        end
    end

    // DDS 原始码观察口已在模块顶部声明(gain_src_code)

    //-------------------------------------------------------------------------
    // 检查任务
    //-------------------------------------------------------------------------
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

    // 等待 cap(tail)增加 n 帧
    task collect_frames;
        input integer n;
        integer t0;
        integer g;
        begin
            t0 = tail + n;
            g  = 0;
            while ((tail < t0) && (g < n * SAMPLE_CYC + 100000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(tail >= t0, "segment samples collected in time");
        end
    endtask

    // DDS 区段独立锚定 + 递推全比(P8 §14:横跨音量切换相位不重启)
    task dds_region_check;
        input integer note;
        input integer lo;
        input integer hi;
        integer k0;
        integer phase;
        integer inc;
        integer j;
        integer ok_cnt;
        integer found;
        integer start_k;
        integer expc;
        begin
            inc   = note_inc(note);
            found = 0;
            k0    = 0;
            while ((k0 <= 200) && (found == 0)) begin
                phase  = (k0 * inc) % 16777216;
                ok_cnt = 0;
                j      = lo;
                while ((j < hi) && (j < lo + 64)) begin
                    if (dds_mem[j] === lut256_expect(phase / 65536)) ok_cnt = ok_cnt + 1;
                    phase = phase + inc;
                    if (phase >= 16777216) phase = phase - 16777216;
                    j = j + 1;
                end
                if (ok_cnt == 64) begin
                    found   = 1;
                    start_k = k0;
                end
                k0 = k0 + 1;
            end

            checks = checks + 1;
            if (found == 0) begin
                errors = errors + 1;
                $display("FAIL: note %0d DDS region [%0d..%0d) anchor not found",
                         note, lo, hi);
            end else begin
                phase = (start_k * inc) % 16777216;
                j     = lo;
                ok_cnt = 0;
                while (j < hi) begin
                    expc = lut256_expect(phase / 65536);
                    if (dds_mem[j] !== expc) begin
                        ok_cnt = ok_cnt + 1;
                        if (ok_cnt <= 5) begin
                            $display("FAIL: note %0d dds idx %0d: got %0d expected %0d",
                                     note, j, dds_mem[j], expc);
                        end
                    end
                    phase = phase + inc;
                    if (phase >= 16777216) phase = phase - 16777216;
                    j = j + 1;
                end
                if (ok_cnt != 0) begin
                    errors = errors + 1;
                    $display("FAIL: note %0d DDS region mismatches: %0d of %0d",
                             note, ok_cnt, hi - lo);
                end else begin
                    $display("  ok: note %0d DDS region continuous across volume steps (%0d samples, start k=%0d)",
                             note, hi - lo, start_k);
                end
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer mute_bad;
    integer i;

    initial begin
        checks       = 0;
        errors       = 0;
        tail         = 0;
        head         = 0;
        sb_mismatch  = 0;
        err_pulses   = 0;
        ready_fail   = 0;
        valid_cnt    = 0;
        interval_bad = 0;
        last_valid_at= 0;
        mute_bad     = 0;
        idx_mute1_end= 0;
        idx_a4_start = 0;
        idx_b4_start = 0;
        idx_mute2_start = 0;

        $display("TB_DDS_GAIN_MCP4725_PIPELINE: start");

        rst_n        = 1'b0;
        note_code    = 3'd0;
        volume_level = 3'd7;
        repeat (32) @(posedge clk);
        rst_n = 1'b1;

        //---------------------------------------------------------------------
        // mute A:note=0(DDS 自身 0x800),vol=7
        //---------------------------------------------------------------------
        collect_frames(512);
        idx_mute1_end = tail;

        //---------------------------------------------------------------------
        // C4:vol 1 -> 4 -> 7(音量阶梯,§14)
        //---------------------------------------------------------------------
        note_code = 3'd1; volume_level = 3'd1;
        collect_frames(512);
        volume_level = 3'd4;
        collect_frames(512);
        volume_level = 3'd7;
        collect_frames(512);
        idx_a4_start = tail;

        //---------------------------------------------------------------------
        // A4:vol 2 -> 6
        //---------------------------------------------------------------------
        note_code = 3'd6; volume_level = 3'd2;
        collect_frames(512);
        volume_level = 3'd6;
        collect_frames(512);
        idx_b4_start = tail;

        //---------------------------------------------------------------------
        // B4:vol 7
        //---------------------------------------------------------------------
        note_code = 3'd7; volume_level = 3'd7;
        collect_frames(512);
        idx_mute2_start = tail;

        //---------------------------------------------------------------------
        // mute B:note=5(DDS 仍播 G4),vol=0(gain 压平,§15)
        //---------------------------------------------------------------------
        note_code = 3'd5; volume_level = 3'd0;
        collect_frames(256);

        // 等 IQ 清空:控制器写完最后样点
        i = 0;
        while ((head < tail) && (i < 4000000)) begin
            @(posedge clk);
            i = i + 1;
        end
        check_true(head >= tail, "scoreboard drained in time");

        //---------------------------------------------------------------------
        // 汇总判定
        //---------------------------------------------------------------------
        dds_region_check(1, idx_mute1_end, idx_a4_start);
        dds_region_check(6, idx_a4_start,  idx_b4_start);
        dds_region_check(7, idx_b4_start,  idx_mute2_start);

        check_eq32(sb_mismatch, 0, "scoreboard mismatch == 0");
        check_eq32(err_pulses,  0, "dac_error pulses == 0");
        check_eq32(dac_overrun, 0, "dac_overrun == 0");
        check_eq32(u_model.eeprom_viol, 0, "EEPROM writes == 0");
        check_eq32(ready_fail,  0, "ready high at every valid");
        check_eq32(interval_bad,0, "8 kS/s cadence constant (1500 clk)");
        check_eq32(tail,        3840, "total samples == planned sequence");

        $display("TB_DDS_GAIN_MCP4725_PIPELINE: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) begin
            $display("TB_DDS_GAIN_MCP4725_PIPELINE: PASS");
        end else begin
            $display("TB_DDS_GAIN_MCP4725_PIPELINE: FAIL");
        end
        $finish;
    end

endmodule
