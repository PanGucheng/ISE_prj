//=============================================================================
// oled_ssd1306_ctrl.v
// SSD1306 OLED 状态机与初始化/点屏控制器（Stage OLED-1）
//
// 功能：
//   1. 上电等待 20 ms（确保 SSD1306 内部电源稳定）；
//   2. 发送 27 字节标准初始化命令序列（页寻址模式，电荷泵使能，对比度配置等）；
//   3. 清屏并向 Page 2 发送测试文字 "OLED OK"；
//   4. 发送 0xAF 点亮屏幕，并置位 init_done。
//=============================================================================

module oled_ssd1306_ctrl #(
    parameter integer SYS_CLK_HZ            = 12000000,
    parameter integer POWER_ON_DELAY_CYCLES = 240000     // 20 ms @ 12 MHz (仿真时可缩短)
) (
    input  wire       clk,
    input  wire       rst_n_sync,

    // I2C 变送接口
    output reg        i2c_start_req,
    output reg        i2c_write_byte_req,
    output reg  [7:0] i2c_byte_in,
    output reg        i2c_stop_req,
    input  wire       i2c_busy,
    input  wire       i2c_byte_done,
    input  wire       i2c_ack_error,

    // 状态指示
    output reg        init_done
);

    //-------------------------------------------------------------------------
    // 上电延时计数器
    //-------------------------------------------------------------------------
    reg [18:0] pwr_cnt;
    wire       pwr_timeout = (pwr_cnt >= POWER_ON_DELAY_CYCLES - 1);

    //-------------------------------------------------------------------------
    // 初始化命令序列（共 27 字节）
    //-------------------------------------------------------------------------
    localparam INIT_CMD_COUNT = 27;
    reg [7:0] init_rom [0:INIT_CMD_COUNT-1];

    initial begin
        init_rom[0]  = 8'hAE; // Display OFF
        init_rom[1]  = 8'h20; // Set Memory Addressing Mode
        init_rom[2]  = 8'h10; // 0x10 = Page Addressing Mode
        init_rom[3]  = 8'hB0; // Set Page Start Address 0
        init_rom[4]  = 8'hC8; // COM Output Scan Direction Remapped
        init_rom[5]  = 8'h00; // Column Start Low 0
        init_rom[6]  = 8'h10; // Column Start High 0
        init_rom[7]  = 8'h40; // Display Start Line 0
        init_rom[8]  = 8'h81; // Contrast Control
        init_rom[9]  = 8'hDF; // Contrast Value
        init_rom[10] = 8'hA1; // Segment Re-map A1
        init_rom[11] = 8'hA6; // Normal Display
        init_rom[12] = 8'hA8; // Multiplex Ratio
        init_rom[13] = 8'h3F; // 64 MUX
        init_rom[14] = 8'hA4; // Entire Display ON resume
        init_rom[15] = 8'hD3; // Display Offset
        init_rom[16] = 8'h00; // Offset 0
        init_rom[17] = 8'hD5; // Clock Divide Ratio / Osc Freq
        init_rom[18] = 8'hF0; // Max Freq
        init_rom[19] = 8'hD9; // Pre-charge Period
        init_rom[20] = 8'h22; // Phase 1 = 2, Phase 2 = 2
        init_rom[21] = 8'hDA; // COM Pins Config
        init_rom[22] = 8'h12; // Alternative COM pins
        init_rom[23] = 8'hDB; // VCOMH Deselect Level
        init_rom[24] = 8'h20; // 0.77 x VCC
        init_rom[25] = 8'h8D; // Charge Pump Setting
        init_rom[26] = 8'h14; // Enable Charge Pump
    end

    //-------------------------------------------------------------------------
    // "OLED OK" 8x6 点阵字模 (7 字符 * 6 字节 = 42 字节)
    //-------------------------------------------------------------------------
    reg [7:0] test_str_rom [0:41];
    initial begin
        // 'O'
        test_str_rom[0]  = 8'h00; test_str_rom[1]  = 8'h3E; test_str_rom[2]  = 8'h41;
        test_str_rom[3]  = 8'h41; test_str_rom[4]  = 8'h41; test_str_rom[5]  = 8'h3E;
        // 'L'
        test_str_rom[6]  = 8'h00; test_str_rom[7]  = 8'h7F; test_str_rom[8]  = 8'h40;
        test_str_rom[9]  = 8'h40; test_str_rom[10] = 8'h40; test_str_rom[11] = 8'h40;
        // 'E'
        test_str_rom[12] = 8'h00; test_str_rom[13] = 8'h7F; test_str_rom[14] = 8'h49;
        test_str_rom[15] = 8'h49; test_str_rom[16] = 8'h49; test_str_rom[17] = 8'h41;
        // 'D'
        test_str_rom[18] = 8'h00; test_str_rom[19] = 8'h7F; test_str_rom[20] = 8'h41;
        test_str_rom[21] = 8'h41; test_str_rom[22] = 8'h22; test_str_rom[23] = 8'h1C;
        // ' '
        test_str_rom[24] = 8'h00; test_str_rom[25] = 8'h00; test_str_rom[26] = 8'h00;
        test_str_rom[27] = 8'h00; test_str_rom[28] = 8'h00; test_str_rom[29] = 8'h00;
        // 'O'
        test_str_rom[30] = 8'h00; test_str_rom[31] = 8'h3E; test_str_rom[32] = 8'h41;
        test_str_rom[33] = 8'h41; test_str_rom[34] = 8'h41; test_str_rom[35] = 8'h3E;
        // 'K'
        test_str_rom[36] = 8'h00; test_str_rom[37] = 8'h7F; test_str_rom[38] = 8'h08;
        test_str_rom[39] = 8'h14; test_str_rom[40] = 8'h22; test_str_rom[41] = 8'h41;
    end

    //-------------------------------------------------------------------------
    // 主控制状态机
    //-------------------------------------------------------------------------
    localparam [3:0] S_PWR_WAIT      = 4'd0,
                     S_INIT_START    = 4'd1,
                     S_INIT_CTRL     = 4'd2,
                     S_INIT_SEND_CMD = 4'd3,
                     S_INIT_STOP     = 4'd4,
                     S_PAGE_START    = 4'd5,
                     S_PAGE_CMD_CTRL = 4'd6,
                     S_PAGE_CMD_ADDR = 4'd7,
                     S_PAGE_STOP1    = 4'd8,
                     S_PAGE_DATA_ST  = 4'd9,
                     S_PAGE_DATA_CTL = 4'd10,
                     S_PAGE_DATA_COL = 4'd11,
                     S_PAGE_STOP2    = 4'd12,
                     S_ON_START      = 4'd13,
                     S_ON_CMD        = 4'd14,
                     S_ON_STOP       = 4'd15;

    reg [3:0] state;
    reg [4:0] cmd_idx;
    reg [2:0] curr_page;
    reg [6:0] col_cnt;
    reg [1:0] sub_cnt;

    // 辅助计算指定列的输出像素字节
    function [7:0] col_data_fn;
        input [6:0] col;
        begin
            if (curr_page == 3'd2 && col >= 7'd32 && col < 7'd74)
                col_data_fn = test_str_rom[col - 7'd32];
            else
                col_data_fn = 8'h00;
        end
    endfunction

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            state              <= S_PWR_WAIT;
            pwr_cnt            <= 19'd0;
            cmd_idx            <= 5'd0;
            curr_page          <= 3'd0;
            col_cnt            <= 7'd0;
            sub_cnt            <= 2'd0;
            i2c_start_req      <= 1'b0;
            i2c_write_byte_req <= 1'b0;
            i2c_byte_in        <= 8'd0;
            i2c_stop_req       <= 1'b0;
            init_done          <= 1'b0;
        end else begin
            i2c_start_req      <= 1'b0;
            i2c_write_byte_req <= 1'b0;
            i2c_stop_req       <= 1'b0;

            case (state)
                // 1. 上电等待 20 ms
                S_PWR_WAIT: begin
                    if (pwr_timeout) begin
                        state         <= S_INIT_START;
                        i2c_start_req <= 1'b1; // 发送 START + 0x78
                    end else begin
                        pwr_cnt <= pwr_cnt + 1'b1;
                    end
                end

                // 2. 发送初始化控制字节 0x00 (连续命令流)
                S_INIT_START: begin
                    if (i2c_byte_done) begin
                        state              <= S_INIT_CTRL;
                        i2c_write_byte_req <= 1'b1;
                        i2c_byte_in        <= 8'h00; // Co=0, D/C#=0
                    end
                end

                // 3. 顺序发送 27 个初始化命令字节
                S_INIT_CTRL: begin
                    if (i2c_byte_done) begin
                        cmd_idx            <= 5'd0;
                        state              <= S_INIT_SEND_CMD;
                        i2c_write_byte_req <= 1'b1;
                        i2c_byte_in        <= init_rom[0];
                    end
                end

                S_INIT_SEND_CMD: begin
                    if (i2c_byte_done) begin
                        if (cmd_idx == INIT_CMD_COUNT - 1) begin
                            state        <= S_INIT_STOP;
                            i2c_stop_req <= 1'b1; // 结束初始化命令流
                        end else begin
                            cmd_idx            <= cmd_idx + 1'b1;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= init_rom[cmd_idx + 1'b1];
                        end
                    end
                end

                S_INIT_STOP: begin
                    if (i2c_byte_done) begin
                        curr_page     <= 3'd0;
                        state         <= S_PAGE_START;
                        i2c_start_req <= 1'b1; // 开始写第 0 页
                    end
                end

                //-------------------------------------------------------------
                // 4. 页面寻址写入：设置页地址与列起始地址 (B0+page, 00, 10)
                //-------------------------------------------------------------
                S_PAGE_START: begin
                    if (i2c_byte_done) begin
                        state              <= S_PAGE_CMD_CTRL;
                        i2c_write_byte_req <= 1'b1;
                        i2c_byte_in        <= 8'h00; // 命令控制字节
                    end
                end

                S_PAGE_CMD_CTRL: begin
                    if (i2c_byte_done) begin
                        sub_cnt            <= 2'd0;
                        state              <= S_PAGE_CMD_ADDR;
                        i2c_write_byte_req <= 1'b1;
                        i2c_byte_in        <= {4'hB, 1'b0, curr_page}; // 0xB0 + curr_page
                    end
                end

                S_PAGE_CMD_ADDR: begin
                    if (i2c_byte_done) begin
                        if (sub_cnt == 2'd0) begin
                            sub_cnt            <= 2'd1;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h00; // 列地址低 4 位归 0
                        end else if (sub_cnt == 2'd1) begin
                            sub_cnt            <= 2'd2;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h10; // 列地址高 4 位归 0
                        end else begin
                            state        <= S_PAGE_STOP1;
                            i2c_stop_req <= 1'b1;
                        end
                    end
                end

                S_PAGE_STOP1: begin
                    if (i2c_byte_done) begin
                        state         <= S_PAGE_DATA_ST;
                        i2c_start_req <= 1'b1; // START 开始发送数据流
                    end
                end

                //-------------------------------------------------------------
                // 5. 发送页面 128 列数据 (0x40 控制字节 + 128 字节点阵)
                //-------------------------------------------------------------
                S_PAGE_DATA_ST: begin
                    if (i2c_byte_done) begin
                        state              <= S_PAGE_DATA_CTL;
                        i2c_write_byte_req <= 1'b1;
                        i2c_byte_in        <= 8'h40; // Co=0, D/C#=1 数据控制字节
                    end
                end

                S_PAGE_DATA_CTL: begin
                    if (i2c_byte_done) begin
                        col_cnt            <= 7'd0;
                        state              <= S_PAGE_DATA_COL;
                        i2c_write_byte_req <= 1'b1;
                        i2c_byte_in        <= col_data_fn(7'd0);
                    end
                end

                S_PAGE_DATA_COL: begin
                    if (i2c_byte_done) begin
                        if (col_cnt == 7'd127) begin
                            state        <= S_PAGE_STOP2;
                            i2c_stop_req <= 1'b1; // 单页 128 列发送完毕
                        end else begin
                            col_cnt            <= col_cnt + 1'b1;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= col_data_fn(col_cnt + 1'b1);
                        end
                    end
                end

                S_PAGE_STOP2: begin
                    if (i2c_byte_done) begin
                        if (curr_page == 3'd7) begin
                            // 8 页全部写入完毕，准备开显示
                            state         <= S_ON_START;
                            i2c_start_req <= 1'b1;
                        end else begin
                            // 下一页
                            curr_page     <= curr_page + 1'b1;
                            state         <= S_PAGE_START;
                            i2c_start_req <= 1'b1;
                        end
                    end
                end

                //-------------------------------------------------------------
                // 6. 开启显示 (0xAF) 并完成初始化
                //-------------------------------------------------------------
                S_ON_START: begin
                    if (i2c_byte_done) begin
                        sub_cnt            <= 2'd0;
                        state              <= S_ON_CMD;
                        i2c_write_byte_req <= 1'b1;
                        i2c_byte_in        <= 8'h00; // 命令控制字节
                    end
                end

                S_ON_CMD: begin
                    if (i2c_byte_done) begin
                        if (sub_cnt == 2'd0) begin
                            sub_cnt            <= 2'd1;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'hAF; // 0xAF: Display ON!
                        end else begin
                            state        <= S_ON_STOP;
                            i2c_stop_req <= 1'b1;
                        end
                    end
                end

                S_ON_STOP: begin
                    if (i2c_byte_done) begin
                        init_done <= 1'b1; // 初始化与初始帧完成！
                        // 停在此状态，释放总线，不进行无谓刷新
                    end
                end

                default: state <= S_PWR_WAIT;
            endcase
        end
    end

endmodule
