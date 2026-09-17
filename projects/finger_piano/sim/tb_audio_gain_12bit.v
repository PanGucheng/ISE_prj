//=============================================================================
// tb_audio_gain_12bit.v — audio_gain_12bit 单元验收(P8 计划 Commit B,§9/§10;
// P8-E 修正:增加理想增益参考检查)
//
// 覆盖:
//   1. **全组合穷举**:sample_in 0..4095 × volume_level 0..7 全部 32768
//      组合,与两套独立整数参考逐位比对:
//        a) shift/add 同语义参考(与 RTL 的算术右移 floor 规则完全一致,
//           逐位相等);
//        b) **理想增益参考** floor(delta*level/8)(严格向 -inf,P8-E 新增):
//           RTL 是该理想值的 shift/add 量化近似,要求全部组合下
//           |RTL - ideal| <= 1 LSB。
//      穷举同时证明端点 0/4095 无 wrap、level 0 恒 2048、2048 恒 2048
//      (§7/§8/§26)。
//   2. 正/负半波已知点抽查表:2560/3072/3840 与 256/1024/1536 全 level
//      逐点打印(§9)。
//   3. 对称性:|g(+d) + g(-d)| <= 1(量化近似允许的 ±1 LSB 对称误差,§9)。
//   4. 单调性:固定 |delta| 时,增益绝对值随 level 单调不减。
//
// 诊断文本全 ASCII。判定行:TB_AUDIO_GAIN_12BIT: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_audio_gain_12bit;

    reg  [11:0] sample_in;
    reg  [2:0]  volume_level;
    wire [11:0] sample_out;

    integer checks;
    integer errors;
    integer s;
    integer lvl;
    integer d;
    integer exp_code;
    integer got;
    integer up;
    integer down;
    integer prev_mag;
    integer cur_mag;

    audio_gain_12bit u_dut (
        .sample_in    (sample_in),
        .volume_level (volume_level),
        .sample_out   (sample_out)
    );

    //-------------------------------------------------------------------------
    // 独立参考模型一(P8 §10):shift/add 同语义参考,floor 移位与 RTL
    // 的算术右移完全一致——预期与 RTL **逐位相等**。
    //-------------------------------------------------------------------------
    function integer fshift;    // floor(d / 2^n)
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
        integer h;
        integer q;
        integer e;
        begin
            h = fshift(delta, 1);
            q = fshift(delta, 2);
            e = fshift(delta, 3);
            case (lvl)
                0:       ref_scaled = 0;
                1:       ref_scaled = e;
                2:       ref_scaled = q;
                3:       ref_scaled = q + e;
                4:       ref_scaled = h;
                5:       ref_scaled = h + e;
                6:       ref_scaled = h + q;
                default: ref_scaled = delta - e;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // 独立参考模型二(P8-E 新增):**理想增益** floor(delta*level/8),
    // 严格向 -inf 取整。RTL 的 shift/add 是该理想值的量化近似(逐项
    // 移位截断),本检查锁定全部组合下 |RTL - ideal| <= 1 LSB。
    //-------------------------------------------------------------------------
    function integer ideal_scaled;
        input integer delta;
        input integer lvl;
        integer p;
        begin
            p = delta * lvl;
            if (p >= 0) ideal_scaled = p / 8;
            else        ideal_scaled = -(((-p) + 7) / 8);
        end
    endfunction

    task apply_check;
        input integer in_code;
        input integer in_lvl;
        integer ideal_code;
        integer diff;
        begin
            sample_in    = in_code[11:0];
            volume_level = in_lvl[2:0];
            #2;
            checks = checks + 1;
            exp_code = 2048 + ref_scaled(in_code - 2048, in_lvl);
            got      = sample_out;
            if (got !== exp_code) begin
                errors = errors + 1;
                $display("FAIL: shiftadd ref: in=%0d lvl=%0d: got %0d expected %0d",
                         in_code, in_lvl, got, exp_code);
            end
            // 理想增益参考:|RTL - ideal| <= 1 LSB(P8-E)
            checks = checks + 1;
            ideal_code = 2048 + ideal_scaled(in_code - 2048, in_lvl);
            diff = got - ideal_code;
            if (diff < 0) diff = -diff;
            if (diff > 1) begin
                errors = errors + 1;
                $display("FAIL: ideal ref: in=%0d lvl=%0d: got %0d ideal %0d (diff %0d > 1)",
                         in_code, in_lvl, got, ideal_code, diff);
            end
        end
    endtask

    initial begin
        checks = 0;
        errors = 0;
        sample_in    = 12'd2048;
        volume_level = 3'd0;

        $display("TB_AUDIO_GAIN_12BIT: start");

        //---------------------------------------------------------------------
        // 1. 全组合穷举 4096 x 8(§26:端点/静音/中心全部隐含覆盖)
        //---------------------------------------------------------------------
        for (s = 0; s <= 4095; s = s + 1) begin
            for (lvl = 0; lvl <= 7; lvl = lvl + 1) begin
                apply_check(s, lvl);
            end
        end
        $display("  ok: exhaustive 4096x8 sweep done (%0d checks: shift-add bitwise + ideal <=1 LSB)", checks);

        //---------------------------------------------------------------------
        // 2. 关键语义点(§8/§9)
        //---------------------------------------------------------------------
        for (lvl = 0; lvl <= 7; lvl = lvl + 1) begin
            apply_check(2048, lvl);
            checks = checks + 1;
            if (sample_out !== 12'd2048) begin
                errors = errors + 1;
                $display("FAIL: center 2048 at lvl %0d -> %0d", lvl, sample_out);
            end
        end
        $display("  ok: center in -> center out at all levels");

        for (s = 0; s <= 4095; s = s + 1) begin
            apply_check(s, 0);
            checks = checks + 1;
            if (sample_out !== 12'd2048) begin
                errors = errors + 1;
                $display("FAIL: mute lvl0 in=%0d -> %0d", s, sample_out);
            end
        end
        $display("  ok: level 0 digital mute -> 2048 for all inputs");

        //---------------------------------------------------------------------
        // 3. 正/负半波已知点抽查表(§9;数值同时被穷举覆盖,这里显式打印)
        //---------------------------------------------------------------------
        d = 256;
        while (d <= 1792) begin
            for (lvl = 0; lvl <= 7; lvl = lvl + 1) begin
                apply_check(2048 + d, lvl);
                apply_check(2048 - d, lvl);
            end
            $display("  info: delta +/-%0d: lvl7 out = %0d / %0d",
                     d, 2048 + ref_scaled(d, 7), 2048 + ref_scaled(-d, 7));
            d = d * 2;
        end
        apply_check(3840, 7); apply_check(256, 7);
        apply_check(3072, 4); apply_check(1024, 4);
        apply_check(2560, 1); apply_check(1536, 1);
        $display("  ok: known half-wave points covered");

        //---------------------------------------------------------------------
        // 4. 对称性:|g(+d) + g(-d)| <= 1(±1 LSB floor 对称误差,§9)
        //---------------------------------------------------------------------
        for (d = 1; d <= 2047; d = d + 1) begin
            up   = ref_scaled(d, 7)    + ref_scaled(-d, 7);
            down = ref_scaled(d, 1)    + ref_scaled(-d, 1);
            checks = checks + 1;
            if ((up > 1) || (up < -1) || (down > 1) || (down < -1)) begin
                errors = errors + 1;
                $display("FAIL: symmetry d=%0d: lvl7 sum %0d lvl1 sum %0d",
                         d, up, down);
            end
        end
        $display("  ok: floor truncation symmetry within +-1 LSB");

        //---------------------------------------------------------------------
        // 5. 单调性:固定 |delta|,增益绝对值随 level 单调不减
        //---------------------------------------------------------------------
        d = 1;
        while (d <= 2047) begin
            prev_mag = 0;
            for (lvl = 1; lvl <= 7; lvl = lvl + 1) begin
                cur_mag = ref_scaled(d, lvl);
                if (cur_mag < 0) cur_mag = -cur_mag;
                checks = checks + 1;
                if (cur_mag < prev_mag) begin
                    errors = errors + 1;
                    $display("FAIL: monotonicity d=%0d lvl=%0d: %0d < %0d",
                             d, lvl, cur_mag, prev_mag);
                end
                prev_mag = cur_mag;
            end
            d = d * 3 + 1;
        end
        $display("  ok: gain magnitude monotonic in level");

        $display("TB_AUDIO_GAIN_12BIT: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) begin
            $display("TB_AUDIO_GAIN_12BIT: PASS");
        end else begin
            $display("TB_AUDIO_GAIN_12BIT: FAIL");
        end
        $finish;
    end

endmodule
