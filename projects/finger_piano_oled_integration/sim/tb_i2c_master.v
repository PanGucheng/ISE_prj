//=============================================================================
// tb_i2c_master.v — i2c_master 验收（P1 计划 A 阶段）
//
// 覆盖项（对应 P1 计划对 tb_i2c_master 的要求）：
//   1) 复位后总线释放（SCL/SDA 为 Z，上拉后为高）、cmd_ready=1、事务态清空
//   2) 协议错误：无事务时 WRITE / READ / STOP / RESTART -> error_code=3
//      且不产生任何总线活动；事务中再次 START -> error_code=3
//   3) START 条件：SDA 在 SCL 高电平期间下落，随后 SCL 拉低并被主机保持
//   4) 写字节 + 从机 ACK：9 个 SCL 脉冲、数据 MSB first 逐位正确、
//      从机 ACK 在 ACK 槽被主机采到、error_code=0
//   5) 写字节 + 从机 NACK：主机自动补发 STOP（SDA 在 SCL 高电平期间上升）、
//      error_code=1、事务结束（再次写字节得到协议错误 3）
//   6) 重复 START：字节 ACK 后 SDA 在 SCL 高电平期间再次下落、error_code=0
//   7) 读字节：数据 MSB first 采样正确；nack_after=1 时主机在 ACK 槽发 NACK
//      （SDA 保持高）；nack_after=0 时主机 ACK（SDA 被拉低）
//   8) STOP：STOP 条件（SDA 上升发生于 SCL 高电平期间）+ 总线释放
//   9) timeout：看门狗周期数小于一个字节所需周期时中止 -> error_code=2、
//      总线释放、cmd_ready 恢复
//   10) 事务中被复位：总线立即释放、事务态清空
//   全程监视：驱动侧只允许 0/Z（拉低时线必须为 0，绝不驱动逻辑 1）
//
// 从机模型：协议级（不算电路）。WRITE 时在 ACK 槽拉低/不拉低 SDA；
// READ 时在 SCL 低电平期间给出下一数据位，ACK 槽释放。ISim 的 pullup
// 只模拟逻辑上拉，不是 4.7 kΩ + 总线电容的上升沿模型（文档已写明）。
//
// 诊断文本全部 ASCII（Win7 构建机 ISim 日志为 GBK 代码页）。
// 判定行：TB_I2C_MASTER: PASS / TB_I2C_MASTER: FAIL
//=============================================================================

