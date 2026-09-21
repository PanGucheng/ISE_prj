`timescale 1ns / 1ps

//=============================================================================
// tb_oled_test_top.v
// Stage OLED-2 完整 8 音符全状态行为与硬件交互仿真平台
//
// 验证项目：
//   1. 上电复位与 20 ms (仿真加速为 120 拍) 延迟；
//   2. 严格核验 27 字节初始化序列与 STM32 参考驱动逐字节匹配；
//   3. 严格核验 Page Addressing Mode (0x20, 0x10)；
//   4. 校验初始全屏铺底：Page 0~1 标题 ("FINGER PIANO") 与 Page 2~5 初始 MUTE；
//   5. 校验静止特性：音符不跳变时，I2C 彻底静止，0 冗余帧；
//   6. 遍历测试全部 8 个音符状态 (000=MUTE, 001=Do, 010=Re, 011=Mi, 100=Fa, 101=Sol, 110=La, 111=Si)：
//      - 每次音符跳转精确校验 256 字节数据更新 (4 Page x 64 Col)；
//      - 逐状态核验 gram 显存中独特的字符点阵与标称频率点阵；
//      - 每次切换后校验静止期 0 总线开销；
//   7. 校验防撕裂原子锁存机制：动态刷新途中输入再变，当前帧刷完后连贯补刷，无半屏撕裂；
//   8. 校验从机 NACK 故障处理：从机 NACK 时控制器立即中止、发出 STOP、置位 oled_error 并停机；
//   9. 校验停机时 SCL 与 SDA 彻底释放为高阻态 (由外部上拉拉高至 1'b1)。
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

    integer prev_data_cnt;
    integer step_data_cnt;
    integer test_note;

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

        // 校验 Page 2 初始 MUTE 点阵 ('M' 在列 49 处应为 0xF8, 列 35 为空格 0x00)
        if (u_ssd1306.gram[2][49] !== 8'hF8 || u_ssd1306.gram[2][35] !== 8'h00) begin
            $display("ERROR: Page 2 initial state not MUTE! Col 49=0x%02X, Col 35=0x%02X",
                     u_ssd1306.gram[2][49], u_ssd1306.gram[2][35]);
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
        prev_data_cnt = model_data_cnt;
        #500000; // 等待 500 us
        if (model_data_cnt !== prev_data_cnt) begin
            $display("ERROR: Unwanted I2C traffic while note is stationary!");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] Zero-refresh stationary idle verified for Note 0.");

        //---------------------------------------------------------------------
        // 3. 完整 8 音符全状态遍历测试 (1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 0)
        //---------------------------------------------------------------------
        for (test_note = 1; test_note <= 7; test_note = test_note + 1) begin
            $display("--------------------------------------------------");
            $display("[%t] Testing transition to Note %0d...", $time, test_note);
            prev_data_cnt = model_data_cnt;
            force u_dut.auto_note = test_note[2:0];

            fork
                begin : WAIT_NOTE_STEP
                    wait (u_dut.u_ctrl.state == 5'd18 && u_dut.u_ctrl.display_note == test_note[2:0]);
                    $display("[%t] Note %0d refresh complete!", $time, test_note);
                    disable TIMEOUT_NOTE_STEP;
                end
                begin : TIMEOUT_NOTE_STEP
                    #40000000; // 40 ms 超时
                    $display("ERROR: Simulation timed out waiting for Note %0d refresh!", test_note);
                    $display("TB_OLED_TEST_TOP: FAIL");
                    $finish;
                end
            join

            // 严格核验数据更新量：每帧必须恰好 4 Page x 64 Col = 256 字节
            step_data_cnt = model_data_cnt - prev_data_cnt;
            $display("  Note %0d delta data bytes: %0d (expected 256)", test_note, step_data_cnt);
            if (step_data_cnt !== 256) begin
                $display("ERROR: Expected exactly 256 bytes for Note %0d, got %0d", test_note, step_data_cnt);
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end

            // 校验各音符独特字模
            case (test_note)
                1: begin // "1 Do  C4", "261.62Hz"
                    if (u_ssd1306.gram[2][35] !== 8'hF8 || u_ssd1306.gram[2][49] !== 8'hF8 || u_ssd1306.gram[4][33] !== 8'h70) begin
                        $display("ERROR: Note 1 bitmap check failed! G[2][35]=0x%02X, G[2][49]=0x%02X, G[4][33]=0x%02X",
                                 u_ssd1306.gram[2][35], u_ssd1306.gram[2][49], u_ssd1306.gram[4][33]);
                        $display("TB_OLED_TEST_TOP: FAIL");
                        $finish;
                    end
                end
                2: begin // "2 Re  D4", "293.67Hz"
                    if (u_ssd1306.gram[2][33] !== 8'h70 || u_ssd1306.gram[2][49] !== 8'hF8 || u_ssd1306.gram[4][33] !== 8'h70) begin
                        $display("ERROR: Note 2 bitmap check failed! G[2][33]=0x%02X, G[2][49]=0x%02X, G[4][33]=0x%02X",
                                 u_ssd1306.gram[2][33], u_ssd1306.gram[2][49], u_ssd1306.gram[4][33]);
                        $display("TB_OLED_TEST_TOP: FAIL");
                        $finish;
                    end
                end
                3: begin // "3 Mi  E4", "329.63Hz"
                    if (u_ssd1306.gram[2][35] !== 8'h88 || u_ssd1306.gram[2][49] !== 8'hF8 || u_ssd1306.gram[4][33] !== 8'h30) begin
                        $display("ERROR: Note 3 bitmap check failed! G[2][35]=0x%02X, G[2][49]=0x%02X, G[4][33]=0x%02X",
                                 u_ssd1306.gram[2][35], u_ssd1306.gram[2][49], u_ssd1306.gram[4][33]);
                        $display("TB_OLED_TEST_TOP: FAIL");
                        $finish;
                    end
                end
                4: begin // "4 Fa  F4", "349.23Hz"
                    if (u_ssd1306.gram[2][37] !== 8'hF8 || u_ssd1306.gram[2][49] !== 8'hF8 || u_ssd1306.gram[4][33] !== 8'h30) begin
                        $display("ERROR: Note 4 bitmap check failed! G[2][37]=0x%02X, G[2][49]=0x%02X, G[4][33]=0x%02X",
                                 u_ssd1306.gram[2][37], u_ssd1306.gram[2][49], u_ssd1306.gram[4][33]);
                        $display("TB_OLED_TEST_TOP: FAIL");
                        $finish;
                    end
                end
                5: begin // "5 Sol G4", "391.99Hz"
                    if (u_ssd1306.gram[2][33] !== 8'hF8 || u_ssd1306.gram[2][49] !== 8'h70 || u_ssd1306.gram[4][33] !== 8'h30) begin
                        $display("ERROR: Note 5 bitmap check failed! G[2][33]=0x%02X, G[2][49]=0x%02X, G[4][33]=0x%02X",
                                 u_ssd1306.gram[2][33], u_ssd1306.gram[2][49], u_ssd1306.gram[4][33]);
                        $display("TB_OLED_TEST_TOP: FAIL");
                        $finish;
                    end
                end
                6: begin // "6 La  A4", "440.00Hz"
                    if (u_ssd1306.gram[2][33] !== 8'hE0 || u_ssd1306.gram[2][49] !== 8'hF8 || u_ssd1306.gram[4][34] !== 8'hC0) begin
                        $display("ERROR: Note 6 bitmap check failed! G[2][33]=0x%02X, G[2][49]=0x%02X, G[4][34]=0x%02X",
                                 u_ssd1306.gram[2][33], u_ssd1306.gram[2][49], u_ssd1306.gram[4][34]);
                        $display("TB_OLED_TEST_TOP: FAIL");
                        $finish;
                    end
                end
                7: begin // "7 Si  B4", "493.88Hz"
                    if (u_ssd1306.gram[2][36] !== 8'hC8 || u_ssd1306.gram[2][49] !== 8'h70 || u_ssd1306.gram[4][34] !== 8'hC0) begin
                        $display("ERROR: Note 7 bitmap check failed! G[2][36]=0x%02X, G[2][49]=0x%02X, G[4][34]=0x%02X",
                                 u_ssd1306.gram[2][36], u_ssd1306.gram[2][49], u_ssd1306.gram[4][34]);
                        $display("TB_OLED_TEST_TOP: FAIL");
                        $finish;
                    end
                end
            endcase

            // 校验标题栏 Page 0 未被覆盖
            if (u_ssd1306.gram[0][17] !== 8'hF8) begin
                $display("ERROR: Title in Page 0 corrupted during Note %0d refresh!", test_note);
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end

            // 校验各状态静止期无总线活动
            prev_data_cnt = model_data_cnt;
            #200000; // 等待 200 us
            if (model_data_cnt !== prev_data_cnt) begin
                $display("ERROR: Unwanted I2C traffic during stationary idle on Note %0d!", test_note);
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end
            $display("[PASS] Note %0d refresh (256 bytes) and stationary idle verified.", test_note);
        end

        // 切换回音符 0 (MUTE) 并核验
        $display("--------------------------------------------------");
        $display("[%t] Testing return to Note 0 (MUTE)...", $time);
        prev_data_cnt = model_data_cnt;
        force u_dut.auto_note = 3'd0;

        fork
            begin : WAIT_MUTE
                wait (u_dut.u_ctrl.state == 5'd18 && u_dut.u_ctrl.display_note == 3'd0);
                $display("[%t] Return to Note 0 (MUTE) complete!", $time);
                disable TIMEOUT_MUTE;
            end
            begin : TIMEOUT_MUTE
                #40000000;
                $display("ERROR: Simulation timed out waiting for Note 0 return!");
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end
        join

        step_data_cnt = model_data_cnt - prev_data_cnt;
        if (step_data_cnt !== 256 || u_ssd1306.gram[2][49] !== 8'hF8 || u_ssd1306.gram[2][35] !== 8'h00) begin
            $display("ERROR: MUTE return check failed! delta=%0d, G[2][49]=0x%02X, G[2][35]=0x%02X",
                     step_data_cnt, u_ssd1306.gram[2][49], u_ssd1306.gram[2][35]);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] All 8 note states successfully traversed and verified.");

        //---------------------------------------------------------------------
        // 4. 防撕裂测试：在动态刷新途中快速跳变音符 (0 -> 1 -> 2)
        //---------------------------------------------------------------------
        #200000;
        $display("--------------------------------------------------");
        $display("[%t] Step 4: Testing Anti-Tearing (switching to Note 1, then Note 2 mid-refresh)...", $time);
        force u_dut.auto_note = 3'd1;

        // 等待控制器进入动态页刷新中途 (Page 3)
        wait (u_dut.u_ctrl.state == 5'd26 && u_dut.u_ctrl.dyn_page_idx == 2'd1);
        $display("[%t] Controller is busy at Page 3, now changing note to 3'd2!", $time);
        force u_dut.auto_note = 3'd2; // 刷新途中改变！

        // 等待连贯补刷完成，稳定返回 S_IDLE
        fork
            begin : WAIT_NOTE2_SETTLE
                wait (u_dut.u_ctrl.state == 5'd18 && u_dut.u_ctrl.display_note == 3'd2 && u_dut.u_ctrl.has_pending == 1'b0);
                $display("[%t] Both frames completed, settled on Note 2!", $time);
                disable TIMEOUT_NOTE2_SETTLE;
            end
            begin : TIMEOUT_NOTE2_SETTLE
                #80000000; // 80 ms 超时 (两帧连续刷新)
                $display("ERROR: Simulation timed out waiting for Anti-Tearing Note 2 settlement!");
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end
        join

        // 校验 Page 2 显示的是 Note 2 的点阵 ('2' 在列 33 处应为 0x70)
        if (u_ssd1306.gram[2][33] !== 8'h70) begin
            $display("ERROR: Page 2 Col 33 expected 0x70 for Note '2', got 0x%02X", u_ssd1306.gram[2][33]);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] Anti-Tearing multi-frame pending latch verified.");

        //---------------------------------------------------------------------
        // 5. NACK 故障注入与停机保护测试
        //---------------------------------------------------------------------
        #200000;
        $display("--------------------------------------------------");
        $display("[%t] Step 5: Injecting NACK fault on new note transition...", $time);
        sim_inject_nack = 1'b1; // 从机在 ACK 槽保持高阻 NACK
        force u_dut.auto_note = 3'd3; // 触发刷新

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

        // 等待几个周期后核对状态与总线释放
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

        // 校验 SCL 与 SDA 彻底释放为高阻态 (由外部 pullup 保持为 1'b1)
        if (oled_i2c_scl !== 1'b1 || oled_i2c_sda !== 1'b1) begin
            $display("ERROR: I2C bus not released to high-Z after error! SCL=%b, SDA=%b",
                     oled_i2c_scl, oled_i2c_sda);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        $display("[PASS] I2C bus release (SCL=1, SDA=1 high-Z) verified.");

        $display("[PASS] NACK error abort, bus release, and halt verified.");
        $display("--------------------------------------------------");
        $display("=== TB_OLED_TEST_TOP: PASS ===");
        $finish;
    end

endmodule
