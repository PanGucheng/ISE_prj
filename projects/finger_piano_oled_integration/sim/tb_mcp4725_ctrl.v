//=============================================================================
// tb_mcp4725_ctrl.v — mcp4725_ctrl 验收(P1 计划 C 阶段,任务书 §29 + 吞吐)
//
// 覆盖项(P1 计划要求):
//   1) 依次发送 000/800/FFF/123/ABC:Fast Write 拆分(字节1 高半字节
//      0000 + D[11:8],字节2 D[7:0])、地址 7'h60、ACK、STOP、busy/ready
//      时序、VOUT 更新(dac_out)、PD=00;
//   2) **无 EEPROM 命令**:模型检测任何首数据字节 C2C1C0 != 000 即违规;
//   3) 地址 NACK -> error_code=1;数据 NACK -> error_code=2,并可恢复;
//   4) 过载刺激:pending 占用期间再推样点 -> dac_overrun 置位且
//      pending **不被覆盖**(发出的仍是先接受的样点);
//   5) **吞吐(真实 12 MHz + 333333,不降频)**:SCL 高相位恒 18 拍
//      (18+18=36 拍设计目标,不是公式的 37 拍),以 8 kHz(每 1500 拍)
//      连续送 120 个样点 -> 0 overrun / 0 丢样;
//   6) ENABLE=0:总线无边沿,ready 恒 0,无任何标志。
//
// ISim 的 pullup 只模拟逻辑上拉,不是 4.7 kΩ + 总线电容的上升沿模型。
// 诊断文本全 ASCII。判定行:TB_MCP4725_CTRL: PASS / FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_mcp4725_ctrl;

    localparam integer GUARD        = 5000;      // 等事务完成的周期上限
    localparam integer ERROR_GUARD  = 200000;    // 等一个 error 的周期上限
    localparam integer THR_N        = 120;       // 吞吐样点数(>= 100)
    localparam integer THR_DIV      = 1500;      // 8 kHz @ 12 MHz
    localparam integer QUIET_CYCLES = 60000;     // ENABLE=0 安静观测窗口

    integer checks;
    integer errors;
    reg [2:0] ecode;

    reg clk;
    reg rst_n;

    //-------------------------------------------------------------------------
    // 实例 1:协议测试(总线 1)
    //-------------------------------------------------------------------------
    reg  [11:0] dac_code1;
    reg         dac_valid1;
    wire        ready1;
    wire        busy1;
    wire        err1;
    wire        overrun1;
    wire [2:0]  err_code1;
    wire        scl1, sda1;

    //-------------------------------------------------------------------------
    // 实例 2:吞吐测试(总线 2,真实 12 MHz + 333333)
    //-------------------------------------------------------------------------
    reg  [11:0] dac_code2;
    reg         dac_valid2;
    wire        ready2;
    wire        busy2;
    wire        err2;
    wire        overrun2;
    wire [2:0]  err_code2;
    wire        scl2, sda2;

    //-------------------------------------------------------------------------
    // 实例 3:ENABLE=0(总线 3)
    //-------------------------------------------------------------------------
    reg  [11:0] dac_code3;
    reg         dac_valid3;
    wire        ready3;
    wire        busy3;
    wire        err3;
    wire        overrun3;
    wire [2:0]  err_code3;
    wire        scl3, sda3;

    // 模型注入
    reg nack_addr_en1;
    reg nack_data_en1;

    pullup pu_scl1 (scl1);
    pullup pu_sda1 (sda1);
    pullup pu_scl2 (scl2);
    pullup pu_sda2 (sda2);
    pullup pu_scl3 (scl3);
    pullup pu_sda3 (sda3);

    mcp4725_ctrl #(
        .ENABLE(1'b1)
    ) u_dut (
        .clk           (clk),
        .rst_n_sync    (rst_n),
        .dac_code      (dac_code1),
        .dac_code_valid(dac_valid1),
        .dac_code_ready(ready1),
        .dac_busy      (busy1),
        .dac_error     (err1),
        .dac_overrun   (overrun1),
        .error_code    (err_code1),
        .dac_i2c_scl   (scl1),
        .dac_i2c_sda   (sda1)
    );

    mcp4725_ctrl #(
        .ENABLE(1'b1)
    ) u_dut_thr (
        .clk           (clk),
        .rst_n_sync    (rst_n),
        .dac_code      (dac_code2),
        .dac_code_valid(dac_valid2),
        .dac_code_ready(ready2),
        .dac_busy      (busy2),
        .dac_error     (err2),
        .dac_overrun   (overrun2),
        .error_code    (err_code2),
        .dac_i2c_scl   (scl2),
        .dac_i2c_sda   (sda2)
    );

    mcp4725_ctrl #(
        .ENABLE(1'b0)
    ) u_dut_off (
        .clk           (clk),
        .rst_n_sync    (rst_n),
        .dac_code      (dac_code3),
        .dac_code_valid(dac_valid3),
        .dac_code_ready(ready3),
        .dac_busy      (busy3),
        .dac_error     (err3),
        .dac_overrun   (overrun3),
        .error_code    (err_code3),
        .dac_i2c_scl   (scl3),
        .dac_i2c_sda   (sda3)
    );

    mcp4725_model #(
        .DEVICE_ADDR(7'h60)
    ) u_model (
        .clk          (clk),
        .rst          (~rst_n),
        .nack_addr_en (nack_addr_en1),
        .nack_data_en (nack_data_en1),
        .scl          (scl1),
        .sda          (sda1)
    );

    mcp4725_model #(
        .DEVICE_ADDR(7'h60)
    ) u_model_thr (
        .clk          (clk),
        .rst          (~rst_n),
        .nack_addr_en (1'b0),
        .nack_data_en (1'b0),
        .scl          (scl2),
        .sda          (sda2)
    );

    // 仿真时钟 10 ns
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // 实例 1 事件计数
    //-------------------------------------------------------------------------
    integer err_cnt1;
    always @(posedge clk) begin
        if (!rst_n) err_cnt1 = 0;
        else if (err1 === 1'b1) err_cnt1 = err_cnt1 + 1;
    end

    //-------------------------------------------------------------------------
    // 总线 3 边沿计数(ENABLE=0 静默检查)
    //-------------------------------------------------------------------------
    integer bus3_edges;
    reg     scl3_q, sda3_q;
    always @(posedge clk) begin
        scl3_q <= scl3;
        sda3_q <= sda3;
        if ((scl3 !== scl3_q) || (sda3 !== sda3_q)) begin
            bus3_edges = bus3_edges + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 总线 2:SCL 相位宽度测量(只在事务期间观测)
    //   高段 == 18(总线空闲/STOP 尾巴的高段 > 100 拍,跳过不计);
    //   低段 == 18 或 > 18(命令边界的低段合法地长于 18),< 18 违规;
    //   rise-to-rise 周期 == 36(18+18 设计目标)或 > 36(边界),
    //   < 36 违规(含公式错误情形,如高 21/14 必然先被高段检查抓到)。
    //-------------------------------------------------------------------------
    reg [31:0] cur_hi, cur_lo, prev_hi_seg;
    reg        pscl2;
    reg        obs_started;   // 从第一个 SCL 下落沿才开始计数(窗口起点的
                              // 高段含进入前的总线空闲,不完整,跳过)
    integer    hi18, hi_bad, lo18, lo_big, lo_bad, p36, pbig, pbad;
    reg        obs_en;
    always @(posedge clk) begin
        if (!rst_n) begin
            cur_hi = 0; cur_lo = 0; prev_hi_seg = 0; pscl2 = 1'b1;
            obs_started = 1'b0;
            hi18 = 0; hi_bad = 0; lo18 = 0; lo_big = 0; lo_bad = 0;
            p36 = 0; pbig = 0; pbad = 0; obs_en = 1'b0;
        end else if (obs_en && busy2 === 1'b1) begin
            if (scl2 !== pscl2) begin
                // 先结算完整段 -> 打印 -> 清零 -> 再累计本沿开始的新段的首拍
                if (scl2 === 1'b0) begin
                    // 下降沿:结算刚结束的高段
                    if (obs_started) begin
                        if (cur_hi == 18)     hi18 = hi18 + 1;
                        else if (cur_hi > 40) ;   // 跨帧长高段(busy 门控截断的
                                                  // 总线空闲+START 前导),跳过;
                                                  // 真实时钟高段恒 18,公式错误
                                                  // 值 <=21 仍会被下面抓到
                        else                  hi_bad = hi_bad + 1;
                        prev_hi_seg = cur_hi;
                    end else begin
                        // 窗口第一个下落沿:此前的高段不完整,丢弃;
                        // 哨兵值让首个周期被归入"边界"而非误判 <36
                        obs_started = 1'b1;
                        prev_hi_seg = 32'd200;
                    end
                    cur_hi = 0;
                    cur_lo = 0;
                    pscl2  = scl2;
                    cur_lo = cur_lo + 1;   // 本沿是低段第一拍
                end else begin
                    // 上升沿:结算刚结束的低段与完整位周期
                    if (obs_started) begin
                        if (cur_lo == 18)      lo18 = lo18 + 1;
                        else if (cur_lo > 18)  lo_big = lo_big + 1;
                        else                   lo_bad = lo_bad + 1;
                        if ((prev_hi_seg + cur_lo) == 36)     p36 = p36 + 1;
                        else if ((prev_hi_seg + cur_lo) > 36) pbig = pbig + 1;
                        else                                  pbad = pbad + 1;
                    end
                    cur_hi = 0;
                    cur_lo = 0;
                    pscl2  = scl2;
                    cur_hi = cur_hi + 1;   // 本沿是高段第一拍
                end
            end else begin
                if (scl2 === 1'b1) cur_hi = cur_hi + 1;
                else               cur_lo = cur_lo + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 检查任务
    //-------------------------------------------------------------------------
    task check_eq32;
        input integer    got;
        input integer    exp;
        input [8*72-1:0] label;
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

    task check_true;
        input            cond;
        input [8*72-1:0] label;
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
    // 实例 1 发一个样点(等 ready -> 推 valid -> 等事务结束)
    //-------------------------------------------------------------------------
    task dac_send;
        input [11:0] c;
        integer g;
        begin
            g = 0;
            @(negedge clk);
            while ((ready1 !== 1'b1) && (g < GUARD)) begin
                @(negedge clk);
                g = g + 1;
            end
            checks = checks + 1;
            if (ready1 !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: dac_send: ready never asserted");
            end
            dac_code1  = c;
            dac_valid1 = 1'b1;
            @(negedge clk);
            dac_valid1 = 1'b0;
            g = 0;
            while ((busy1 !== 1'b1) && (g < GUARD)) begin
                @(negedge clk);
                g = g + 1;
            end
            g = 0;
            while ((busy1 !== 1'b0) && (g < GUARD)) begin
                @(negedge clk);
                g = g + 1;
            end
            @(negedge clk);
        end
    endtask

    //-------------------------------------------------------------------------
    // 等待实例 1 的 dac_error(有界;基线在触发事务之前由调用方记录)
    //-------------------------------------------------------------------------
    task wait_error_since;
        input integer base;
        input integer max_cycles;
        output [2:0] code;
        integer c0;
        begin
            c0 = 0;
            while ((err_cnt1 == base) && (c0 < max_cycles)) begin
                @(posedge clk);
                c0 = c0 + 1;
            end
            checks = checks + 1;
            if (err_cnt1 == base) begin
                errors = errors + 1;
                $display("FAIL: no dac_error within %0d cycles", max_cycles);
            end
            code = err_code1;
        end
    endtask

    //-------------------------------------------------------------------------
    // 发一帧并检查模型收到的完整内容
    //-------------------------------------------------------------------------
    task send_and_check;
        input [11:0] c;
        integer f0;
        begin
            f0 = u_model.frame_cnt;
            dac_send(c);
            checks = checks + 1;
            if (u_model.frame_cnt !== f0 + 1) begin
                errors = errors + 1;
                $display("FAIL: send %0h: frame_cnt %0d -> %0d",
                         c, f0, u_model.frame_cnt);
            end else begin
                $display("  ok: send %0h delivered", c);
            end
            check_eq32(u_model.dac_out, c,       "  dac_out == code (VOUT updated)");
            check_eq32(u_model.last_addr, 7'h60, "  device address == 0x60");
            check_eq32({u_model.last_b1[7:4], u_model.last_b1[3:0], u_model.last_b2},
                       {4'h0, c[11:8], c[7:0]},
                       "  byte split {0000,D11..D8},{D7..D0}");
            check_eq32(u_model.pd_bits, 2'b00,   "  PD1PD0 == 00 (normal mode)");
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer k;
    integer sent_cnt;
    integer acc_cnt;
    integer f0;
    integer ebase;
    reg [11:0] thr_code;
    reg [31:0] thr_div;

    // 吞吐实例的接收计数(与 DUT 同沿采样:valid && ready)
    always @(posedge clk) begin
        if (!rst_n)                acc_cnt = 0;
        else if (dac_valid2 && ready2) acc_cnt = acc_cnt + 1;
    end

    initial begin
        checks       = 0;
        errors       = 0;
        err_cnt1     = 0;
        bus3_edges   = 0;
        scl3_q       = 1'b1;
        sda3_q       = 1'b1;
        nack_addr_en1= 1'b0;
        nack_data_en1= 1'b0;
        dac_code1    = 12'h000;
        dac_valid1   = 1'b0;
        dac_code2    = 12'h000;
        dac_valid2   = 1'b0;
        dac_code3    = 12'h000;
        dac_valid3   = 1'b0;
        clk          = 1'b0;
        rst_n        = 1'b0;
        sent_cnt     = 0;
        acc_cnt      = 0;
        thr_code     = 12'h000;
        thr_div      = 32'd0;

        $display("TB_MCP4725_CTRL: start");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        //---------------------------------------------------------------------
        // T1:协议序列 000/800/FFF/123/ABC
        //---------------------------------------------------------------------
        $display("T1: fast write sequence");
        dac_valid1 = 1'b0;
        send_and_check(12'h000);
        send_and_check(12'h800);
        send_and_check(12'hFFF);
        send_and_check(12'h123);
        send_and_check(12'hABC);
        check_eq32(u_model.eeprom_viol, 0,  "T1 no EEPROM command on the bus");
        check_eq32(err_cnt1, 0,             "T1 no error in clean sequence");
        check_true(overrun1 === 1'b0,       "T1 no overrun in clean sequence");

        //---------------------------------------------------------------------
        // T2:地址 NACK -> 1,恢复(DAC 被动,必须先推样点触发事务;
        // 错误基线必须在发送前记录)
        //---------------------------------------------------------------------
        $display("T2: address NACK -> error_code 1");
        nack_addr_en1 = 1'b1;
        ebase = err_cnt1;
        dac_send(12'h555);
        wait_error_since(ebase, ERROR_GUARD, ecode);
        check_eq32(ecode, 3'd1, "T2 address NACK mapped to error_code 1");
        nack_addr_en1 = 1'b0;
        send_and_check(12'h246);
        check_eq32(err_code1, 3'd0, "T2 error_code cleared by next good frame");

        //---------------------------------------------------------------------
        // T3:数据 NACK -> 2,恢复
        //---------------------------------------------------------------------
        $display("T3: data NACK -> error_code 2");
        nack_data_en1 = 1'b1;
        ebase = err_cnt1;
        dac_send(12'h666);
        wait_error_since(ebase, ERROR_GUARD, ecode);
        check_eq32(ecode, 3'd2, "T3 data NACK mapped to error_code 2");
        nack_data_en1 = 1'b0;
        send_and_check(12'h39C);
        check_eq32(err_code1, 3'd0, "T3 error_code cleared by next good frame");

        //---------------------------------------------------------------------
        // T4:过载刺激:pending 占用期间再推 -> overrun 且不覆盖
        //---------------------------------------------------------------------
        $display("T4: overrun while busy, pending not overwritten");
        dac_send(12'hA57);              // 先正常发一帧,清空 pending
        f0 = u_model.frame_cnt;
        @(negedge clk);
        dac_code1  = 12'hBEF;           // 样点 A:先接受,进入事务
        dac_valid1 = 1'b1;
        @(negedge clk);
        dac_valid1 = 1'b0;
        begin : T4_WAIT_BUSY
            integer g;
            g = 0;
            while ((busy1 !== 1'b1) && (g < GUARD)) begin
                @(negedge clk);
                g = g + 1;
            end
        end
        // 事务进行中(ready=0)再推一个不同样点 B:必须被拒绝且置 overrun
        dac_code1  = 12'h123;
        dac_valid1 = 1'b1;
        @(negedge clk);
        dac_valid1 = 1'b0;
        @(negedge clk);
        check_true(overrun1 === 1'b1, "T4 dac_overrun set");
        begin : T4_WAIT_DONE
            integer g;
            g = 0;
            while ((busy1 !== 1'b0) && (g < GUARD)) begin
                @(negedge clk);
                g = g + 1;
            end
        end
        @(negedge clk);
        // 发出的帧必须是先接受的 BEF,不是过载的 123(pending 未被覆盖)
        check_eq32(u_model.dac_out, 12'hBEF, "T4 pending sample BEF transmitted");
        check_eq32(u_model.frame_cnt, f0 + 1, "T4 exactly one extra frame (123 rejected)");

        //---------------------------------------------------------------------
        // T5:吞吐(真实 12 MHz + 333333,8 kHz,120 样点)
        //---------------------------------------------------------------------
        $display("T5: throughput 12 MHz / 333333 / 8 kHz / %0d samples", THR_N);
        thr_code  = 12'h000;
        thr_div   = 32'd0;
        sent_cnt  = 0;
        acc_cnt   = 0;
        obs_en    = 1'b1;

        begin : T5_PRODUCER
            integer n;
            n = 0;
            dac_valid2 = 1'b0;
            while (n < THR_N) begin
                @(posedge clk);
                if (thr_div == THR_DIV - 1) begin
                    thr_div    = 32'd0;
                    dac_code2  = thr_code;
                    dac_valid2 = 1'b1;
                    thr_code   = thr_code + 12'h001;
                    n          = n + 1;
                    sent_cnt   = sent_cnt + 1;
                end else begin
                    thr_div    = thr_div + 32'd1;
                    dac_valid2 = 1'b0;
                end
            end
            // 末脉冲不清:先等下一个沿被 DUT 采样,再拉低(见下)
        end
        @(posedge clk);           // 让最后一个 valid 脉冲被 DUT 采样
        dac_valid2 = 1'b0;

        // 等最后一帧:先等 busy 上升,再等下降(推入后 busy 有短暂为 0 的窗口)
        begin : T5_DRAIN
            integer g;
            g = 0;
            while ((busy2 !== 1'b1) && (g < GUARD)) begin
                @(negedge clk);
                g = g + 1;
            end
            g = 0;
            while ((busy2 !== 1'b0) && (g < 4 * GUARD)) begin
                @(negedge clk);
                g = g + 1;
            end
        end
        @(negedge clk);

        check_eq32(acc_cnt, THR_N,            "T5 all samples accepted (ready)");
        check_eq32(u_model_thr.frame_cnt, THR_N, "T5 all frames delivered (0 drop)");
        check_true(overrun2 === 1'b0,         "T5 zero overrun at 8 kHz");
        check_true(err2 === 1'b0,             "T5 no error");
        check_true(hi_bad == 0,               "T5 every SCL high phase == 18 cycles");
        check_true(lo_bad == 0,               "T5 no SCL low phase < 18 cycles");
        check_true(pbad == 0,                 "T5 no bit period < 36 cycles");
        check_true(hi18 > 0,                  "T5 18-cycle high phases observed");
        check_true(lo18 > 0,                  "T5 18-cycle low phases observed");
        check_true(p36 > 0,                   "T5 36-cycle bit periods (18+18) observed");
        obs_en = 1'b0;

        //---------------------------------------------------------------------
        // T6:ENABLE=0 静默
        //---------------------------------------------------------------------
        $display("T6: ENABLE=0 instance stays silent");
        begin : T6_BLOCK
            integer c;
            integer edges0;
            edges0 = bus3_edges;
            c = 0;
            while (c < QUIET_CYCLES) begin
                @(posedge clk);
                // 期间不时推样点:关闭态无人接收,不得置任何标志
                if (c % 5000 == 0) begin
                    dac_code3  <= 12'hABC;
                    dac_valid3 <= 1'b1;
                end else begin
                    dac_valid3 <= 1'b0;
                end
                c = c + 1;
            end
            dac_valid3 <= 1'b0;
            check_eq32(bus3_edges - edges0, 0, "T6 no SCL/SDA edges on bus 3");
            check_true(ready3   === 1'b0,      "T6 ready3 == 0 (nothing accepts)");
            check_true(busy3    === 1'b0,      "T6 busy3 == 0");
            check_true(err3     === 1'b0,      "T6 error3 == 0");
            check_true(overrun3 === 1'b0,      "T6 overrun3 == 0");
            check_true((scl3 === 1'b1) && (sda3 === 1'b1),
                       "T6 bus 3 pulled high (released)");
        end

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("TB_MCP4725_CTRL: PASS (checks=%0d, errors=0, sim_time=%0t)",
                     checks, $time);
        end else begin
            $display("TB_MCP4725_CTRL: FAIL (checks=%0d, errors=%0d, sim_time=%0t)",
                     checks, errors, $time);
        end

        $finish;
    end

endmodule
