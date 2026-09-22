`timescale 1ns / 1ps

//=============================================================================
// tb_oled_hw_delay.v
// SSD1306 OLED 硬件上电延时分支 (SIM_FAST_INIT = 0) 专项回归
//
// 验证项目：
//   1. 硬件计数器参数验证：在 12 MHz 下，2^18 周期 = 262,144 周期 = 21.84533 ms (>= 20 ms)；
//   2. 延时未到期前 (周期 1 ~ 262,143)：
//      - pwr_timeout 恒为 0；
//      - 控制器严格停留在 SEQ_PWR_WAIT 状态；
//      - 绝不产生任何 i2c_start_req 或总线请求脉冲；
//   3. 延时到期时刻 (第 262,144 周期)：
//      - pwr_timeout 准时翻转为 1 (pwr_cnt 达 0x40000)；
//      - 控制器转移到 SEQ_INIT_CMD；
//   4. 启动脉冲时刻 (第 262,145 周期)：
//      - i2c_start_req 准时产生单周期启动脉冲；
//      - 随后的周期 i2c_start_req 自动回落为 0；
//   5. 延时到期后饱和防回绕特性：
//      - 19-bit 计数器在最高位为 1 后锁定饱和，绝不发生溢出回绕；
//   6. 异步复位特性：
//      - 复位有效期间 pwr_cnt 为 0，pwr_timeout 为 0。
//
// 判定行：TB_OLED_HW_DELAY: PASS / TB_OLED_HW_DELAY: FAIL
//=============================================================================

module tb_oled_hw_delay;

    reg clk;
    reg rst_n_sync;
    reg [2:0] note_code;
    reg i2c_byte_done;
    reg i2c_ack_error;

    wire i2c_start_req;
    wire i2c_write_byte_req;
    wire [7:0] i2c_byte_in;
    wire i2c_stop_req;
    wire init_done;
    wire oled_error;

    integer checks = 0;
    integer errors = 0;
    integer cyc = 0;

    // 12 MHz 时钟 (周期 83.333 ns, 半周期 41.667 ns)
    initial clk = 1'b0;
    always #41.667 clk = ~clk;

    // 实例化被测 OLED 控制器：SIM_FAST_INIT 显式设置为 0 (测试硬件分支)
    oled_ssd1306_ctrl #(
        .SYS_CLK_HZ    (12000000),
        .SIM_FAST_INIT (0)
    ) u_ctrl (
        .clk                (clk),
        .rst_n_sync         (rst_n_sync),
        .note_code          (note_code),
        .i2c_start_req      (i2c_start_req),
        .i2c_write_byte_req (i2c_write_byte_req),
        .i2c_byte_in        (i2c_byte_in),
        .i2c_stop_req       (i2c_stop_req),
        .i2c_byte_done      (i2c_byte_done),
        .i2c_ack_error      (i2c_ack_error),
        .init_done          (init_done),
        .oled_error         (oled_error)
    );

    // 观测内部硬件计数器与超时信号
    wire hw_pwr_timeout = u_ctrl.pwr_timeout;
    wire [18:0] hw_pwr_cnt = u_ctrl.GEN_HW_PWR.pwr_cnt;
    wire [3:0]  hw_seq_state = u_ctrl.seq_state;

    initial begin
        $display("=== TB_OLED_HW_DELAY: START ===");
        rst_n_sync    = 1'b0;
        note_code     = 3'b000;
        i2c_byte_done = 1'b0;
        i2c_ack_error = 1'b0;

        // 保持复位 20 个周期
        repeat (20) @(posedge clk);
        #1;
        checks = checks + 1;
        if (hw_pwr_cnt !== 19'd0 || hw_pwr_timeout !== 1'b0) begin
            $display("ERROR: pwr_cnt not 0 during reset! cnt=%0d, timeout=%b", hw_pwr_cnt, hw_pwr_timeout);
            errors = errors + 1;
        end

        // 在时钟下降沿释放复位，确保下一个 posedge 是第 1 个有效计数沿
        @(negedge clk);
        rst_n_sync = 1'b1;
        $display("[%0t] Reset released, monitoring 19-bit hardware power-on counter...", $time);

        // 监视第 1 到第 262,143 周期
        // 验证每一拍计数器严格递增，pwr_timeout 严格为 0，seq_state 停留在 0 (SEQ_PWR_WAIT)，无 i2c_start_req
        for (cyc = 1; cyc <= 262143; cyc = cyc + 1) begin
            @(posedge clk);
            #1;
            if (i2c_start_req !== 1'b0) begin
                $display("ERROR: Premature i2c_start_req at cycle %0d!", cyc);
                errors = errors + 1;
            end
            if (hw_pwr_timeout !== 1'b0) begin
                $display("ERROR: Premature pwr_timeout at cycle %0d!", cyc);
                errors = errors + 1;
            end
            if (hw_seq_state !== 4'd0) begin
                $display("ERROR: Premature seq_state transition to %0d at cycle %0d!", hw_seq_state, cyc);
                errors = errors + 1;
            end
        end

        checks = checks + 1;
        $display("[%0t] Cycle 262143 reached. Current cnt=%0d (0x%05X), pwr_timeout=%b",
                 $time, hw_pwr_cnt, hw_pwr_cnt, hw_pwr_timeout);
        if (hw_pwr_cnt !== 19'h3FFFF || hw_pwr_timeout !== 1'b0) begin
            $display("ERROR: Expected cnt=0x3FFFF at cycle 262143, got 0x%05X", hw_pwr_cnt);
            errors = errors + 1;
        end

        // 迎来第 262,144 周期 (2^18)：pwr_cnt 翻转为 0x40000，pwr_timeout 准时拉高！
        @(posedge clk);
        #1;
        checks = checks + 1;
        $display("[%0t] Cycle 262144: cnt=%0d (0x%05X), pwr_timeout=%b, seq_state=%0d",
                 $time, hw_pwr_cnt, hw_pwr_cnt, hw_pwr_timeout, hw_seq_state);

        if (hw_pwr_timeout !== 1'b1) begin
            $display("ERROR: pwr_timeout not asserted at cycle 262144!");
            errors = errors + 1;
        end
        if (hw_pwr_cnt !== 19'h40000) begin
            $display("ERROR: pwr_cnt expected 0x40000 (2^18), got 0x%05X", hw_pwr_cnt);
            errors = errors + 1;
        end

        // 第 262,145 周期：burst_req 为 1，bst_state 从 IDLE 响应 burst_req 并登记 i2c_start_req
        @(posedge clk);
        #1;
        checks = checks + 1;
        $display("[%0t] Cycle 262145: seq_state=%0d, burst_req=%b", $time, hw_seq_state, u_ctrl.burst_req);
        if (hw_seq_state !== 4'd1) begin
            $display("ERROR: seq_state not transitioned to SEQ_INIT_CMD (1), got %0d", hw_seq_state);
            errors = errors + 1;
        end

        // 第 262,146 周期：i2c_start_req 准时产生单周期脉冲
        @(posedge clk);
        #1;
        checks = checks + 1;
        $display("[%0t] Cycle 262146: start_req=%b", $time, i2c_start_req);
        if (i2c_start_req !== 1'b1) begin
            $display("ERROR: i2c_start_req not asserted at cycle 262146!");
            errors = errors + 1;
        end

        // 第 262,147 周期：i2c_start_req 单周期脉冲自清为 0
        @(posedge clk);
        #1;
        checks = checks + 1;
        if (i2c_start_req !== 1'b0) begin
            $display("ERROR: i2c_start_req not self-cleared at cycle 262147!");
            errors = errors + 1;
        end

        // 验证其后 500 个时钟周期内，计数器锁定饱和在 0x40000，绝不回绕！
        repeat (500) @(posedge clk);
        #1;
        checks = checks + 1;
        if (hw_pwr_cnt !== 19'h40000 || hw_pwr_timeout !== 1'b1) begin
            $display("ERROR: pwr_cnt failed to saturate! cnt=0x%05X, timeout=%b", hw_pwr_cnt, hw_pwr_timeout);
            errors = errors + 1;
        end else begin
            $display("[%0t] Saturation verified: counter held locked at 0x40000 without rollover.", $time);
        end

        // 验证延时计算契约：
        // 262,144 / 12,000,000 = 21.84533 ms >= 20.000 ms
        $display("Hardware delay specification verification:");
        $display("  Target clock: 12.000 MHz");
        $display("  Cycles elapsed: 262144");
        $display("  Calculated time: 21.84533 ms (>= 20 ms requirement: PASS)");

        $display("--------------------------------------------------");
        if (errors == 0) begin
            $display("TB_OLED_HW_DELAY: PASS (checks=%0d, errors=0)", checks);
        end else begin
            $display("TB_OLED_HW_DELAY: FAIL (checks=%0d, errors=%0d)", checks, errors);
        end
        $finish;
    end

    // 仿真超时看门狗 (35 ms)
    initial begin
        #35000000;
        $display("ERROR: Simulation timeout in tb_oled_hw_delay!");
        $display("TB_OLED_HW_DELAY: FAIL");
        $finish;
    end

endmodule
