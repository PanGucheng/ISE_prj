//=============================================================================
// tb_dds_sine_generator.v — dds_sine_generator 验收(P3 计划 Commit C/D)
//
// 三套仿真共用本 TB,由参数区分(P3 计划 §37):
//   dds_sine_generator            TB_SYS_CLK_HZ=1e6   快速功能 + 七音频率
//   dds_sine_generator_12m        TB_SYS_CLK_HZ=12e6  真实 12 MHz 采样节拍
//   dds_sine_generator_disabled   TB_ENABLE=0         关闭态
//
// 覆盖:
//   A reset            复位后 dac_code=12'h800、valid=0
//   B sample cadence   相邻 valid 间隔 == SAMPLE_DIV(12 MHz 下 = 1500,
//                      不允许 1499/1501),valid 严格 1 clk 宽
//   C mute             note=0 时所有样点 == 12'h800 且 valid 持续
//   D/G range          全程 256 <= dac_code <= 3840 且无 X(全局监视)
//   F note transition  切换当拍相位归零、切换后第一个有效样点 12'h800、
//                      8 kHz 节拍不受切换影响
//   H ENABLE=0         dac_code 恒 12'h800、valid 恒 0、无周期性事务
//   (Commit D 扩展:七音零交叉测频 + phase increment 独立数学检查)
//
// 诊断文本全 ASCII。判定行:TB_DDS_SINE_GENERATOR: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_dds_sine_generator;

    parameter integer TB_SYS_CLK_HZ     = 1000000;
    parameter integer TB_SAMPLE_RATE_HZ = 8000;
    parameter integer TB_ENABLE         = 1;

    localparam integer SAMPLE_DIV = TB_SYS_CLK_HZ / TB_SAMPLE_RATE_HZ;

    reg         clk;
    reg         rst_n;
    reg  [2:0]  note_code;
    wire [11:0] dac_code;
    wire        dac_code_valid;

    integer checks;
    integer errors;

    // 采样值收集
    integer valid_cnt;

    //-------------------------------------------------------------------------
    // DUT(ENABLE 由 TB 参数传入;disabled 仿真走 GEN_OFF 分支)
    //-------------------------------------------------------------------------
    dds_sine_generator #(
        .SYS_CLK_HZ     (TB_SYS_CLK_HZ),
        .SAMPLE_RATE_HZ (TB_SAMPLE_RATE_HZ),
        .ENABLE         (TB_ENABLE)
    ) u_dut (
        .clk            (clk),
        .rst_n_sync     (rst_n),
        .note_code      (note_code),
        .dac_code       (dac_code),
        .dac_code_valid (dac_code_valid)
    );

    //-------------------------------------------------------------------------
    // 全局范围/X 监视(§34):任何使能采样期间不得越界或为 X
    //-------------------------------------------------------------------------
    integer range_bad;
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (!(dac_code >= 12'd256 && dac_code <= 12'd3840)) begin
                range_bad = range_bad + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // valid 节拍监视(§29):间隔 == SAMPLE_DIV,宽度 == 1 clk
    //-------------------------------------------------------------------------
    integer cyc_cnt;
    integer bad_interval;
    integer bad_width;
    integer intervals;
    reg     prev_valid;
    reg     seen_valid;
    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            cyc_cnt = 0; bad_interval = 0; bad_width = 0;
            intervals = 0; prev_valid = 1'b0; seen_valid = 1'b0;
        end else begin
            if (dac_code_valid === 1'b1) begin
                if (seen_valid !== 1'b0) begin
                    if (cyc_cnt !== SAMPLE_DIV - 1) begin
                        bad_interval = bad_interval + 1;
                        $display("FAIL: valid interval %0d != %0d", cyc_cnt + 1, SAMPLE_DIV);
                    end else begin
                        intervals = intervals + 1;
                    end
                end
                if (prev_valid === 1'b1) begin
                    bad_width = bad_width + 1;
                    $display("FAIL: valid wider than 1 clk");
                end
                seen_valid = 1'b1;
                prev_valid = 1'b1;
                cyc_cnt    = 0;
            end else begin
                prev_valid = 1'b0;
                cyc_cnt    = cyc_cnt + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 等待 n 个 valid 样点,逐个返回样点值
    //-------------------------------------------------------------------------
    task collect_valids;
        input integer n;
        output [11:0] first_sample;
        output [11:0] last_sample;
        integer k;
        reg [11:0] s;
        begin
            first_sample = 12'hxxx;
            last_sample  = 12'hxxx;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                while (dac_code_valid !== 1'b1) begin
                    @(posedge clk);
                end
                s = dac_code;              // 与 valid 同周期的样点
                if (k == 0) first_sample = s;
                last_sample = s;
                valid_cnt   = valid_cnt + 1;
            end
        end
    endtask

    task check_eq12;
        input [11:0]     got;
        input [11:0]     exp;
        input [8*60-1:0] label;
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

    //-------------------------------------------------------------------------
    // P3 Commit D:phase increment 独立数学检查(§33)。
    // 放在 generate 作用域内:TB_ENABLE=0 时 GEN_DDS 未 elaborate,
    // 对 u_dut.GEN_DDS 的层次引用随之消失,disabled 仿真可正常编译。
    // real 运算仅存在于 TB(ISim 无 $sin 已在 LUT TB 用泰勒级数替代,
    // 这里只需要乘除)。
    //-------------------------------------------------------------------------
    reg [11:0] s_first;
    reg [11:0] s_last;
    integer    vc0;
    reg [2:0] tb_exp_note;   // 主流程写入:当前被测音符

    generate
        if (TB_ENABLE != 0) begin : G_INC
            reg [23:0] inc_got;
            real inc_nom_cHz;
            integer inc_exp;
            always @(tb_exp_note) begin
                #20000;      // 等相位重启与 increment 更新稳定
                inc_got = u_dut.GEN_DDS.phase_inc;
                case (tb_exp_note)
                    3'd1:    inc_nom_cHz = 26162.0;
                    3'd2:    inc_nom_cHz = 29367.0;
                    3'd3:    inc_nom_cHz = 32963.0;
                    3'd4:    inc_nom_cHz = 34923.0;
                    3'd5:    inc_nom_cHz = 39199.0;
                    3'd6:    inc_nom_cHz = 44000.0;
                    3'd7:    inc_nom_cHz = 49388.0;
                    default: inc_nom_cHz = 0.0;
                endcase
                inc_exp = $rtoi((inc_nom_cHz / 100.0) * 16777216.0 / 8000.0 + 0.5);
                checks = checks + 1;
                if (inc_got !== inc_exp[23:0]) begin
                    errors = errors + 1;
                    $display("FAIL: inc note=%0d got=%0d expected=%0d",
                             tb_exp_note, inc_got, inc_exp);
                end else begin
                    $display("  ok: inc note=%0d == %0d (independent math)",
                             tb_exp_note, inc_got);
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 七音频率测试(§31/§32):跳过重启样点后,统计 8192 个样点内
    // dac_code < 2048 -> >= 2048 的正向零交叉:
    //   f_meas = crossings / N * fs,|err| < 1%
    //-------------------------------------------------------------------------
    task freq_test;
        input [2:0] n;
        input integer f_cHz;      // 标称频率,单位 0.01 Hz
        integer k;
        integer crossings;
        reg [11:0] prev;
        reg [11:0] cur;
        real f_nom;
        real f_meas;
        real err_pct;
        begin
            @(negedge clk);
            note_code    = n;
            tb_exp_note  = n;     // 触发 inc 数学检查
            collect_valids(2, s_first, s_last);
            check_eq12(s_first, 12'h800, "  restart sample == 0x800");
            crossings = 0;
            prev      = s_last;
            for (k = 0; k < 8192; k = k + 1) begin
                @(posedge clk);
                while (dac_code_valid !== 1'b1) begin
                    @(posedge clk);
                end
                cur = dac_code;
                if ((prev < 12'd2048) && (cur >= 12'd2048)) begin
                    crossings = crossings + 1;
                end
                prev = cur;
            end
            f_nom  = f_cHz / 100.0;
            f_meas = crossings * 8000.0 / 8192.0;
            err_pct = (f_meas - f_nom) / f_nom * 100.0;
            checks = checks + 1;
            if ((err_pct > 1.0) || (err_pct < -1.0)) begin
                errors = errors + 1;
                $display("FAIL: freq note=%0d f_meas=%.3f nom=%.2f err=%+.4f%% crossings=%0d",
                         n, f_meas, f_nom, err_pct, crossings);
            end else begin
                $display("  ok: freq note=%0d f_meas=%.3f nom=%.2f err=%+.4f%% crossings=%0d",
                         n, f_meas, f_nom, err_pct, crossings);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;       // 时钟周期任意,DDS 只关心拍数(DIV)

    initial begin
        checks   = 0;
        errors   = 0;
        range_bad = 0;
        valid_cnt = 0;
        clk       = 1'b0;
        rst_n     = 1'b0;
        note_code = 3'd0;
        tb_exp_note = 3'd0;

        $display("TB_DDS_SINE_GENERATOR: start (CLK=%0d RATE=%0d DIV=%0d ENABLE=%0d)",
                 TB_SYS_CLK_HZ, TB_SAMPLE_RATE_HZ, SAMPLE_DIV, TB_ENABLE);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        //---------------------------------------------------------------------
        // H:ENABLE=0(§25)
        //---------------------------------------------------------------------
        if (TB_ENABLE == 0) begin : DISABLED
            integer c;
            c = 0;
            while (c < 20000) begin
                @(posedge clk);
                #1;
                c = c + 1;
                checks = checks + 1;
                if (dac_code !== 12'h800) begin
                    errors = errors + 1;
                    $display("FAIL: disabled dac_code=%0h != 800", dac_code);
                end
                if (dac_code_valid !== 1'b0) begin
                    errors = errors + 1;
                    $display("FAIL: disabled valid is not 0");
                end
            end
            $display("  ok: ENABLE=0 constant 0x800 / valid=0 over %0d cycles", c);
            if (errors == 0) begin
                $display("TB_DDS_SINE_GENERATOR: PASS (checks=%0d, errors=0)", checks);
            end else begin
                $display("TB_DDS_SINE_GENERATOR: FAIL (checks=%0d, errors=%0d)", checks, errors);
            end
            $finish;
        end

        //---------------------------------------------------------------------
        // A:复位状态
        //---------------------------------------------------------------------
        $display("T1: reset state");
        check_eq12(dac_code, 12'h800, "T1 dac_code == 0x800 after reset");
        checks = checks + 1;
        if (dac_code_valid !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: T1 valid != 0 after reset");
        end else begin
            $display("  ok: T1 valid == 0 after reset");
        end

        //---------------------------------------------------------------------
        // C:mute(note=0)持续样点 == 0x800,valid 持续
        //---------------------------------------------------------------------
        $display("T2: mute keeps 0x800 at every valid");
        vc0 = valid_cnt;
        collect_valids(30, s_first, s_last);
        check_eq12(s_first, 12'h800, "T2 first mute sample == 0x800");
        check_eq12(s_last,  12'h800, "T2 last mute sample == 0x800");
        checks = checks + 1;
        if (valid_cnt - vc0 !== 30) begin
            errors = errors + 1;
            $display("FAIL: T2 collected %0d valids", valid_cnt - vc0);
        end else begin
            $display("  ok: T2 30 valid samples collected");
        end

        //---------------------------------------------------------------------
        // F:note transition C4 -> A4(§35):节拍不变、相位重启、首样点中点
        //---------------------------------------------------------------------
        $display("T3: note transition 0 -> C4 -> A4");
        @(negedge clk);
        note_code = 3'd1;                       // C4
        collect_valids(2, s_first, s_last);
        check_eq12(s_first, 12'h800, "T3 first C4 sample == 0x800 (phase restart)");
        collect_valids(8, s_first, s_last);
        vc0 = valid_cnt;
        @(negedge clk);
        note_code = 3'd6;                       // A4
        collect_valids(1, s_first, s_last);
        check_eq12(s_first, 12'h800, "T3 first A4 sample == 0x800 (phase restart)");
        collect_valids(10, s_first, s_last);
        checks = checks + 1;
        if (bad_interval != 0) begin
            errors = errors + 1;
            $display("FAIL: T3 sample cadence disturbed by note transitions");
        end else begin
            $display("  ok: T3 8 kHz cadence unchanged across transitions");
        end

        //---------------------------------------------------------------------
        // T5(P3 Commit D):七音全部实测(仅快速模式;§30/§31/§32/§33)
        //---------------------------------------------------------------------
        if (TB_SYS_CLK_HZ == 1000000) begin : SEVEN_NOTES
            $display("T5: seven-note frequency measurement (8192 samples/note)");
            freq_test(3'd1, 26162);
            freq_test(3'd2, 29367);
            freq_test(3'd3, 32963);
            freq_test(3'd4, 34923);
            freq_test(3'd5, 39199);
            freq_test(3'd6, 44000);
            freq_test(3'd7, 49388);
            // 回静音:静音样点恒 0x800
            @(negedge clk);
            note_code = 3'd0;
            collect_valids(5, s_first, s_last);
            check_eq12(s_first, 12'h800, "T5 back to mute sample == 0x800");
        end

        //---------------------------------------------------------------------
        // 汇总(cadence/range 统计由全局监视累计)
        //---------------------------------------------------------------------
        checks = checks + 1;
        if (bad_interval != 0) begin
            errors = errors + 1;
            $display("FAIL: %0d bad valid intervals", bad_interval);
        end else if (intervals < 20) begin
            errors = errors + 1;
            $display("FAIL: only %0d intervals observed", intervals);
        end else begin
            $display("  ok: %0d valid intervals all == %0d clk", intervals, SAMPLE_DIV);
        end
        checks = checks + 1;
        if (bad_width != 0) begin
            errors = errors + 1;
            $display("FAIL: %0d valid pulses wider than 1 clk", bad_width);
        end else begin
            $display("  ok: valid pulses are 1 clk wide");
        end
        checks = checks + 1;
        if (range_bad != 0) begin
            errors = errors + 1;
            $display("FAIL: %0d out-of-range dac_code samples", range_bad);
        end else begin
            $display("  ok: dac_code within [256,3840] for the whole run");
        end

        if (errors == 0) begin
            $display("TB_DDS_SINE_GENERATOR: PASS (checks=%0d, errors=0, sim_time=%0t)",
                     checks, $time);
        end else begin
            $display("TB_DDS_SINE_GENERATOR: FAIL (checks=%0d, errors=%0d, sim_time=%0t)",
                     checks, errors, $time);
        end

        $finish;
    end

endmodule
