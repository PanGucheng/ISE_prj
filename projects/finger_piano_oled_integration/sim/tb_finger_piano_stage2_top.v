//=============================================================================
// tb_finger_piano_stage2_top.v — finger_piano_stage2_top 物理顶层验收(P6B)
//
// 目的(P6B §16):P6A 已经逐样点验证过 finger_piano_system 的内部数字行为,
// 本 TB 不重复 longrun,只验证物理顶层 wrapper 的接线:
//
//   - reset_sync -> rst_n_sync 门控(复位态输出确定、两条 I2C 总线释放);
//   - 顶层 inout I2C 端口与两条独立总线上的协议模型正确互通;
//   - note_code -> note_debug 直通;
//   - 顶层承载下 ADC 扫描帧 / DAC Fast Write 仍完整工作,零错误。
//
// 复用现有 verilog 模型(sim/models/ads1115_model.v / mcp4725_model.v),
// 不新建第三套行为模型(P6B §15)。I2C 用 ISim pullup 只表示开漏逻辑高,
// **不**代表真实 4.7kΩ RC 上升时间(P6B §18)。
//
// 真实 12 MHz 节拍 + 真实 10 ms sensor 滤波门限;ADS 转换耗时缩短为
// TB_CONV_CYCLES=2000 拍以加速仿真(与 P6A 基础系统 TB 相同手法)。
//
// 诊断文本全 ASCII。判定行:TB_FINGER_PIANO_STAGE2_TOP: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