`timescale 1ns/1ps

module tb_i2c_master;

    //-------------------------------------------------------------------------
    // DUT 时序参数（clk 周期数，取小值缩短仿真）。
    // 一个位周期 = LOW+HIGH = 8 拍；一个字节命令 = 9 位 = 72+ 拍。
    //-------------------------------------------------------------------------
    localparam integer LOW_CYC  = 4;
    localparam integer HIGH_CYC = 4;
    localparam integer HD_CYC   = 2;
    localparam integer SU_CYC   = 2;
    localparam integer BUF_CYC  = 3;
    localparam integer TO_MAIN  = 20000;   // 主实例：必须远大于任何命令，不得触发
    localparam integer TO_TINY  = 60;      // 超时实例：小于一个字节 -> 必然触发

    // 命令编码（与 RTL 一致）
    localparam [2:0] CMD_START   = 3'd0;
    localparam [2:0] CMD_RESTART = 3'd1;
    localparam [2:0] CMD_WRITE   = 3'd2;
    localparam [2:0] CMD_READ    = 3'd3;
    localparam [2:0] CMD_STOP    = 3'd4;

    reg clk;
    reg rst_n;

    //-------------------------------------------------------------------------
    // 实例 1：协议测试（带从机模型）
    //-------------------------------------------------------------------------
    reg  [2:0] cmd;
    reg  [7:0] wr_data;
    reg        nack_after;
    reg        cmd_valid;
    wire       cmd_ready;
    wire [7:0] rd_data;
    wire       err;
    wire [1:0] err_code;
    wire       scl;
    wire       sda;

    //-------------------------------------------------------------------------
    // 实例 2：timeout 测试（独立总线，无从机）
    //-------------------------------------------------------------------------
    reg  [2:0] cmd2;
    reg  [7:0] wr_data2;
    reg        nack_after2;
    reg        cmd_valid2;
    wire       cmd_ready2;
    wire [7:0] rd_data2;
    wire       err2;
    wire [1:0] err_code2;
    wire       scl2;
    wire       sda2;

    integer checks;
    integer errors;
    integer od_errors;      // 开漏违规计数
    integer err_pulses;     // 实例 1 error 脉冲计数
    integer err2_pulses;    // 实例 2 error 脉冲计数

    pullup pu_scl1 (scl);
    pullup pu_sda1 (sda);
    pullup pu_scl2 (scl2);
    pullup pu_sda2 (sda2);

    i2c_master #(
        .SYS_CLK_HZ        (12000000),
        .SCL_LOW_CYCLES    (LOW_CYC),
        .SCL_HIGH_CYCLES   (HIGH_CYC),
        .T_HDSTA_CYCLES    (HD_CYC),
        .T_SUSTA_CYCLES    (SU_CYC),
        .T_SUSTO_CYCLES    (SU_CYC),
        .T_BUF_CYCLES      (BUF_CYC),
        .TIMEOUT_CYCLES    (TO_MAIN)
    ) dut (
        .clk        (clk),
        .rst_n_sync (rst_n),
        .cmd        (cmd),
        .cmd_valid  (cmd_valid),
        .wr_data    (wr_data),
        .nack_after (nack_after),
        .cmd_ready  (cmd_ready),
        .rd_data    (rd_data),
        .error      (err),
        .error_code (err_code),
        .scl        (scl),
        .sda        (sda)
    );

    i2c_master #(
        .SYS_CLK_HZ        (12000000),
        .SCL_LOW_CYCLES    (LOW_CYC),
        .SCL_HIGH_CYCLES   (HIGH_CYC),
        .T_HDSTA_CYCLES    (HD_CYC),
        .T_SUSTA_CYCLES    (SU_CYC),
        .T_SUSTO_CYCLES    (SU_CYC),
        .T_BUF_CYCLES      (BUF_CYC),
        .TIMEOUT_CYCLES    (TO_TINY)
    ) dut_to (
        .clk        (clk),
        .rst_n_sync (rst_n),
        .cmd        (cmd2),
        .cmd_valid  (cmd_valid2),
        .wr_data    (wr_data2),
        .nack_after (nack_after2),
        .cmd_ready  (cmd_ready2),
        .rd_data    (rd_data2),
        .error      (err2),
        .error_code (err_code2),
        .scl        (scl2),
        .sda        (sda2)
    );

    //-------------------------------------------------------------------------
    // 边界矩阵测试实例：覆盖 2 的幂次相邻值与位宽边界
    //-------------------------------------------------------------------------
    reg  [2:0] bm_cmd;
    reg        bm_valid;
    reg  [7:0] bm_wr_data;

    wire bm_scl_7,  bm_sda_7,  bm_ready_7;  wire [1:0] bm_ec_7;
    wire bm_scl_8,  bm_sda_8,  bm_ready_8;  wire [1:0] bm_ec_8;
    wire bm_scl_15, bm_sda_15, bm_ready_15; wire [1:0] bm_ec_15;
    wire bm_scl_16, bm_sda_16, bm_ready_16; wire [1:0] bm_ec_16;
    wire bm_scl_31, bm_sda_31, bm_ready_31; wire [1:0] bm_ec_31;
    wire bm_scl_32, bm_sda_32, bm_ready_32; wire [1:0] bm_ec_32;

    pullup pu_bm_scl7 (bm_scl_7);   pullup pu_bm_sda7 (bm_sda_7);
    pullup pu_bm_scl8 (bm_scl_8);   pullup pu_bm_sda8 (bm_sda_8);
    pullup pu_bm_scl15(bm_scl_15);  pullup pu_bm_sda15(bm_sda_15);
    pullup pu_bm_scl16(bm_scl_16);  pullup pu_bm_sda16(bm_sda_16);
    pullup pu_bm_scl31(bm_scl_31);  pullup pu_bm_sda31(bm_sda_31);
    pullup pu_bm_scl32(bm_scl_32);  pullup pu_bm_sda32(bm_sda_32);

    i2c_master #(.SCL_LOW_CYCLES(7),  .SCL_HIGH_CYCLES(7),  .TIMEOUT_CYCLES(255))  u_bm_7  (.clk(clk), .rst_n_sync(rst_n), .cmd(bm_cmd), .cmd_valid(bm_valid), .wr_data(bm_wr_data), .nack_after(1'b0), .cmd_ready(bm_ready_7),  .rd_data(), .error(), .error_code(bm_ec_7),  .scl(bm_scl_7),  .sda(bm_sda_7));
    i2c_master #(.SCL_LOW_CYCLES(8),  .SCL_HIGH_CYCLES(8),  .TIMEOUT_CYCLES(256))  u_bm_8  (.clk(clk), .rst_n_sync(rst_n), .cmd(bm_cmd), .cmd_valid(bm_valid), .wr_data(bm_wr_data), .nack_after(1'b0), .cmd_ready(bm_ready_8),  .rd_data(), .error(), .error_code(bm_ec_8),  .scl(bm_scl_8),  .sda(bm_sda_8));
    i2c_master #(.SCL_LOW_CYCLES(15), .SCL_HIGH_CYCLES(15), .TIMEOUT_CYCLES(511)) u_bm_15 (.clk(clk), .rst_n_sync(rst_n), .cmd(bm_cmd), .cmd_valid(bm_valid), .wr_data(bm_wr_data), .nack_after(1'b0), .cmd_ready(bm_ready_15), .rd_data(), .error(), .error_code(bm_ec_15), .scl(bm_scl_15), .sda(bm_sda_15));
    i2c_master #(.SCL_LOW_CYCLES(16), .SCL_HIGH_CYCLES(16), .TIMEOUT_CYCLES(512)) u_bm_16 (.clk(clk), .rst_n_sync(rst_n), .cmd(bm_cmd), .cmd_valid(bm_valid), .wr_data(bm_wr_data), .nack_after(1'b0), .cmd_ready(bm_ready_16), .rd_data(), .error(), .error_code(bm_ec_16), .scl(bm_scl_16), .sda(bm_sda_16));
    i2c_master #(.SCL_LOW_CYCLES(31), .SCL_HIGH_CYCLES(31), .TIMEOUT_CYCLES(1023)) u_bm_31 (.clk(clk), .rst_n_sync(rst_n), .cmd(bm_cmd), .cmd_valid(bm_valid), .wr_data(bm_wr_data), .nack_after(1'b0), .cmd_ready(bm_ready_31), .rd_data(), .error(), .error_code(bm_ec_31), .scl(bm_scl_31), .sda(bm_sda_31));
    i2c_master #(.SCL_LOW_CYCLES(32), .SCL_HIGH_CYCLES(32), .TIMEOUT_CYCLES(1024)) u_bm_32 (.clk(clk), .rst_n_sync(rst_n), .cmd(bm_cmd), .cmd_valid(bm_valid), .wr_data(bm_wr_data), .nack_after(1'b0), .cmd_ready(bm_ready_32), .rd_data(), .error(), .error_code(bm_ec_32), .scl(bm_scl_32), .sda(bm_sda_32));

    // 仿真时钟：10 ns 周期
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // 从机模型（协议级）：SCL 边沿检测 + ACK/数据位驱动
    //-------------------------------------------------------------------------
    reg  tb_sda_low;            // 1 = 从机拉低 SDA
    assign sda = tb_sda_low ? 1'b0 : 1'bz;

    reg        mode_write;      // 正在收主机写的字节
    reg        mode_read;       // 正在给主机送读字节
    reg        slave_ack_en;    // WRITE 的 ACK 槽是否 ACK
    reg  [7:0] slave_tx_byte;   // READ 时从机给出的字节
    reg  [7:0] slave_rx;        // 从机收到的字节（移位）
    reg        slave_rx_en;     // 是否移位采样
    integer    scl_rises;       // 当前字节命令内的 SCL 上升沿计数（1..9）

    reg  scl_q;
    always @(posedge clk) scl_q <= scl;
    wire scl_rise = (scl === 1'b1) && (scl_q !== 1'b1);
    wire scl_fall = (scl !== 1'b1) && (scl_q === 1'b1);

    always @(posedge clk) begin
        if (scl_rise) begin
            scl_rises = scl_rises + 1;
            if (mode_write && slave_rx_en && (scl_rises <= 8)) begin
                slave_rx <= {slave_rx[6:0], sda};       // MSB first 采样
            end
            if (slave_ack_en && (scl_rises == 9)) begin
                tb_sda_low <= 1'b1;                     // ACK 槽拉低
            end
        end
        if (scl_fall) begin
            if (mode_read && (scl_rises < 8)) begin
                // 下一个上升沿是第 scl_rises+1 个数据位（1..8），提前给出
                tb_sda_low <= ~slave_tx_byte[7 - scl_rises];
            end else begin
                tb_sda_low <= 1'b0;                     // 其余情况一律释放
            end
        end
    end

    //-------------------------------------------------------------------------
    // 第 9 个时钟（ACK 槽）的线电平采样：用于检查 ACK/NACK 行为。
    // 用延迟一拍的上升沿（scl_rise_d）触发，此时 scl_rises 已在上一个沿被
    // 从机模型稳定更新，避免同一时钟沿两个进程读写竞态。
    //-------------------------------------------------------------------------
    reg  scl_q2;
    always @(posedge clk) scl_q2 <= scl_q;
    wire scl_rise_d = (scl_q === 1'b1) && (scl_q2 !== 1'b1);

    reg ack9_sample;
    reg ack9_valid;
    reg ack9_sda;
    always @(posedge clk) begin
        // ack9_valid 粘滞：置位后保持，由 stimulus 在每字节前阻塞赋值清零
        if (scl_rise_d && (scl_rises == 9) && (mode_write || mode_read)) begin
            ack9_sample <= 1'b1;
        end
        if (ack9_sample) begin
            ack9_sda    <= sda;
            ack9_valid  <= 1'b1;
            ack9_sample <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // 全程开漏监视：主机声明拉低时线必须为 0（间接保证绝不驱动逻辑 1）
    //-------------------------------------------------------------------------
    wire m_scl_d = dut.scl_drive_low;
    wire m_sda_d = dut.sda_drive_low;
    always @(negedge clk) begin
        if (m_scl_d === 1'b1 && scl !== 1'b0) begin
            od_errors = od_errors + 1;
            $display("FAIL: open-drain violation: SCL drive-low asserted but line is not 0");
        end
        if (m_sda_d === 1'b1 && sda !== 1'b0) begin
            od_errors = od_errors + 1;
            $display("FAIL: open-drain violation: SDA drive-low asserted but line is not 0");
        end
    end

    // error 脉冲计数（实例 1 / 实例 2）
    always @(posedge clk) begin
        if (err  === 1'b1) err_pulses  = err_pulses  + 1;
        if (err2 === 1'b1) err2_pulses = err2_pulses + 1;
    end

    //-------------------------------------------------------------------------
    // 命令发射任务（实例 1 / 实例 2）
    //-------------------------------------------------------------------------
    task do_cmd;
        input  [2:0] c_cmd;
        input  [7:0] c_data;
        input        c_nlast;
        output [1:0] c_ecode;
        output [7:0] c_rdata;
        begin
            @(negedge clk);
            cmd        = c_cmd;
            wr_data    = c_data;
            nack_after = c_nlast;
            cmd_valid  = 1'b1;
            @(negedge clk);
            cmd_valid  = 1'b0;
            @(negedge clk);
            while (cmd_ready !== 1'b1) @(negedge clk);
            c_ecode = err_code;
            c_rdata = rd_data;
            @(negedge clk);
        end
    endtask

    task do_cmd2;
        input  [2:0] c_cmd;
        input  [7:0] c_data;
        input        c_nlast;
        output [1:0] c_ecode;
        output [7:0] c_rdata;
        begin
            @(negedge clk);
            cmd2        = c_cmd;
            wr_data2    = c_data;
            nack_after2 = c_nlast;
            cmd_valid2  = 1'b1;
            @(negedge clk);
            cmd_valid2  = 1'b0;
            @(negedge clk);
            while (cmd_ready2 !== 1'b1) @(negedge clk);
            c_ecode = err_code2;
            c_rdata = rd_data2;
            @(negedge clk);
        end
    endtask

    //-------------------------------------------------------------------------
    // 检查任务
    //-------------------------------------------------------------------------
    task check_eq;
        input integer    got;
        input integer    exp;
        input [8*72-1:0] label;
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
    // START/RESTART 条件观测：SDA 在 SCL 高电平期间下落。
    // SCL 低电平期间的数据位跳变是合法的，只忽略、不报错。
    //-------------------------------------------------------------------------
    task expect_start;
        input integer max_cycles;
        integer c;
        reg     prev_sda;
        reg     found;
        begin
            c       = 0;
            found   = 0;
            prev_sda= sda;
            while ((!found) && (c < max_cycles)) begin
                @(posedge clk);
                #1;
                c = c + 1;
                if ((prev_sda === 1'b1) && (sda === 1'b0) && (scl === 1'b1)) found = 1;
                prev_sda = sda;
            end
            checks = checks + 1;
            if (!found) begin
                errors = errors + 1;
                $display("FAIL: START condition not observed within %0d cycles", max_cycles);
            end else begin
                $display("  ok: START/RESTART condition observed (SDA fall while SCL high)");
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // STOP 条件观测：SDA 在 SCL 高电平期间上升。
    // SCL 低电平期间的数据位跳变是合法的，只忽略、不报错。
    //-------------------------------------------------------------------------
    task expect_stop;
        input integer max_cycles;
        integer c;
        reg     prev_sda;
        reg     found;
        begin
            c       = 0;
            found   = 0;
            prev_sda= sda;
            while ((!found) && (c < max_cycles)) begin
                @(posedge clk);
                #1;
                c = c + 1;
                if ((prev_sda === 1'b0) && (sda === 1'b1) && (scl === 1'b1)) found = 1;
                prev_sda = sda;
            end
            checks = checks + 1;
            if (!found) begin
                errors = errors + 1;
                $display("FAIL: STOP condition not observed within %0d cycles", max_cycles);
            end else begin
                $display("  ok: STOP condition observed (SDA rise while SCL high)");
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    reg [1:0] ec;
    reg [7:0] rd;
    reg [1:0] ec2;
    reg [7:0] rd2;
    integer   bm_wcnt;

    initial begin
        checks       = 0;
        errors       = 0;
        od_errors    = 0;
        err_pulses   = 0;
        err2_pulses  = 0;
        scl_rises    = 0;
        mode_write   = 1'b0;
        mode_read    = 1'b0;
        slave_ack_en = 1'b0;
        slave_rx_en  = 1'b0;
        slave_tx_byte= 8'h00;
        slave_rx     = 8'h00;
        tb_sda_low   = 1'b0;
        ack9_sample  = 1'b0;
        ack9_valid   = 1'b0;
        ack9_sda     = 1'b0;
        cmd          = 3'd0;
        wr_data      = 8'h00;
        nack_after   = 1'b0;
        cmd_valid    = 1'b0;
        cmd2         = 3'd0;
        wr_data2     = 8'h00;
        nack_after2  = 1'b0;
        bm_cmd       = 3'd0;
        bm_valid     = 1'b0;
        bm_wr_data   = 8'h00;
        cmd_valid2   = 1'b0;
        clk          = 1'b0;
        rst_n        = 1'b0;

        $display("TB_I2C_MASTER: start");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        //---------------------------------------------------------------------
        // T1: 复位后状态（有 pullup，释放的总线读作高电平而非 Z）
        //---------------------------------------------------------------------
        $display("T1: reset state");
        check_true((scl === 1'b1) && (sda === 1'b1),
                   "T1 bus lines pulled high (released) after reset");
        check_true((dut.scl_drive_low === 1'b0) && (dut.sda_drive_low === 1'b0),
                   "T1 DUT drives neither line after reset");
        check_true(cmd_ready === 1'b1,               "T1 cmd_ready=1 after reset");
        check_true(dut.xact   === 1'b0,              "T1 transaction flag clear after reset");

        //---------------------------------------------------------------------
        // T2: 无事务时的协议错误（不得有总线活动）
        //---------------------------------------------------------------------
        $display("T2: protocol errors without transaction");
        do_cmd(CMD_WRITE,   8'hA0, 1'b0, ec, rd);
        check_eq(ec, 2'd3, "T2 WRITE without START -> error_code=3");
        do_cmd(CMD_READ,    8'h00, 1'b1, ec, rd);
        check_eq(ec, 2'd3, "T2 READ without START -> error_code=3");
        do_cmd(CMD_STOP,    8'h00, 1'b0, ec, rd);
        check_eq(ec, 2'd3, "T2 STOP without START -> error_code=3");
        do_cmd(CMD_RESTART, 8'h00, 1'b0, ec, rd);
        check_eq(ec, 2'd3, "T2 RESTART without START -> error_code=3");
        check_eq(err_pulses, 4, "T2 four error pulses observed");
        check_true((scl === 1'b1) && (sda === 1'b1), "T2 bus untouched by protocol errors");

        //---------------------------------------------------------------------
        // T3: START 条件 + 事务中重复 START 被拒绝
        //---------------------------------------------------------------------
        $display("T3: START condition");
        fork
            do_cmd(CMD_START, 8'h00, 1'b0, ec, rd);
            expect_start(600);
        join
        check_eq(ec, 2'd0, "T3 START command no error");
        check_true(scl === 1'b0, "T3 SCL held low after START");
        check_true(sda === 1'b1, "T3 SDA released after START");
        do_cmd(CMD_START, 8'h00, 1'b0, ec, rd);
        check_eq(ec, 2'd3, "T3 second START inside transaction -> error_code=3");
        check_eq(err_pulses, 5, "T3 error pulse count now 5");

        //---------------------------------------------------------------------
        // T4: 写字节 + 从机 ACK
        //---------------------------------------------------------------------
        $display("T4: write byte with slave ACK");
        scl_rises   = 0;
        mode_write  = 1'b1;
        slave_ack_en= 1'b1;
        slave_rx_en = 1'b1;
        slave_rx    = 8'h00;
        ack9_valid  = 1'b0;
        do_cmd(CMD_WRITE, 8'h48, 1'b0, ec, rd);
        mode_write  = 1'b0;
        slave_rx_en = 1'b0;
        slave_ack_en= 1'b0;
        check_eq(ec, 2'd0,          "T4 write byte error_code=0");
        check_eq(slave_rx, 8'h48,   "T4 slave received 0x48 MSB first");
        check_eq(scl_rises, 9,      "T4 exactly 9 SCL pulses for one byte");
        check_true((ack9_valid === 1'b1) && (ack9_sda === 1'b0),
                   "T4 slave ACK seen low in ACK slot");
        check_eq(err_pulses, 5,     "T4 no extra error pulse");

        //---------------------------------------------------------------------
        // T5: 写字节 + 从机 NACK -> 自动补发 STOP + error_code=1
        //---------------------------------------------------------------------
        $display("T5: write byte with slave NACK");
        scl_rises   = 0;
        mode_write  = 1'b1;
        slave_ack_en= 1'b0;
        slave_rx_en = 1'b1;
        slave_rx    = 8'h00;
        ack9_valid  = 1'b0;
        fork
            do_cmd(CMD_WRITE, 8'hD0, 1'b0, ec, rd);
            expect_stop(600);
        join
        mode_write  = 1'b0;
        slave_rx_en = 1'b0;
        check_eq(ec, 2'd1,          "T5 NACK -> error_code=1");
        check_eq(slave_rx, 8'hD0,   "T5 slave still received 0xD0 before NACK");
        // 9 个字节脉冲 + NACK 自动补发 STOP 时 SCL 拉高 1 次 = 10
        check_eq(scl_rises, 10,     "T5 9 byte pulses + 1 STOP SCL pulse");
        check_true((ack9_valid === 1'b1) && (ack9_sda === 1'b1),
                   "T5 ACK slot stayed high (NACK)");
        check_true(dut.xact === 1'b0, "T5 transaction aborted after NACK");
        do_cmd(CMD_WRITE, 8'h00, 1'b0, ec, rd);
        check_eq(ec, 2'd3, "T5 WRITE after NACK abort -> error_code=3");

        //---------------------------------------------------------------------
        // T6: 新 START + 写字节（ACK）+ 重复 START
        //---------------------------------------------------------------------
        $display("T6: repeated START");
        do_cmd(CMD_START, 8'h00, 1'b0, ec, rd);
        check_eq(ec, 2'd0, "T6 second transaction START ok");
        scl_rises   = 0;
        mode_write  = 1'b1;
        slave_ack_en= 1'b1;
        slave_rx_en = 1'b0;
        do_cmd(CMD_WRITE, 8'h90, 1'b0, ec, rd);
        mode_write  = 1'b0;
        slave_ack_en= 1'b0;
        check_eq(ec, 2'd0, "T6 write byte ACKed");
        fork
            do_cmd(CMD_RESTART, 8'h00, 1'b0, ec, rd);
            expect_start(600);
        join
        check_eq(ec, 2'd0, "T6 RESTART command no error");

        //---------------------------------------------------------------------
        // T7: 读字节（0xA5），nack_after=1 -> 主机 NACK
        // RESTART 完成后 SCL 保持低、主机已释放 SDA，从机此刻给出 bit7；
        // scl_rises 在此重新清零（只统计本读字节的 9 个脉冲）。
        //---------------------------------------------------------------------
        $display("T7: read byte, master NACK on last byte");
        mode_read    = 1'b1;
        slave_tx_byte= 8'hA5;
        scl_rises    = 0;
        ack9_valid   = 1'b0;
        tb_sda_low   = ~slave_tx_byte[7];   // SCL 低电平期间先给出 bit7
        do_cmd(CMD_READ, 8'h00, 1'b1, ec, rd);
        mode_read = 1'b0;
        check_eq(ec, 2'd0,        "T7 read byte error_code=0 (master NACK is not an error)");
        check_eq(rd, 8'hA5,       "T7 read data = 0xA5 MSB first");
        check_true((ack9_valid === 1'b1) && (ack9_sda === 1'b1),
                   "T7 master released SDA in ACK slot (master NACK)");
        check_eq(scl_rises, 9,    "T7 9 SCL pulses for the read byte");
        check_true(dut.xact === 1'b1, "T7 transaction still active after master NACK");

        //---------------------------------------------------------------------
        // T8: 继续读一个字节，nack_after=0 -> 主机 ACK
        //---------------------------------------------------------------------
        $display("T8: read byte, master ACK (not last byte)");
        mode_read    = 1'b1;
        slave_tx_byte= 8'h3C;
        scl_rises    = 0;
        ack9_valid   = 1'b0;
        tb_sda_low   = ~slave_tx_byte[7];
        do_cmd(CMD_READ, 8'h00, 1'b0, ec, rd);
        mode_read = 1'b0;
        check_eq(ec, 2'd0,        "T8 read byte error_code=0");
        check_eq(rd, 8'h3C,       "T8 read data = 0x3C");
        check_true((ack9_valid === 1'b1) && (ack9_sda === 1'b0),
                   "T8 master drove SDA low in ACK slot (master ACK)");

        //---------------------------------------------------------------------
        // T9: STOP + 总线释放
        //---------------------------------------------------------------------
        $display("T9: STOP and bus release");
        scl_rises = 0;
        ack9_valid= 1'b0;
        fork
            do_cmd(CMD_STOP, 8'h00, 1'b0, ec, rd);
            expect_stop(600);
        join
        check_eq(ec, 2'd0,            "T9 STOP command no error");
        check_true(dut.xact === 1'b0, "T9 transaction closed by STOP");
        // 累计脉冲：T2 协议错误 4 + T3 双 START 1 + T5 NACK 1 + T5 探针 1 = 7
        check_eq(err_pulses, 7,       "T9 no extra error pulse after normal transaction");
        // STOP 后等 t_BUF 完成（命令返回时已结束），总线应释放
        check_true((scl === 1'b1) && (sda === 1'b1), "T9 bus released after STOP");
        check_true((dut.scl_drive_low === 1'b0) && (dut.sda_drive_low === 1'b0),
                   "T9 DUT drives neither line after STOP");

        //---------------------------------------------------------------------
        // T10: timeout（实例 2，看门狗小于一个字节）。
        // WRITE 需要活动事务，所以先 START（其耗时远小于看门狗）。
        //---------------------------------------------------------------------
        $display("T10: timeout watchdog aborts long command");
        do_cmd2(CMD_START, 8'h00, 1'b0, ec2, rd2);
        check_eq(ec2, 2'd0, "T10 bus-2 START ok");
        do_cmd2(CMD_WRITE, 8'h5A, 1'b0, ec2, rd2);
        check_eq(ec2, 2'd2,             "T10 timeout -> error_code=2");
        check_true(err2_pulses >= 1,    "T10 timeout error pulse observed");
        check_true((scl2 === 1'b1) && (sda2 === 1'b1),
                   "T10 bus-2 lines released after timeout");
        check_true((dut_to.scl_drive_low === 1'b0) && (dut_to.sda_drive_low === 1'b0),
                   "T10 DUT-2 drives neither line after timeout");
        check_true(dut_to.xact === 1'b0, "T10 timeout cleared transaction state");

        //---------------------------------------------------------------------
        // T11: 事务中复位 -> 总线立即释放、事务态清空
        //---------------------------------------------------------------------
        $display("T11: reset in the middle of a transaction");
        do_cmd(CMD_START, 8'h00, 1'b0, ec, rd);
        check_eq(ec, 2'd0, "T11 START ok");
        @(negedge clk);
        cmd       = CMD_WRITE;
        wr_data   = 8'h77;
        nack_after= 1'b0;
        cmd_valid = 1'b1;
        @(negedge clk);
        cmd_valid = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        check_true((scl === 1'b1) && (sda === 1'b1), "T11 bus released by reset");
        check_true((dut.scl_drive_low === 1'b0) && (dut.sda_drive_low === 1'b0),
                   "T11 DUT drives neither line after reset");
        check_true(cmd_ready === 1'b1,               "T11 cmd_ready=1 after reset");
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        do_cmd(CMD_WRITE, 8'h00, 1'b0, ec, rd);
        check_eq(ec, 2'd3, "T11 WRITE after reset -> error_code=3 (transaction state cleared)");
        check_true((scl === 1'b1) && (sda === 1'b1),
                   "T11 bus still released after aborted command");

        //---------------------------------------------------------------------
        // T12: 边界矩阵测试（7, 8, 15, 16, 31, 32 时钟周期参数）
        // 验证 2 的幂次相邻值与位宽边界参数下的 I2C 控制器行为
        //---------------------------------------------------------------------
        $display("--- T12: Boundary matrix instances check ---");
        check_true(bm_ready_7  === 1'b1, "T12 bm_7 ready");
        check_true(bm_ready_8  === 1'b1, "T12 bm_8 ready");
        check_true(bm_ready_15 === 1'b1, "T12 bm_15 ready");
        check_true(bm_ready_16 === 1'b1, "T12 bm_16 ready");
        check_true(bm_ready_31 === 1'b1, "T12 bm_31 ready");
        check_true(bm_ready_32 === 1'b1, "T12 bm_32 ready");

        // 步骤 1: 正常 START -> STOP 流程
        @(negedge clk);
        bm_cmd   = CMD_START;
        bm_valid = 1'b1;
        @(negedge clk);
        bm_valid = 1'b0;
        @(negedge clk);

        bm_wcnt = 0;
        while (!(bm_ready_7 && bm_ready_8 && bm_ready_15 && bm_ready_16 && bm_ready_31 && bm_ready_32) && bm_wcnt < 5000) begin
            @(negedge clk);
            bm_wcnt = bm_wcnt + 1;
        end
        check_true(bm_wcnt < 5000, "T12 START completed within timeout");
        check_eq(bm_ec_7,  2'd0, "T12 bm_7 START error_code=0");
        check_eq(bm_ec_8,  2'd0, "T12 bm_8 START error_code=0");
        check_eq(bm_ec_15, 2'd0, "T12 bm_15 START error_code=0");
        check_eq(bm_ec_16, 2'd0, "T12 bm_16 START error_code=0");
        check_eq(bm_ec_31, 2'd0, "T12 bm_31 START error_code=0");
        check_eq(bm_ec_32, 2'd0, "T12 bm_32 START error_code=0");

        @(negedge clk);
        bm_cmd   = CMD_STOP;
        bm_valid = 1'b1;
        @(negedge clk);
        bm_valid = 1'b0;
        @(negedge clk);

        bm_wcnt = 0;
        while (!(bm_ready_7 && bm_ready_8 && bm_ready_15 && bm_ready_16 && bm_ready_31 && bm_ready_32) && bm_wcnt < 5000) begin
            @(negedge clk);
            bm_wcnt = bm_wcnt + 1;
        end
        check_true(bm_wcnt < 5000, "T12 STOP completed within timeout");
        check_eq(bm_ec_7,  2'd0, "T12 bm_7 STOP error_code=0");
        check_eq(bm_ec_8,  2'd0, "T12 bm_8 STOP error_code=0");
        check_eq(bm_ec_15, 2'd0, "T12 bm_15 STOP error_code=0");
        check_eq(bm_ec_16, 2'd0, "T12 bm_16 STOP error_code=0");
        check_eq(bm_ec_31, 2'd0, "T12 bm_31 STOP error_code=0");
        check_eq(bm_ec_32, 2'd0, "T12 bm_32 STOP error_code=0");
        check_true((bm_scl_7 === 1'b1)  && (bm_sda_7 === 1'b1),  "T12 bm_7 bus released after STOP");
        check_true((bm_scl_8 === 1'b1)  && (bm_sda_8 === 1'b1),  "T12 bm_8 bus released after STOP");
        check_true((bm_scl_15 === 1'b1) && (bm_sda_15 === 1'b1), "T12 bm_15 bus released after STOP");
        check_true((bm_scl_16 === 1'b1) && (bm_sda_16 === 1'b1), "T12 bm_16 bus released after STOP");
        check_true((bm_scl_31 === 1'b1) && (bm_sda_31 === 1'b1), "T12 bm_31 bus released after STOP");
        check_true((bm_scl_32 === 1'b1) && (bm_sda_32 === 1'b1), "T12 bm_32 bus released after STOP");

        // 步骤 2: START -> WRITE (无从机拉低产生 NACK) -> 自动补发 STOP 与释放总线
        @(negedge clk);
        bm_cmd   = CMD_START;
        bm_valid = 1'b1;
        @(negedge clk);
        bm_valid = 1'b0;
        @(negedge clk);

        bm_wcnt = 0;
        while (!(bm_ready_7 && bm_ready_8 && bm_ready_15 && bm_ready_16 && bm_ready_31 && bm_ready_32) && bm_wcnt < 5000) begin
            @(negedge clk);
            bm_wcnt = bm_wcnt + 1;
        end
        check_true(bm_wcnt < 5000, "T12 START 2 completed within timeout");

        @(negedge clk);
        bm_cmd     = CMD_WRITE;
        bm_wr_data = 8'hA5;
        bm_valid   = 1'b1;
        @(negedge clk);
        bm_valid   = 1'b0;
        @(negedge clk);

        bm_wcnt = 0;
        while (!(bm_ready_7 && bm_ready_8 && bm_ready_15 && bm_ready_16 && bm_ready_31 && bm_ready_32) && bm_wcnt < 10000) begin
            @(negedge clk);
            bm_wcnt = bm_wcnt + 1;
        end
        check_true(bm_wcnt < 10000, "T12 WRITE NACK completed within timeout");
        check_eq(bm_ec_7,  2'd1, "T12 bm_7 WRITE NACK error_code=1");
        check_eq(bm_ec_8,  2'd1, "T12 bm_8 WRITE NACK error_code=1");
        check_eq(bm_ec_15, 2'd1, "T12 bm_15 WRITE NACK error_code=1");
        check_eq(bm_ec_16, 2'd1, "T12 bm_16 WRITE NACK error_code=1");
        check_eq(bm_ec_31, 2'd1, "T12 bm_31 WRITE NACK error_code=1");
        check_eq(bm_ec_32, 2'd1, "T12 bm_32 WRITE NACK error_code=1");

        // 验证 NACK 自动补发 STOP 后总线被彻底释放（上拉为高）
        check_true((bm_scl_7 === 1'b1)  && (bm_sda_7 === 1'b1),  "T12 bm_7 bus released after NACK auto-stop");
        check_true((bm_scl_8 === 1'b1)  && (bm_sda_8 === 1'b1),  "T12 bm_8 bus released after NACK auto-stop");
        check_true((bm_scl_15 === 1'b1) && (bm_sda_15 === 1'b1), "T12 bm_15 bus released after NACK auto-stop");
        check_true((bm_scl_16 === 1'b1) && (bm_sda_16 === 1'b1), "T12 bm_16 bus released after NACK auto-stop");
        check_true((bm_scl_31 === 1'b1) && (bm_sda_31 === 1'b1), "T12 bm_31 bus released after NACK auto-stop");
        check_true((bm_scl_32 === 1'b1) && (bm_sda_32 === 1'b1), "T12 bm_32 bus released after NACK auto-stop");

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (od_errors != 0) begin
            errors = errors + od_errors;
        end

        if (errors == 0) begin
            $display("TB_I2C_MASTER: PASS (checks=%0d, errors=0, od_violations=0, sim_time=%0t)",
                     checks, $time);
        end else begin
            $display("TB_I2C_MASTER: FAIL (checks=%0d, errors=%0d, od_violations=%0d, sim_time=%0t)",
                     checks, errors, od_errors, $time);
        end

        $finish;
    end

endmodule
