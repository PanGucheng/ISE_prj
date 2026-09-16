//=============================================================================
// tb_finger_piano_system.v — finger_piano_system 系统级验收(P6 计划)
//
// 多套仿真共用本 TB,由 TB_MODE 区分(P6 计划 §32/§54):
//   system_stage2_basic            TB_MODE=0  复位初始化 + sensor 全码遍历
//                                             -> note -> MCP 音频频率 + ADS
//                                             -> pressure(Commit C)
//   system_stage2_dual_i2c         TB_MODE=1  ADC/DAC 同时运行 + 压力/音符
//                                             解耦双向验证(Commit D)
//   system_stage2_error_isolation  TB_MODE=2  ADC NACK / DAC NACK 隔离 +
//                                             事务中复位恢复(Commit D)
//   system_stage2_longrun          TB_MODE=3  真实 12 MHz/8 kS/s 连续 8192
//                                             样点逐点比对(Commit E)
//   system_stage2_disabled         TB_MODE=4  ENABLE_ADC=0/ENABLE_DAC=0 双总线
//                                             静默(Commit D)
//   system_stage2_adc_only         TB_MODE=5  DAC 关闭,仅 ADC(Commit D)
//   system_stage2_dac_only         TB_MODE=6  ADC 关闭,仅 DAC(Commit D)
//
// 全部使用真实 12 MHz 系统节拍与真实 10 ms sensor 滤波门限(与板上一致;
// 系统级验证的是"必须等门限才切换"的真实节奏),仅 ADS 转换耗时默认缩短
// 为 TB_CONV_CYCLES=2000 拍加速;longrun 用 13956 拍(860 SPS 标称)。
//
// ADS 转换耗时 TB_CONV_CYCLES 默认 2000 拍加速;longrun 用 13956 拍
// (860 SPS 标称 1.163 ms @ 12 MHz)。
//
// MCP4725 捕获流在 TB 内逐帧入 scoreboard(层次引用 u_dac_model),支持:
//   - mute 段逐样点 0x800 检查;
//   - 音符段首末过零点间隔测频(P4 方法,精度 ±0.1%);
//   - longrun 逐样点 real 正弦比对(独立泰勒级数,锚点对齐)。
//
// 诊断文本全 ASCII。判定行:TB_FINGER_PIANO_SYSTEM: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