`include "finger_piano_cfg.vh"

module tb_finger_piano_stage2_top;

    parameter integer TB_SYS_CLK_HZ  = 12000000;
    parameter integer TB_SAMPLE_RATE = 8000;
    parameter integer TB_STABLE_MS   = `KEY_STABLE_MS;
    parameter integer TB_CONV_CYCLES = 2000;

    localparam integer STABLE_CYC = (TB_SYS_CLK_HZ / 1000) * TB_STABLE_MS;
    localparam integer SAMPLE_CYC = TB_SYS_CLK_HZ / TB_SAMPLE_RATE;

    reg         clk;
    reg         rst_n;
    reg  [2:0]  sensor_async;
    reg         adc_nack_addr, adc_nack_data;
    reg         dac_nack_addr, dac_nack_data;

    wire        adc_scl, adc_sda;
    wire        dac_scl, dac_sda;
    wire [2:0]  note_debug;

    // P6B §18:逻辑开漏上拉(NOT a real RC model)
    pullup pu_ascl (adc_scl);
    pullup pu_asda (adc_sda);
    pullup pu_dscl (dac_scl);
    pullup pu_dsda (dac_sda);

    //-------------------------------------------------------------------------
    // DUT:物理顶层(只有 12 个用户 I/O 的 wrapper)
    //-------------------------------------------------------------------------
    finger_piano_stage2_top u_top (
        .clk         (clk),
        .rst_n       (rst_n),
        .sensor_async(sensor_async),
        .adc_i2c_scl (adc_scl),
        .adc_i2c_sda (adc_sda),
        .dac_i2c_scl (dac_scl),
        .dac_i2c_sda (dac_sda),
        .note_debug  (note_debug)
    );

    //-------------------------------------------------------------------------
    // 协议模型(接在顶层 inout 端口上,与板上器件等价)
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
    // 时钟:真实 12 MHz(周期 83.334 ns)
    //-------------------------------------------------------------------------
    initial clk = 1'b0;
    always #41.667 clk = ~clk;

    integer checks;
    integer errors;

    //-------------------------------------------------------------------------
    // DUT 内部状态观测(只读,层次引用;顶层不暴露 pressure/error 端口)
    //-------------------------------------------------------------------------
    wire [14:0] p_ch0 = u_top.u_sys.pressure_ch0;
    wire [14:0] p_ch1 = u_top.u_sys.pressure_ch1;
    wire [14:0] p_ch2 = u_top.u_sys.pressure_ch2;
    wire        p_valid = u_top.u_sys.pressure_valid;
    wire        adc_err = u_top.u_sys.adc_error;
    wire        dac_err = u_top.u_sys.dac_error;
    wire        dac_over = u_top.u_sys.dac_overrun;

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
    // MCP4725 Fast Write 捕获(mute 段要求逐样点 0x800)
    //-------------------------------------------------------------------------
    reg [11:0] captured_mem [0:4095];
    integer    cap_total;
    reg [31:0] prev_frames;

    reg         seg_mute_en;
    integer     mute_bad;

    integer     dac_frames_note1;
    integer     dac_frames_note7;
    integer     dac_frames_mute;

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            prev_frames = 32'd0;
            cap_total   = 0;
            mute_bad    = 0;
            seg_mute_en = 1'b0;
        end else begin
            if (u_dac_model.frame_cnt > prev_frames) begin
                prev_frames = u_dac_model.frame_cnt;
                if (cap_total <= 4095) begin
                    captured_mem[cap_total] = u_dac_model.dac_out;
                    cap_total = cap_total + 1;
                    if (seg_mute_en && (u_dac_model.dac_out !== 12'h800)) begin
                        mute_bad = mute_bad + 1;
                        $display("FAIL: mute sample %0d != 0x800 at idx %0d",
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
    // stimulus 辅助任务
    //-------------------------------------------------------------------------
    task drive_sensor;
        input [2:0] code;
        begin
            @(negedge clk);
            sensor_async = code;
        end
    endtask

    // 等滤波门限 + 2FF 同步 + 解码,确认 note_debug 切到期望编码
    task wait_note;
        input [2:0] code;
        integer g;
        begin
            g = 0;
            while ((note_debug !== code) && (g < STABLE_CYC + 200000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_eq32(note_debug, code, "note_debug after filter+decode");
        end
    endtask

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

    task collect_frames;
        input integer n;
        integer g;
        integer t0;
        begin
            t0 = cap_total + n;
            g  = 0;
            while ((cap_total < t0) && (g < n * SAMPLE_CYC + 200000)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(cap_total >= t0, "collected MCP4725 frames in time");
        end
    endtask

    task wait_pvalid;
        input integer n;
        input integer limit;
        integer g;
        begin
            g = 0;
            while ((pvalid_cnt < n) && (g < limit)) begin
                @(posedge clk);
                g = g + 1;
            end
            check_true(pvalid_cnt >= n, "internal pressure frames arrived in time");
        end
    endtask

    // 一段传感器编码:切换 -> 等稳定 -> 收集 DAC 事务
    task run_segment;
        input [2:0] code;
        input integer is_mute;
        integer base;
        begin
            $display("  info: segment sensor=%0d mute=%0d", code, is_mute);
            drive_sensor(code);
            wait_note(code);
            skip_frames(8);                 // 排除切换过渡样点

            base = u_dac_model.frame_cnt;
            if (is_mute) begin
                seg_mute_en = 1'b1;
                collect_frames(128);
                seg_mute_en = 1'b0;
                dac_frames_mute = dac_frames_mute + (u_dac_model.frame_cnt - base);
            end else begin
                seg_mute_en = 1'b0;
                collect_frames(256);
                if (code == 3'd1)
                    dac_frames_note1 = dac_frames_note1 + (u_dac_model.frame_cnt - base);
                else if (code == 3'd7)
                    dac_frames_note7 = dac_frames_note7 + (u_dac_model.frame_cnt - base);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer rst_bus_ok;

    initial begin
        checks     = 0;
        errors     = 0;

        adc_nack_addr  = 1'b0;
        adc_nack_data  = 1'b0;
        dac_nack_addr  = 1'b0;
        dac_nack_data  = 1'b0;
        sensor_async   = 3'd0;
        seg_mute_en    = 1'b0;
        dac_frames_note1 = 0;
        dac_frames_note7 = 0;
        dac_frames_mute  = 0;

        $display("TB_FINGER_PIANO_STAGE2_TOP: start");

        rst_n = 1'b0;
        repeat (32) @(posedge clk);

        //---------------------------------------------------------------------
        // §17 Reset:note_debug = 000,两条 I2C 总线释放(pullup 为高)
        //---------------------------------------------------------------------
        check_eq32(note_debug, 3'd0, "reset: note_debug == 000");
        rst_bus_ok = (adc_scl === 1'b1) && (adc_sda === 1'b1) &&
                     (dac_scl === 1'b1) && (dac_sda === 1'b1);
        check_true(rst_bus_ok, "reset: both I2C buses released high");
        check_eq32(pvalid_cnt, 0, "reset: no pressure frames");

        @(posedge clk);
        rst_n = 1'b1;
        $display("  info: reset released");

        //---------------------------------------------------------------------
        // §17 ADC:模型给出 1000/2000/3000,系统内部完成 pressure frame
        //---------------------------------------------------------------------
        wait_pvalid(2, 4000000);
        check_eq32(p_ch0, 15'd1000, "internal pressure_ch0 == 1000");
        check_eq32(p_ch1, 15'd2000, "internal pressure_ch1 == 2000");
        check_eq32(p_ch2, 15'd3000, "internal pressure_ch2 == 3000");

        //---------------------------------------------------------------------
        // §17 sensor:000 -> 001 -> 011 -> 111 -> 000,note_debug 必须对应
        //        0 -> 1 -> 3 -> 7 -> 0;同时 DAC 持续 Fast Write
        //---------------------------------------------------------------------
        run_segment(3'd0, 1);   // mute
        run_segment(3'd1, 0);   // C4
        run_segment(3'd3, 0);   // E4
        run_segment(3'd7, 0);   // B4
        run_segment(3'd0, 1);   // mute

        //---------------------------------------------------------------------
        // §17 DAC:note 1 / note 7 / mute 都产生了 MCP4725 Fast Write
        //---------------------------------------------------------------------
        check_true(dac_frames_note1 > 0, "note 1 produced MCP4725 Fast Writes");
        check_true(dac_frames_note7 > 0, "note 7 produced MCP4725 Fast Writes");
        check_true(dac_frames_mute  > 0, "mute produced MCP4725 Fast Writes");
        check_eq32(mute_bad, 0, "mute windows all held 0x800");

        //---------------------------------------------------------------------
        // §17 双总线同时工作:ADC / DAC 事务 > 0,零 adc_error / dac_error /
        //      dac_overrun
        //---------------------------------------------------------------------
        check_true(u_adc_model.stop_cnt > 0, "ADC bus transactions > 0");
        check_true(u_dac_model.frame_cnt > 0, "DAC bus transactions > 0");
        check_eq32(adc_err_cnt,  0, "adc_error count == 0");
        check_eq32(dac_err_cnt,  0, "dac_error count == 0");
        check_eq32(dac_over_cnt, 0, "dac_overrun count == 0");
        check_eq32(u_dac_model.eeprom_viol, 0, "no MCP4725 EEPROM command");

        //---------------------------------------------------------------------
        // §17 复位保持:拉低 rst_n,输出回到确定状态、总线释放
        //---------------------------------------------------------------------
        @(negedge clk);
        rst_n = 1'b0;
        sensor_async = 3'd0;
        repeat (16) @(posedge clk);
        check_eq32(note_debug, 3'd0, "re-reset: note_debug back to 000");
        check_true((adc_scl === 1'b1) && (adc_sda === 1'b1) &&
                   (dac_scl === 1'b1) && (dac_sda === 1'b1),
                   "re-reset: both I2C buses released high");

        $display("TB_FINGER_PIANO_STAGE2_TOP: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) begin
            $display("TB_FINGER_PIANO_STAGE2_TOP: PASS");
        end else begin
            $display("TB_FINGER_PIANO_STAGE2_TOP: FAIL");
        end
        $finish;
    end

endmodule
