//=============================================================================
// tb_periph_test_top.v — P9 板级诊断工程顶层验收(P9 计划 §20~§27)
//
// 由 TB_MODE + generics 区分(simulation 条目见 project.json):
//   periph_test_normal   TB_MODE=0            复位/heartbeat/ADS 帧 toggle/
//                                             DAC DC(DC 值由 TB_DAC_TEST_MODE
//                                             决定,normal 条目 = 0x800)
//   periph_test_adc_nack TB_MODE=1            ADC 地址 NACK -> sticky error,
//                                             DAC 不受影响;reset 清 sticky
//   periph_test_dac_nack TB_MODE=2            DAC 数据 NACK -> sticky error,
//                                             ADS 帧活动不受影响
//   periph_test_dac_400  TB_DAC_TEST_MODE=1   捕获恒 0x400
//   periph_test_dac_c00  TB_DAC_TEST_MODE=2   捕获恒 0xC00
//   periph_test_dac_1khz TB_MODE=3            1 kHz/8 kS/s 八点波形循环
//   periph_test_heartbeat_real  TB_HEARTBEAT_HALF_CYC=6000000(板上真实
//                                             1 Hz 常量的接线与周期验证)
//
// 全部真实 12 MHz 节拍。注意:Verilog 任务参数按值传入(调用时求值一次),
// 因此所有动态等待都写成显式 while 循环,不经过任务参数。
// 诊断文本全 ASCII。判定行:TB_PERIPH_TEST_TOP: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_periph_test_top;

    parameter integer TB_MODE              = 0;
    parameter integer TB_DAC_TEST_MODE     = 0;
    parameter integer TB_HEARTBEAT_HALF_CYC = 2000;

    reg         clk;
    reg         rst_n;
    reg         adc_nack_addr;
    reg         dac_nack_data;
    wire        adc_scl, adc_sda;
    wire        dac_scl, dac_sda;
    wire        dbg_alive, dbg_adc, dbg_error;

    pullup pu_ascl (adc_scl);
    pullup pu_asda (adc_sda);
    pullup pu_dscl (dac_scl);
    pullup pu_dsda (dac_sda);

    periph_test_top #(
        .HEARTBEAT_HALF_CYC (TB_HEARTBEAT_HALF_CYC),
        .DAC_TEST_MODE      (TB_DAC_TEST_MODE)
    ) u_top (
        .clk          (clk),
        .rst_n        (rst_n),
        .adc_i2c_scl  (adc_scl),
        .adc_i2c_sda  (adc_sda),
        .dac_i2c_scl  (dac_scl),
        .dac_i2c_sda  (dac_sda),
        .dbg_alive    (dbg_alive),
        .dbg_adc      (dbg_adc),
        .dbg_error    (dbg_error)
    );

    ads1115_model #(
        .DEVICE_ADDR (7'h48),
        .CONV_CYCLES (2000)
    ) u_adc_model (
        .clk             (clk),
        .rst             (~rst_n),
        .nack_addr_en    (adc_nack_addr),
        .nack_data_en    (1'b0),
        .conv_never_done (1'b0),
        .scl             (adc_scl),
        .sda             (adc_sda)
    );

    mcp4725_model #(
        .DEVICE_ADDR (7'h60)
    ) u_dac_model (
        .clk          (clk),
        .rst          (~rst_n),
        .nack_addr_en (1'b0),
        .nack_data_en (dac_nack_data),
        .scl          (dac_scl),
        .sda          (dac_sda)
    );

    initial clk = 1'b0;
    always #41.667 clk = ~clk;

    integer checks;
    integer errors;
    integer g;

    //-------------------------------------------------------------------------
    // 事件计数(MCP 捕获 / 错误脉冲 / overrun)
    //-------------------------------------------------------------------------
    reg [11:0] captured [0:1023];
    reg [31:0] frame_time [0:1023];
    integer    cap_total;
    reg [31:0] prev_frames;
    integer    err_dac;
    integer    err_adc;
    integer    ov_cnt;

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            prev_frames = 32'd0;
            cap_total   = 0;
            err_dac     = 0;
            err_adc     = 0;
            ov_cnt      = 0;
        end else begin
            if (u_top.dac_error === 1'b1) err_dac = err_dac + 1;
            if (u_top.adc_error === 1'b1) err_adc = err_adc + 1;
            if (u_top.dac_overrun === 1'b1) ov_cnt = ov_cnt + 1;
            if (u_dac_model.frame_cnt > prev_frames) begin
                prev_frames = u_dac_model.frame_cnt;
                if (cap_total <= 1023) begin
                    captured[cap_total]   = u_dac_model.dac_out;
                    frame_time[cap_total] = $time;
                    cap_total = cap_total + 1;
                end
            end else if (u_dac_model.frame_cnt < prev_frames) begin
                prev_frames = u_dac_model.frame_cnt;
            end
        end
    end

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

    //-------------------------------------------------------------------------
    // 复位态检查(P9 §18)
    //-------------------------------------------------------------------------
    task reset_state_check;
        begin
            repeat (8) @(posedge clk);
            check_eq32(dbg_alive, 1'b0, "reset: dbg_alive == 0");
            check_eq32(dbg_adc,   1'b0, "reset: dbg_adc == 0");
            check_eq32(dbg_error, 1'b0, "reset: dbg_error == 0");
            check_eq32(u_adc_model.in_txn, 1'b0, "reset: ADC model idle");
            check_eq32(u_dac_model.byte_active, 1'b0, "reset: DAC model idle");
            check_true((adc_scl === 1'b1) && (adc_sda === 1'b1) &&
                       (dac_scl === 1'b1) && (dac_sda === 1'b1),
                       "reset: both I2C buses released high");
        end
    endtask

    //-------------------------------------------------------------------------
    // heartbeat:用拍计数测量半周期(不依赖 $time,避免沿检测调度差)。
    // g 为"稳定电平持续到下一次翻转"的拍数,期望 half_cyc(±4 调度余量)。
    //-------------------------------------------------------------------------
    task heartbeat_check;
        input integer half_cyc;
        reg  v0;
        reg  v1;
        begin
            g = 0;
            v0 = dbg_alive;
            while ((dbg_alive === v0) && (g < 8 * half_cyc + 100000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(dbg_alive !== v0, "heartbeat: output toggles");
            @(posedge clk);          // 越过翻转沿
            v1 = dbg_alive;
            g = 0;
            while ((dbg_alive === v1) && (g < 8 * half_cyc + 100000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(dbg_alive !== v1, "heartbeat: second toggle (half period)");
            checks = checks + 1;
            if ((g < half_cyc - 4) || (g > half_cyc + 4)) begin
                errors = errors + 1;
                $display("FAIL: heartbeat half period %0d clk, expected ~%0d",
                         g, half_cyc);
            end else begin
                $display("  ok: heartbeat half period %0d clk (target %0d)",
                         g, half_cyc);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer i;
    integer dac_frames0;
    integer toggle_cnt;
    reg     prev_toggle;
    integer ph;
    integer j;
    integer ok_cnt;
    integer wave_match;
    reg [11:0] dc_value;
    integer gap_ns;

    initial begin
        checks    = 0;
        errors    = 0;
        cap_total = 0;
        prev_frames = 32'd0;
        err_dac   = 0;
        err_adc   = 0;
        ov_cnt    = 0;
        adc_nack_addr = 1'b0;
        dac_nack_data = 1'b0;

        $display("TB_PERIPH_TEST_TOP: start (mode=%0d dac_mode=%0d hb=%0d)",
                 TB_MODE, TB_DAC_TEST_MODE, TB_HEARTBEAT_HALF_CYC);

        rst_n = 1'b0;
        repeat (32) @(posedge clk);

        //---------------------------------------------------------------------
        // MODE 0:normal + DC(P9 §18/§21/§22/§26)
        //---------------------------------------------------------------------
        if (TB_MODE == 0) begin
            reset_state_check;

            @(negedge clk);
            rst_n = 1'b1;

            heartbeat_check(TB_HEARTBEAT_HALF_CYC);

            // ADS 帧活动:dbg_adc 至少 toggle 4 次(>= 4 个完整三通道帧)
            toggle_cnt = 0;
            prev_toggle = dbg_adc;
            i = 0;
            while ((toggle_cnt < 4) && (i < 8000000)) begin
                @(posedge clk);
                if (dbg_adc !== prev_toggle) begin
                    toggle_cnt = toggle_cnt + 1;
                    prev_toggle = dbg_adc;
                end
                i = i + 1;
            end
            check_true(toggle_cnt >= 4, "ADS frames keep completing (dbg_adc toggles)");
            check_true(u_adc_model.stop_cnt > 0, "ADC bus transactions > 0");

            // DAC DC:捕获 >= 60 帧,全部等于期望 DC 值(P9 §26)
            dc_value = (TB_DAC_TEST_MODE == 1) ? 12'h400 :
                       (TB_DAC_TEST_MODE == 2) ? 12'hC00 : 12'h800;
            i = 0;
            while ((cap_total < 60) && (i < 4000000)) begin
                @(posedge clk);
                i = i + 1;
            end
            check_true(cap_total >= 60, "DAC captured >= 60 frames");
            ok_cnt = 0;
            for (j = 0; j < 60; j = j + 1) begin
                if (captured[j] === dc_value) ok_cnt = ok_cnt + 1;
            end
            check_eq32(ok_cnt, 60, "every captured DAC code == expected DC");

            check_eq32(dbg_error, 1'b0, "no sticky error in normal run");
            check_eq32(err_dac,   0,    "no dac_error pulses");
            check_eq32(err_adc,   0,    "no adc_error pulses");
            check_eq32(ov_cnt,    0,    "no DAC overrun");
            check_eq32(u_dac_model.eeprom_viol, 0, "no EEPROM writes");
        end

        //---------------------------------------------------------------------
        // MODE 1:ADC NACK 隔离(P9 §23/§25)
        //---------------------------------------------------------------------
        if (TB_MODE == 1) begin
            @(negedge clk);
            rst_n = 1'b1;

            // 先确认正常(等 dbg_adc 第一次翻转 = 至少一个完整帧)
            g = 0;
            while ((dbg_adc === 1'b0) && (g < 8000000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(dbg_adc === 1'b1, "normal ADS frames before fault");
            check_eq32(dbg_error, 1'b0, "no error before injection");

            adc_nack_addr = 1'b1;
            g = 0;
            while ((dbg_error !== 1'b1) && (g < 8000000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(dbg_error === 1'b1, "ADC NACK raises sticky error");

            // DAC 不受影响:注入期间继续完成 Fast Write
            dac_frames0 = u_dac_model.frame_cnt;
            i = 0;
            while ((u_dac_model.frame_cnt < dac_frames0 + 8) && (i < 8000000)) begin
                @(posedge clk);
                i = i + 1;
            end
            check_true(u_dac_model.frame_cnt >= dac_frames0 + 8,
                       "DAC keeps writing during ADC NACK storm");
            check_eq32(err_dac, 0, "DAC bus clean during ADC NACK");

            // 解除后 sticky 保持 1(P9 §25)
            adc_nack_addr = 1'b0;
            repeat (200000) @(posedge clk);
            check_eq32(dbg_error, 1'b1, "sticky error survives bus recovery");

            // 只有 reset 清除(P9 §25/§18)
            @(negedge clk);
            rst_n = 1'b0;
            repeat (16) @(posedge clk);
            check_eq32(dbg_error, 1'b0, "reset clears sticky error");
            @(negedge clk);
            rst_n = 1'b1;
            repeat (200000) @(posedge clk);
            check_eq32(dbg_error, 1'b0, "clean run after reset keeps error low");
            check_true(u_adc_model.stop_cnt > 0, "ADC rescans after reset");
        end

        //---------------------------------------------------------------------
        // MODE 2:DAC NACK 隔离(P9 §24/§25)
        //---------------------------------------------------------------------
        if (TB_MODE == 2) begin
            @(negedge clk);
            rst_n = 1'b1;

            g = 0;
            while ((dbg_adc === 1'b0) && (g < 8000000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(dbg_adc === 1'b1, "normal ADS frames before fault");
            check_eq32(dbg_error, 1'b0, "no error before injection");

            dac_nack_data = 1'b1;
            g = 0;
            while ((dbg_error !== 1'b1) && (g < 8000000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(dbg_error === 1'b1, "DAC NACK raises sticky error");

            // ADS 帧活动不受影响
            toggle_cnt = 0;
            prev_toggle = dbg_adc;
            i = 0;
            while ((toggle_cnt < 2) && (i < 8000000)) begin
                @(posedge clk);
                if (dbg_adc !== prev_toggle) begin
                    toggle_cnt = toggle_cnt + 1;
                    prev_toggle = dbg_adc;
                end
                i = i + 1;
            end
            check_true(toggle_cnt >= 2, "ADS frames keep flowing during DAC NACK");
            check_eq32(err_adc, 0, "ADC bus clean during DAC NACK");

            dac_nack_data = 1'b0;
            dac_frames0 = u_dac_model.frame_cnt;
            i = 0;
            while ((u_dac_model.frame_cnt < dac_frames0 + 8) && (i < 8000000)) begin
                @(posedge clk);
                i = i + 1;
            end
            check_true(u_dac_model.frame_cnt >= dac_frames0 + 8,
                       "DAC recovers and keeps writing after NACK release");
            check_eq32(dbg_error, 1'b1, "sticky error survives bus recovery");

            @(negedge clk);
            rst_n = 1'b0;
            repeat (16) @(posedge clk);
            check_eq32(dbg_error, 1'b0, "reset clears sticky error");
        end

        //---------------------------------------------------------------------
        // MODE 3:1 kHz 八点波形(P9 §15/§27)
        //---------------------------------------------------------------------
        if (TB_MODE == 3) begin
            @(negedge clk);
            rst_n = 1'b1;

            i = 0;
            while ((cap_total < 400) && (i < 8000000)) begin
                @(posedge clk);
                i = i + 1;
            end
            check_true(cap_total >= 400, "1kHz mode: captured >= 400 samples");

            // 循环序列匹配:存在相位 ph 使 captured[i] == wave[(ph+i) % 8]。
            // captured[0] 是复位直通值(首个 valid 拍 controller 锁存的是
            // 复位 0x800,不是波形首点),从 captured[1] 起匹配 399 帧。
            wave_match = 0;
            for (ph = 0; (ph < 8) && (wave_match == 0); ph = ph + 1) begin
                ok_cnt = 0;
                for (j = 1; j < 400; j = j + 1) begin
                    case ((ph + j - 1) % 8)
                        0: if (captured[j] === 12'd2048) ok_cnt = ok_cnt + 1;
                        1: if (captured[j] === 12'd3316) ok_cnt = ok_cnt + 1;
                        2: if (captured[j] === 12'd3840) ok_cnt = ok_cnt + 1;
                        3: if (captured[j] === 12'd3316) ok_cnt = ok_cnt + 1;
                        4: if (captured[j] === 12'd2048) ok_cnt = ok_cnt + 1;
                        5: if (captured[j] === 12'd780)  ok_cnt = ok_cnt + 1;
                        6: if (captured[j] === 12'd256)  ok_cnt = ok_cnt + 1;
                        7: if (captured[j] === 12'd780)  ok_cnt = ok_cnt + 1;
                    endcase
                end
                if (ok_cnt == 399) wave_match = 1;
            end
            check_eq32(wave_match, 1, "8-sample 1 kHz sequence repeats exactly");

            // 8 kS/s cadence:帧间隔 ~125 us(容差 +-3 us)
            ok_cnt = 0;
            for (j = 50; j < 350; j = j + 1) begin
                gap_ns = frame_time[j] - frame_time[j - 1];
                if ((gap_ns > 122000) && (gap_ns < 128000)) ok_cnt = ok_cnt + 1;
            end
            check_eq32(ok_cnt, 300, "frame interval ~= 8 kS/s cadence");

            check_eq32(err_dac, 0, "no dac_error in 1kHz run");
            check_eq32(ov_cnt,  0, "no overrun in 1kHz run");
            check_eq32(u_dac_model.eeprom_viol, 0, "no EEPROM writes");
        end

        $display("TB_PERIPH_TEST_TOP: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) begin
            $display("TB_PERIPH_TEST_TOP: PASS");
        end else begin
            $display("TB_PERIPH_TEST_TOP: FAIL");
        end
        $finish;
    end

endmodule