`include "finger_piano_cfg.vh"

module tb_finger_piano_system;

    parameter integer TB_SYS_CLK_HZ  = 12000000;
    parameter integer TB_SAMPLE_RATE = 8000;
    // sensor 滤波门限与 DUT 实际值一致(sensor_code_frontend 未透传
    // STABLE_MS 时用 `KEY_STABLE_MS 宏 = 10 ms);等待按拍数计,与节拍无关。
    parameter integer TB_STABLE_MS   = `KEY_STABLE_MS;
    parameter integer TB_MODE        = 0;
    parameter integer TB_CONV_CYCLES = 2000;   // ADS 模型转换耗时(拍)

    // ENABLE 组合(§28):MODE 4 = (0,0)、MODE 5 = (1,0)、MODE 6 = (0,1);
    // 其余模式两条链都开(1,1)。
    localparam integer ADC_ON = (TB_MODE == 4 || TB_MODE == 6) ? 0 : 1;
    localparam integer DAC_ON = (TB_MODE == 4 || TB_MODE == 5) ? 0 : 1;

    // 滤波稳定拍数(12 MHz x ms)与单样点拍数
    localparam integer STABLE_CYC = (TB_SYS_CLK_HZ / 1000) * TB_STABLE_MS;
    localparam integer SAMPLE_CYC = TB_SYS_CLK_HZ / TB_SAMPLE_RATE;

    reg         clk;
    reg         rst_n;
    reg  [2:0]  sensor_async;
    reg         adc_nack_addr, adc_nack_data;
    reg         dac_nack_addr, dac_nack_data;

    wire        adc_scl, adc_sda;
    wire        dac_scl, dac_sda;
    wire [2:0]  sensor_code_stable;
    wire [2:0]  note_code;
    wire [14:0] p_ch0, p_ch1, p_ch2;
    wire        p_valid;
    wire        adc_err, dac_err, dac_over;

    pullup pu_ascl (adc_scl);
    pullup pu_asda (adc_sda);
    pullup pu_dscl (dac_scl);
    pullup pu_dsda (dac_sda);

    finger_piano_system #(
        .SYS_CLK_HZ           (TB_SYS_CLK_HZ),
        .SENSOR_ACTIVE_HIGH   (1),
        .SENSOR_FILTER_ENABLE (1),
        .ENABLE_ADC           (ADC_ON),
        .ENABLE_DAC           (DAC_ON)
    ) u_sys (
        .clk               (clk),
        .rst_n_sync        (rst_n),
        .sensor_async      (sensor_async),
        .adc_i2c_scl       (adc_scl),
        .adc_i2c_sda       (adc_sda),
        .dac_i2c_scl       (dac_scl),
        .dac_i2c_sda       (dac_sda),
        .sensor_code_stable(sensor_code_stable),
        .note_code         (note_code),
        .pressure_ch0      (p_ch0),
        .pressure_ch1      (p_ch1),
        .pressure_ch2      (p_ch2),
        .pressure_valid    (p_valid),
        .adc_error         (adc_err),
        .dac_error         (dac_err),
        .dac_overrun       (dac_over)
    );

    ads1115_model #(
        .DEVICE_ADDR  (7'h48),
        .CONV_CYCLES  (TB_CONV_CYCLES),
        .VAL_AIN0     (16'd1000),          // P6 §21 压力源值
        .VAL_AIN1     (16'd2000),
        .VAL_AIN2     (16'd3000)
    ) u_adc_model (
        .clk             (clk),
        .rst             (~rst_n),
        .nack_addr_en    (adc_nack_addr),
        .nack_data_en    (adc_nack_data),
        .conv_never_done (1'b0),
        .scl             (adc_scl),
        .sda             (adc_sda)
    );

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

    initial clk = 1'b0;
    // 真实 12 MHz 节拍(周期 83.334 ns):系统级验证的全部拍数常数
    // (滤波门限、8 kS/s 采样分频、I2C 拍数)都以 clk 沿计数,必须用与
    // 板上一致的时钟周期,否则捕获流的时间轴(进而测频)整体失真。
    always #41.667 clk = ~clk;

    integer checks;
    integer errors;

    //-------------------------------------------------------------------------
    // 事件计数(任何模式都累计;复位时清零)
    //-------------------------------------------------------------------------
    integer pvalid_cnt;
    integer adc_err_cnt;
    integer dac_err_cnt;
    integer dac_over_cnt;
    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            pvalid_cnt   = 0;
            adc_err_cnt  = 0;
            dac_err_cnt  = 0;
            dac_over_cnt = 0;
        end else begin
            if (p_valid   === 1'b1) pvalid_cnt   = pvalid_cnt   + 1;
            if (adc_err   === 1'b1) adc_err_cnt  = adc_err_cnt  + 1;
            if (dac_err   === 1'b1) dac_err_cnt  = dac_err_cnt  + 1;
            if (dac_over  === 1'b1) dac_over_cnt = dac_over_cnt + 1;
        end
    end

    //-------------------------------------------------------------------------
    // MCP4725 捕获 scoreboard:每完成一帧 Fast Write 采一个样点
    //-------------------------------------------------------------------------
    reg [11:0] captured_mem [0:9500];
    integer    cap_total;
    reg [31:0] prev_frames;

    // 段控制(stimulus 任务驱动):mute 段逐样点必须 0x800
    reg         seg_mute_en;
    integer     mute_bad;
    integer     range_bad;

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            prev_frames    = 32'd0;
            cap_total      = 0;
            mute_bad       = 0;
            range_bad      = 0;
            seg_mute_en    = 1'b0;
        end else begin
            if (u_dac_model.frame_cnt > prev_frames) begin
                prev_frames = u_dac_model.frame_cnt;
                if (cap_total <= 9500) begin
                    captured_mem[cap_total] = u_dac_model.dac_out;
                    cap_total = cap_total + 1;

                    if (u_dac_model.dac_out < 12'd256 ||
                        u_dac_model.dac_out > 12'd3840) begin
                        range_bad = range_bad + 1;
                        $display("FAIL: captured %0d out of range at idx %0d",
                                 u_dac_model.dac_out, cap_total - 1);
                    end
                    if (seg_mute_en && (u_dac_model.dac_out !== 12'h800)) begin
                        mute_bad = mute_bad + 1;
                        $display("FAIL: mute segment sample %0d != 0x800 at idx %0d",
                                 u_dac_model.dac_out, cap_total - 1);
                    end
                end
            end else if (u_dac_model.frame_cnt < prev_frames) begin
                prev_frames = u_dac_model.frame_cnt;   // 复位回绕
            end
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
    // 独立正弦参考(ISim 不支持 $sin,用 real 泰勒级数,P3 TB 同方法):
    // 期望码 = 2048 + round(1792 * sin(2*pi*phase/2^24)),容差 +-1 LSB
    //-------------------------------------------------------------------------
    function integer iround;
        input real v;
        begin
            if (v >= 0.0) iround = $rtoi(v + 0.5);
            else          iround = $rtoi(v - 0.5);
        end
    endfunction

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

    // LUT 语义期望:DDS 只取相位累加器高 8 位(phase[23:16])查 256 相位表,
    // 期望值必须做同样的 8-bit 量化(直接用 24-bit 精确相位会差出最多
    // 半个相位步进,高频下达数百 LSB,导致匹配失败)。
    function integer lut256_expect;
        input integer p;   // 相位地址 0..255
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

    function integer wave_expect;
        input integer phase;   // [0, 2^24)
        begin
            wave_expect = lut256_expect(phase / 65536);
        end
    endfunction

    // P3 冻结的七音 phase increment(dds_frequency_table.md)
    function integer note_inc;
        input integer note;
        begin
            case (note)
                1:        note_inc = 548657;
                2:        note_inc = 615871;
                3:        note_inc = 691284;
                4:        note_inc = 732388;
                5:        note_inc = 822063;
                6:        note_inc = 922747;
                default:  note_inc = 1035741;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // 音符段波形检查:在最近 n_frames 个捕获样点上,尝试窗口起点对应的
    // 音符内样点序号 k0(0..64,切换后 skip 了几帧),以"64 样点连续
    // 匹配"锁定起点,然后全窗口逐样点比对独立正弦参考(±1 LSB)。
    // 连续 64 点随机全部命中的概率约 (3/4096)^64,锁定结果无歧义。
    //-------------------------------------------------------------------------
    task check_note_wave;
        input integer note;
        input integer n_frames;
        integer w0;
        integer k0;
        integer j;
        integer phase;
        integer inc;
        integer expc;
        integer got;
        integer ok_cnt;
        integer found;
        integer start_k;
        begin
            w0  = cap_total - n_frames;
            inc = note_inc(note);
            if (w0 < 0) w0 = 0;

            found  = 0;
            start_k = -1;
            k0     = 0;
            while ((k0 <= 64) && (found == 0)) begin
                phase = (k0 * inc) % 16777216;
                ok_cnt = 0;
                j      = w0;
                while ((j < cap_total) && (j < w0 + 64)) begin
                    expc = wave_expect(phase);
                    got  = captured_mem[j];
                    if ((got >= expc - 1) && (got <= expc + 1)) ok_cnt = ok_cnt + 1;
                    phase = phase + inc;
                    if (phase >= 16777216) phase = phase - 16777216;
                    j = j + 1;
                end
                if (ok_cnt == 64) begin
                    found  = 1;
                    start_k = k0;
                end
                k0 = k0 + 1;
            end

            checks = checks + 1;
            if (found == 0) begin
                errors = errors + 1;
                $display("FAIL: note %0d waveform start not found in %0d samples",
                         note, cap_total - w0);
            end else begin
                phase  = (start_k * inc) % 16777216;
                j      = w0;
                ok_cnt = 0;
                while (j < cap_total) begin
                    expc = wave_expect(phase);
                    got  = captured_mem[j];
                    if ((got < expc - 1) || (got > expc + 1)) begin
                        ok_cnt = ok_cnt + 1;
                        if (ok_cnt <= 5) begin
                            $display("FAIL: note %0d sample idx %0d (k=%0d): got %0d expected %0d",
                                     note, j, start_k + (j - w0), got, expc);
                        end
                    end
                    phase = phase + inc;
                    if (phase >= 16777216) phase = phase - 16777216;
                    j = j + 1;
                end
                if (ok_cnt != 0) begin
                    errors = errors + 1;
                    $display("FAIL: note %0d waveform mismatches: %0d of %0d samples (start k=%0d)",
                             note, ok_cnt, cap_total - w0, start_k);
                end else begin
                    $display("  ok: note %0d waveform match (%0d samples, start k=%0d)",
                             note, cap_total - w0, start_k);
                end
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // stimulus 辅助任务
    //-------------------------------------------------------------------------
    task drive_sensor;
        input [2:0] code;
        begin
            @(negedge clk);
            sensor_async = code;
        end
    endtask

    // 等待滤波门限 + 2FF 同步 + 少量余量,并确认 stable/note 已经切换
    task wait_stable;
        input [2:0] code;
        integer g;
        begin
            g = 0;
            while ((sensor_code_stable !== code) && (g < STABLE_CYC + 4096)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_eq32(sensor_code_stable, code, "sensor_code_stable after filter");
            check_eq32(note_code, code, "note_code after decode");
        end
    endtask

    // 丢弃 n 个过渡样点(切换边界不参与统计)
    task skip_frames;
        input integer n;
        integer g;
        integer t0;
        begin
            t0 = cap_total + n;
            g  = 0;
            while ((cap_total < t0) && (g < n * SAMPLE_CYC + 100000)) begin
                @(posedge clk);
                g = g + 1;
            end
        end
    endtask

    // 收 n 个样点做段统计
    task collect_frames;
        input integer n;
        integer g;
        integer t0;
        begin
            t0 = cap_total + n;
            g  = 0;
            while ((cap_total < t0) && (g < n * SAMPLE_CYC + 100000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(cap_total >= t0, "collected segment samples in time");
        end
    endtask

    task seg_start_mute;
        begin
            seg_mute_en = 1'b1;
        end
    endtask

    task seg_start_note;
        begin
            seg_mute_en = 1'b0;
        end
    endtask

    task seg_stop;
        begin
            seg_mute_en = 1'b0;
        end
    endtask

    //-------------------------------------------------------------------------
    // MODE 0 — basic(P6 §17/§18/§21)
    //-------------------------------------------------------------------------
    task run_basic;
        integer   i;
        reg [2:0] code;
        begin
            // 等几个复位沿,确保全部寄存器进入复位态后再检查
            repeat (8) @(posedge clk);

            //-------------------------------------------------------------
            // §17 复位态:全部输出为确定 0,两总线释放(pullup 为高)
            //-------------------------------------------------------------
            check_eq32(note_code,          3'd0, "reset: note_code == 0");
            check_eq32(sensor_code_stable, 3'd0, "reset: sensor_code_stable == 000");
            check_eq32(p_ch0, 15'd0, "reset: pressure_ch0 == 0");
            check_eq32(p_ch1, 15'd0, "reset: pressure_ch1 == 0");
            check_eq32(p_ch2, 15'd0, "reset: pressure_ch2 == 0");
            check_eq32(p_valid,  1'b0, "reset: pressure_valid == 0");
            check_eq32(adc_err,  1'b0, "reset: adc_error == 0");
            check_eq32(dac_err,  1'b0, "reset: dac_error == 0");
            check_eq32(dac_over, 1'b0, "reset: dac_overrun == 0");
            check_true((adc_scl === 1'b1) && (adc_sda === 1'b1) &&
                       (dac_scl === 1'b1) && (dac_sda === 1'b1),
                       "reset: both I2C buses released high");

            @(posedge clk);
            rst_n = 1'b1;
            $display("  info: reset released");

            //-------------------------------------------------------------
            // §21:ADC 自动开始扫描;两帧后 pressure = 1000/2000/3000
            //-------------------------------------------------------------
            g_wait_pvalid(2, 4000000);
            check_true(pvalid_cnt >= 2, "ADC produced >= 2 scan frames");
            check_eq32(p_ch0, 15'd1000, "pressure_ch0 == 1000 (zero=0)");
            check_eq32(p_ch1, 15'd2000, "pressure_ch1 == 2000 (zero=0)");
            check_eq32(p_ch2, 15'd3000, "pressure_ch2 == 3000 (zero=0)");

            //-------------------------------------------------------------
            // §18:000 -> 001..111 -> 000,note 与 MCP 音频一一对应
            //-------------------------------------------------------------
            for (i = 0; i < 9; i = i + 1) begin
                code = i % 8;
                $display("  info: segment %0d: sensor code %0d", i, code);
                drive_sensor(code);
                wait_stable(code);
                skip_frames(16);            // 排除切换过渡样点
                if (code == 0) begin
                    seg_start_mute;
                    collect_frames(256);
                    seg_stop;
                    check_eq32(mute_bad, 0, "mute segment all 0x800");
                end else begin
                    seg_start_note;
                    collect_frames(768);
                    seg_stop;
                    check_note_wave(code, 768);
                end
            end

            //-------------------------------------------------------------
            // §20 前置条件(两条链都活着):双总线事务计数、无错误
            //-------------------------------------------------------------
            check_true(u_adc_model.stop_cnt > 0, "ADC bus transactions > 0");
            check_true(u_dac_model.frame_cnt > 0, "DAC bus transactions > 0");
            check_eq32(adc_err_cnt,  0, "adc_error count == 0");
            check_eq32(dac_err_cnt,  0, "dac_error count == 0");
            check_eq32(dac_over_cnt, 0, "dac_overrun count == 0");
            check_eq32(range_bad,    0, "no out-of-range samples");
            check_eq32(mute_bad,     0, "no mute-segment violations");
        end
    endtask

    // 等 pressure_valid 计数达标(带超时)
    task g_wait_pvalid;
        input integer n;
        input integer limit;
        integer g;
        begin
            g = 0;
            while ((pvalid_cnt < n) && (g < limit)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(pvalid_cnt >= n, "pressure frames arrived in time");
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        checks       = 0;
        errors       = 0;

        adc_nack_addr = 1'b0;
        adc_nack_data = 1'b0;
        dac_nack_addr = 1'b0;
        dac_nack_data = 1'b0;
        sensor_async  = 3'd0;
        seg_mute_en   = 1'b0;

        $display("TB_FINGER_PIANO_SYSTEM: start (mode=%0d adc_on=%0d dac_on=%0d)",
                 TB_MODE, ADC_ON, DAC_ON);

        rst_n = 1'b0;
        repeat (32) @(posedge clk);

        case (TB_MODE)
            0: run_basic;
            default: begin
                errors = errors + 1;
                $display("FAIL: mode %0d not implemented in this TB build", TB_MODE);
            end
        endcase

        $display("TB_FINGER_PIANO_SYSTEM: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) begin
            $display("TB_FINGER_PIANO_SYSTEM: PASS");
        end else begin
            $display("TB_FINGER_PIANO_SYSTEM: FAIL");
        end
        $finish;
    end

endmodule
