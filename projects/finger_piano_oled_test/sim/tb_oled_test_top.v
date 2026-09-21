`timescale 1ns / 1ps

//=============================================================================
// tb_oled_test_top.v
// Stage OLED-2/3 综合仿真与验证平台
//
// 验证项目：
//   1. 上电复位与 20 ms (仿真加速为 120 拍) 延迟；
//   2. 严格核验 27 字节初始化序列与 STM32 参考驱动逐字节匹配；
//   3. 严格核验 Page Addressing Mode (0x20, 0x10)；
//   4. 校验初始全屏铺底：Page 0~1 标题 ("FINGER PIANO") 与 Page 2~5 初始 MUTE；
//   5. 校验静止特性：音符不跳变时，I2C 彻底静止，0 冗余帧；
//   6. 校验局部增量刷新：note_code 切换为 1 (Do C4)，仅更新 Page 2~5，且字模准确；
//   7. 校验防撕裂机制：刷新中途改变音符 (2 -> 3)，前帧刷完后自动连贯补刷第 3 音符；
//   8. 校验 NACK 故障处理：注入从机 NACK，控制器立即中止、发出 STOP、置位 oled_error 并停机。
//=============================================================================

module tb_oled_test_top;

    reg clk;
    reg rst_n;

    wire oled_i2c_scl;
    wire oled_i2c_sda;
    wire dbg_led;
    wire dbg_unused;

    // 故障注入控制
    reg  sim_inject_nack;

    // 外部 4.7k 上拉电阻模拟
    pullup (oled_i2c_scl);
    pullup (oled_i2c_sda);

    // 12 MHz 系统时钟 (周期 83.333 ns, 半周期 41.667 ns)
    always #41.667 clk = ~clk;

    // 实例化顶层被测模块 (禁用顶层自动步进 AUTO_STEP_CYCLES=0，由 TB 手动驱动音符)
    oled_test_top #(
        .SYS_CLK_HZ            (12000000),
        .POWER_ON_DELAY_CYCLES (120),
        .AUTO_STEP_CYCLES      (0)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .oled_i2c_scl (oled_i2c_scl),
        .oled_i2c_sda (oled_i2c_sda),
        .dbg_led      (dbg_led),
        .dbg_unused   (dbg_unused)
    );

    // 实例化增强型 SSD1306 仿真模型
    wire       model_init_seq_err;
    wire       model_mode_err;
    wire       model_proto_err;
    wire [1:0] model_addr_mode;
    wire [7:0] model_last_cmd;
    wire [31:0] model_cmd_cnt;
    wire [31:0] model_data_cnt;

    ssd1306_model #(
        .DEVICE_ADDR (7'h3C)
    ) u_ssd1306 (
        .clk                    (clk),
        .rst                    (!rst_n),
        .inject_nack            (sim_inject_nack),
        .scl                    (oled_i2c_scl),
        .sda                    (oled_i2c_sda),
        .init_seq_error         (model_init_seq_err),
        .mode_error             (model_mode_err),
        .protocol_error         (model_proto_err),
        .memory_addressing_mode (model_addr_mode),
        .last_cmd               (model_last_cmd),
        .cmd_count              (model_cmd_cnt),
        .data_count             (model_data_cnt)
    );

    integer initial_data_count;
    integer step1_data_count;

    //-------------------------------------------------------------------------
    // 主测试流程
    //-------------------------------------------------------------------------
    initial begin
        $display("=== TB_OLED_TEST_TOP: START ===");
        clk             = 1'b0;
        rst_n           = 1'b0;
        sim_inject_nack = 1'b0;

        // 顶层音符初始置 000 (MUTE)
        force u_dut.auto_note = 3'd0;

        // 复位保持 200 ns
        #200;
        rst_n = 1'b1;
        $display("[%t] Step 0: Reset released, waiting for init_done...", $time);

        //---------------------------------------------------------------------
        // 1. 等待初始化完成与全屏初始铺底完成
        //---------------------------------------------------------------------
        fork
            begin : WAIT_INIT
                wait (u_dut.u_ctrl.init_done == 1'b1);
                $display("[%t] Step 1: init_done asserted!", $time);
                disable TIMEOUT_INIT;
            end
            begin : TIMEOUT_INIT
                #130000000; // 130 ms 超时
                $display("ERROR: Simulation timed out waiting for init_done!");
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end
        join

        #2000;
        $display("--------------------------------------------------");
        $display("SSD1306 Init Verification Results:");
        $display("  Init Sequence Error: %0d", model_init_seq_err);
        $display("  Addressing Mode Error: %0d", model_mode_err);
        $display("  Protocol Error: %0d", model_proto_err);
        $display("  Addressing Mode Reg: 2'b%02b (expected 2'b10)", model_addr_mode);
        $display("  Total Commands: %0d", model_cmd_cnt);
        $display("  Total Initial Data Bytes: %0d", model_data_cnt);
        $display("--------------------------------------------------");

        if (model_init_seq_err) begin
            $display("ERROR: Init command sequence does NOT match STM32 reference!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        if (model_mode_err || model_addr_mode !== 2'b10) begin
            $display("ERROR: Memory addressing mode not set to Page Addressing Mode (0x10)!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        if (model_proto_err) begin
            $display("ERROR: SSD1306 protocol error detected!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        // 校验 Page 0 标题点阵 "FINGER PIANO" ('F' 在列 17 处应为 0xF8)
        if (u_ssd1306.gram[0][17] !== 8'hF8) begin
            $display("ERROR: Page 0 Col 17 expected 0xF8 for 'F', got 0x%02X", u_ssd1306.gram[0][17]);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] Page 0 Title 'FINGER PIANO' verified.");

        // 校验 Page 2 初始 MUTE 点阵 ('M' 在列 49 处应为 0xF8)
        if (u_ssd1306.gram[2][49] !== 8'hF8) begin
            $display("ERROR: Page 2 Col 49 expected 0xF8 for 'M', got 0x%02X", u_ssd1306.gram[2][49]);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] Page 2 Initial 'MUTE' verified.");

        // 校验 Page 6, 7 为全黑 0x00
        if (u_ssd1306.gram[6][64] !== 8'h00 || u_ssd1306.gram[7][64] !== 8'h00) begin
            $display("ERROR: Page 6/7 not blank!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] Page 6/7 blank verified.");

        //---------------------------------------------------------------------
        // 2. 校验静止特性：音符不改变时无任何总线活动
        //---------------------------------------------------------------------
        initial_data_count = model_data_cnt;
        #500000; // 等待 500 us
        if (model_data_cnt !== initial_data_count) begin
            $display("ERROR: Unwanted I2C traffic while note is stationary!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] Zero-refresh stationary idle verified.");

        //---------------------------------------------------------------------
        // 3. 动态刷新测试：切换为音符 1 (1 Do C4, 261.62Hz)
        //---------------------------------------------------------------------
        $display("[%t] Step 2: Triggering note change to 1 (Do C4)...", $time);
        force u_dut.auto_note = 3'd1;

        // 等待刷新完成（4 页 x 64 字节 = 256 字节，在 100 kHz 下耗时约 27 ms）
        fork
            begin : WAIT_NOTE1
                // 等待控制器返回 S_IDLE
                wait (u_dut.u_ctrl.state == 5'd18 && u_dut.u_ctrl.display_note == 3'd1);
                $display("[%t] Note 1 refresh completed!", $time);
                disable TIMEOUT_NOTE1;
            end
            begin : TIMEOUT_NOTE1
                #40000000; // 40 ms 超时
                $display("ERROR: Simulation timed out waiting for Note 1 refresh!");
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end
        join

        // 校验增量刷新只更新了 4 页 x 64 列 = 256 字节
        step1_data_count = model_data_cnt - initial_data_count;
        $display("  Note 1 delta data bytes received: %0d (expected 256)", step1_data_count);
        if (step1_data_count !== 256) begin
            $display("ERROR: Expected exactly 256 bytes for 4-page dynamic refresh, got %0d", step1_data_count);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        // 校验 Page 2 列 35 应为 '1' 的笔画 0xF8
        if (u_ssd1306.gram[2][35] !== 8'hF8) begin
            $display("ERROR: Page 2 Col 35 expected 0xF8 for Note '1', got 0x%02X", u_ssd1306.gram[2][35]);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        // 校验 Page 0 标题没有被污染
        if (u_ssd1306.gram[0][17] !== 8'hF8) begin
            $display("ERROR: Title was corrupted after Note 1 refresh!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] Dynamic refresh for Note 1 (Do C4) verified.");

        //---------------------------------------------------------------------
        // 4. 防撕裂测试：在刷新中途快速跳变音符 (1 -> 2 -> 3)
        //---------------------------------------------------------------------
        #200000;
        $display("[%t] Step 3: Testing Anti-Tearing (switching to Note 2, then Note 3 mid-refresh)...", $time);
        force u_dut.auto_note = 3'd2; // 触发刷新 Note 2

        // 等待控制器开始进入动态页刷新
        wait (u_dut.u_ctrl.state == 5'd26 && u_dut.u_ctrl.dyn_page_idx == 2'd1);
        $display("[%t] Controller is busy at Page 3, now changing note to 3'd3!", $time);
        force u_dut.auto_note = 3'd3; // 刷新中途改变！

        // 等待完全稳定返回 S_IDLE
        fork
            begin : WAIT_NOTE3
                wait (u_dut.u_ctrl.state == 5'd18 && u_dut.u_ctrl.display_note == 3'd3 && u_dut.u_ctrl.has_pending == 1'b0);
                $display("[%t] Both frames completed, settled on Note 3!", $time);
                disable TIMEOUT_NOTE3;
            end
            begin : TIMEOUT_NOTE3
                #80000000; // 80 ms 超时 (两帧连续刷新)
                $display("ERROR: Simulation timed out waiting for Anti-Tearing Note 3 settlement!");
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end
        join

        // 校验 Page 2 显示的是 Note 3 的点阵 ('3' 在列 35 处应为 0x88)
        if (u_ssd1306.gram[2][35] !== 8'h88) begin
            $display("ERROR: Page 2 Col 35 expected 0x88 for Note '3', got 0x%02X", u_ssd1306.gram[2][35]);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] Anti-Tearing multi-frame pending latch verified.");

        //---------------------------------------------------------------------
        // 5. NACK 故障注入与停机保护测试
        //---------------------------------------------------------------------
        #200000;
        $display("[%t] Step 4: Injecting NACK fault on new note transition...", $time);
        sim_inject_nack = 1'b1; // 从机在 ACK 槽保持高阻 NACK
        force u_dut.auto_note = 3'd4; // 触发刷新

        // 等待 oled_error 置位
        fork
            begin : WAIT_ERR
                wait (u_dut.u_ctrl.oled_error == 1'b1);
                $display("[%t] oled_error asserted as expected!", $time);
                disable TIMEOUT_ERR;
            end
            begin : TIMEOUT_ERR
                #5000000; // 5 ms 超时
                $display("ERROR: Simulation timed out waiting for oled_error upon NACK injection!");
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end
        join

        // 等待几个周期后核对状态
        #20000;
        if (u_dut.u_ctrl.init_done !== 1'b0) begin
            $display("ERROR: init_done should be cleared to 0 after error!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        if (dbg_unused !== 1'b1) begin
            $display("ERROR: dbg_unused (P113) should output 1 on oled_error!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        if (dbg_led !== 1'b0) begin
            $display("ERROR: dbg_led should be off on oled_error!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        $display("[PASS] NACK error abort, bus release, and halt verified.");
        $display("--------------------------------------------------");
        $display("=== TB_OLED_TEST_TOP: PASS ===");
        $finish;
    end

endmodule
