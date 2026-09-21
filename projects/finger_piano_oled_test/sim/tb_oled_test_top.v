`timescale 1ns / 1ps

//=============================================================================
// tb_oled_test_top.v
// Stage OLED-1 最小点屏测试平台（带 ssd1306_model 仿真模型）
//=============================================================================

module tb_oled_test_top;

    reg clk;
    reg rst_n;

    wire oled_i2c_scl;
    wire oled_i2c_sda;
    wire dbg_led;
    wire dbg_unused;

    // 外部 4.7k 上拉电阻模拟
    pullup (oled_i2c_scl);
    pullup (oled_i2c_sda);

    // 12 MHz 晶振时钟源 (周期 83.333 ns, 半周期 41.667 ns)
    always #41.667 clk = ~clk;

    // 实例化顶层（将上电延时缩短为 120 拍进行快速仿真）
    oled_test_top #(
        .SYS_CLK_HZ            (12000000),
        .POWER_ON_DELAY_CYCLES (120)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .oled_i2c_scl (oled_i2c_scl),
        .oled_i2c_sda (oled_i2c_sda),
        .dbg_led      (dbg_led),
        .dbg_unused   (dbg_unused)
    );

    // 实例化 SSD1306 仿真模型（监听 7'h3C，线上 0x78）
    ssd1306_model #(
        .DEVICE_ADDR (7'h3C)
    ) u_ssd1306 (
        .clk (clk),
        .rst (!rst_n),
        .scl (oled_i2c_scl),
        .sda (oled_i2c_sda)
    );

    //-------------------------------------------------------------------------
    // 仿真测试与断言
    //-------------------------------------------------------------------------
    initial begin
        $display("=== TB_OLED_TEST_TOP: START ===");
        clk   = 1'b0;
        rst_n = 1'b0;

        // 复位保持 200 ns
        #200;
        rst_n = 1'b1;
        $display("[%t] Reset released", $time);

        // 等待 init_done 置位（100 kHz I2C 下全屏 8 页写完约需 10~13 ms）
        fork
            begin : WAIT_INIT
                wait (u_dut.u_ctrl.init_done == 1'b1);
                $display("[%t] init_done asserted!", $time);
                disable TIMEOUT_CHECK;
            end
            begin : TIMEOUT_CHECK
                #130000000; // 130 ms 超时 (1024 字节在 100 kHz 下传输耗时约 95~105 ms)
                $display("ERROR: Simulation timed out waiting for init_done!");
                $display("TB_OLED_TEST_TOP: FAIL");
                $finish;
            end
        join

        #1000;
        $display("--------------------------------------------------");
        $display("SSD1306 Model Statistics:");
        $display("  Total commands received: %0d", u_ssd1306.cmd_count);
        $display("  Total data bytes received: %0d", u_ssd1306.data_count);
        $display("  Last command byte: 0x%02X", u_ssd1306.last_cmd);
        $display("--------------------------------------------------");

        // 校验命令总数 (27 初始化字节 + 8*3 寻址命令字节 + 1 个开显示 0xAF = 52 个命令)
        if (u_ssd1306.cmd_count < 50) begin
            $display("ERROR: Expected at least 50 commands, got %0d", u_ssd1306.cmd_count);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        // 校验 8 个页面数据总数 (8 * 128 = 1024 字节)
        if (u_ssd1306.data_count !== 1024) begin
            $display("ERROR: Expected 1024 data bytes, got %0d", u_ssd1306.data_count);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        // 校验最后一条命令是 0xAF (Display ON)
        if (u_ssd1306.last_cmd !== 8'hAF) begin
            $display("ERROR: Last command expected 0xAF (Display ON), got 0x%02X", u_ssd1306.last_cmd);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        // 校验 Page 2 上的 "OLED OK" 文字点阵
        // 第 33 列应该对应 'O' 的点阵: 0x3E
        $display("Checking Page 2 content for 'OLED OK'...");
        if (u_ssd1306.gram[2][33] !== 8'h3E) begin
            $display("ERROR: Page 2 Col 33 expected 0x3E ('O'), got 0x%02X", u_ssd1306.gram[2][33]);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end
        // 第 39 列应该对应 'L' 的点阵: 0x7F
        if (u_ssd1306.gram[2][39] !== 8'h7F) begin
            $display("ERROR: Page 2 Col 39 expected 0x7F ('L'), got 0x%02X", u_ssd1306.gram[2][39]);
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        // 校验指示灯
        if (dbg_led !== 1'b1) begin
            $display("ERROR: dbg_led is not 1 after init_done");
            $display("TB_OLED_TEST_TOP: FAIL");
            $finish;
        end

        $display("Page 2 'OLED OK' bit pattern verified successfully!");
        $display("=== TB_OLED_TEST_TOP: PASS ===");
        $finish;
    end

endmodule
