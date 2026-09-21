//=============================================================================
// oled_ssd1306_ctrl.v
// SSD1306 OLED 主控制器（基于 1 x RAMB16 预渲染点阵 ROM 架构）
//
// 架构特性：
//   1. 极低资源消耗：
//      - 动态区（Page 2~5，64 列居中）8 种音符状态预渲染存入 1 x RAMB16 (2048 字节)；
//      - 标题栏 ("FINGER PIANO", Page 0~1) 存入微型分布式 ROM，仅上电初始化刷一次；
//      - 彻底消除运行时字模查找、ASCII 展开、字符串拼接与浮点运算；
//   2. 增量局部刷新与按需静止：
//      - note_code 不变时，彻底静止，0 I2C 事务；
//      - note_code 改变时，仅刷新 Page 2~5 的第 32..95 列（每页仅 64 字节）；
//   3. 防撕裂原子锁存：
//      - 维护 last_note, pending_note, display_note；
//      - 刷新途中若输入再变，记录 pending_note，当前帧刷完后连贯补刷，杜绝半屏撕裂；
//   4. 严格 ACK 错误处理：
//      - 任何从机 NACK 均触发中止、发出 STOP、置位 oled_error 并安全停机。
//=============================================================================

module oled_ssd1306_ctrl #(
    parameter integer SYS_CLK_HZ            = 12000000,
    parameter integer POWER_ON_DELAY_CYCLES = 240000     // 20 ms @ 12 MHz
) (
    input  wire       clk,
    input  wire       rst_n_sync,

    // 音符输入编码 (000=MUTE, 001=C4 ... 111=B4)
    input  wire [2:0] note_code,

    // I2C 变送接口
    output reg        i2c_start_req,
    output reg        i2c_write_byte_req,
    output reg  [7:0] i2c_byte_in,
    output reg        i2c_stop_req,
    input  wire       i2c_byte_done,
    input  wire       i2c_ack_error,

    // 状态指示
    output reg        init_done,
    output reg        oled_error
);

    //-------------------------------------------------------------------------
    // 1. 上电延时计数器
    //-------------------------------------------------------------------------
    reg [18:0] pwr_cnt;
    wire       pwr_timeout = (pwr_cnt >= POWER_ON_DELAY_CYCLES - 1);

    //-------------------------------------------------------------------------
    // 2. 初始化 27 字节命令函数 (严格遵照 STM32 参考驱动序列)
    //-------------------------------------------------------------------------
    localparam INIT_CMD_COUNT = 27;

    function [7:0] get_init_cmd;
        input [4:0] idx;
        case (idx)
            5'd0:  get_init_cmd = 8'hAE; // Display OFF
            5'd1:  get_init_cmd = 8'h20; // Set Memory Addressing Mode
            5'd2:  get_init_cmd = 8'h10; // Page Addressing Mode (0x10)
            5'd3:  get_init_cmd = 8'hB0; // Page Start Address 0
            5'd4:  get_init_cmd = 8'hC8; // COM Output Scan Direction Remapped
            5'd5:  get_init_cmd = 8'h00; // Column Start Low 0
            5'd6:  get_init_cmd = 8'h10; // Column Start High 0
            5'd7:  get_init_cmd = 8'h40; // Display Start Line 0
            5'd8:  get_init_cmd = 8'h81; // Contrast Control
            5'd9:  get_init_cmd = 8'hDF; // Contrast Value
            5'd10: get_init_cmd = 8'hA1; // Segment Re-map A1
            5'd11: get_init_cmd = 8'hA6; // Normal Display
            5'd12: get_init_cmd = 8'hA8; // Multiplex Ratio
            5'd13: get_init_cmd = 8'h3F; // 64 MUX
            5'd14: get_init_cmd = 8'hA4; // Entire Display ON resume
            5'd15: get_init_cmd = 8'hD3; // Display Offset
            5'd16: get_init_cmd = 8'h00; // Offset 0
            5'd17: get_init_cmd = 8'hD5; // Display Clock Divide / Osc Freq
            5'd18: get_init_cmd = 8'hF0; // Max Freq
            5'd19: get_init_cmd = 8'hD9; // Pre-charge Period
            5'd20: get_init_cmd = 8'h22; // Phase 1 = 2, Phase 2 = 2
            5'd21: get_init_cmd = 8'hDA; // COM Pins Config
            5'd22: get_init_cmd = 8'h12; // Alternative COM pins
            5'd23: get_init_cmd = 8'hDB; // VCOMH Deselect Level
            5'd24: get_init_cmd = 8'h20; // 0.77 x VCC
            5'd25: get_init_cmd = 8'h8D; // Charge Pump Setting
            5'd26: get_init_cmd = 8'h14; // Enable Charge Pump
            default: get_init_cmd = 8'h00;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // 3. 预渲染字模存储器接口 (1 x RAMB16 Block RAM 与 标题 ROM)
    //-------------------------------------------------------------------------
    reg  [2:0]  display_note;
    reg  [2:0]  last_note;
    reg  [2:0]  pending_note;
    reg         has_pending;

    reg  [1:0]  bram_page_idx;
    reg  [5:0]  bram_col_idx;
    wire [10:0] bram_addr = {display_note, bram_page_idx, bram_col_idx};
    wire [7:0]  bram_dout;

    oled_bitmap_rom u_bitmap_bram (
        .clk  (clk),
        .addr (bram_addr),
        .dout (bram_dout)
    );

    // 静态标题 ROM ("FINGER PIANO", Page 0~1)
    reg  [2:0]  curr_init_page;
    reg  [6:0]  curr_init_col;
    wire [7:0]  title_dout;

    oled_title_rom u_title_rom (
        .addr ({curr_init_page[0], curr_init_col}),
        .dout (title_dout)
    );

    //-------------------------------------------------------------------------
    // 4. 控制状态机定义
    //-------------------------------------------------------------------------
    localparam [4:0] S_PWR_WAIT        = 5'd0,
                     S_INIT_START      = 5'd1,
                     S_INIT_CTRL       = 5'd2,
                     S_INIT_SEND_CMD   = 5'd3,
                     S_INIT_STOP       = 5'd4,
                     // 初始全屏铺底 (Page 0..7)
                     S_SCR_PAGE_START  = 5'd5,
                     S_SCR_PAGE_CTRL   = 5'd6,
                     S_SCR_PAGE_ADDR   = 5'd7,
                     S_SCR_PAGE_STOP1  = 5'd8,
                     S_SCR_DATA_START  = 5'd9,
                     S_SCR_DATA_CTRL   = 5'd10,
                     S_SCR_DATA_FETCH  = 5'd11,
                     S_SCR_DATA_SEND   = 5'd12,
                     S_SCR_DATA_WAIT   = 5'd13,
                     S_SCR_DATA_STOP   = 5'd14,
                     // 开显示
                     S_ON_START        = 5'd15,
                     S_ON_CMD          = 5'd16,
                     S_ON_STOP         = 5'd17,
                     // 空闲静止
                     S_IDLE            = 5'd18,
                     // 动态增量刷新 (Page 2..5, Cols 32..95)
                     S_DYN_PAGE_START  = 5'd19,
                     S_DYN_PAGE_CTRL   = 5'd20,
                     S_DYN_PAGE_ADDR   = 5'd21,
                     S_DYN_PAGE_STOP1  = 5'd22,
                     S_DYN_DATA_START  = 5'd23,
                     S_DYN_DATA_CTRL   = 5'd24,
                     S_DYN_DATA_FETCH  = 5'd25,
                     S_DYN_DATA_SEND   = 5'd26,
                     S_DYN_DATA_WAIT   = 5'd27,
                     S_DYN_DATA_STOP   = 5'd28,
                     // 错误停机状态
                     S_ERR_STOP        = 5'd29,
                     S_ERR_HALT        = 5'd30;

    reg [4:0] state;
    reg [4:0] cmd_idx;
    reg [1:0] sub_cnt;

    // 动态刷新控制
    reg [1:0] dyn_page_idx; // 0..3 对应 Page 2, 3, 4, 5
    reg [5:0] dyn_col_cnt;  // 0..63 (64 列)

    // 计算初始全屏铺底各列数据
    function [7:0] get_init_byte;
        input [2:0] p;
        input [6:0] c;
        input [7:0] bram_val;
        input [7:0] title_val;
        begin
            if (p == 3'd0 || p == 3'd1) begin
                get_init_byte = title_val;
            end else if (p >= 3'd2 && p <= 3'd5) begin
                if (c >= 7'd32 && c < 7'd96)
                    get_init_byte = bram_val;
                else
                    get_init_byte = 8'h00;
            end else begin
                get_init_byte = 8'h00;
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // 5. 状态机主逻辑
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            state              <= S_PWR_WAIT;
            pwr_cnt            <= 19'd0;
            cmd_idx            <= 5'd0;
            sub_cnt            <= 2'd0;
            curr_init_page     <= 3'd0;
            curr_init_col      <= 7'd0;
            bram_page_idx      <= 2'd0;
            bram_col_idx       <= 6'd0;
            dyn_page_idx       <= 2'd0;
            dyn_col_cnt        <= 6'd0;
            display_note       <= 3'd0;
            last_note          <= 3'd0;
            pending_note       <= 3'd0;
            has_pending        <= 1'b0;
            i2c_start_req      <= 1'b0;
            i2c_write_byte_req <= 1'b0;
            i2c_byte_in        <= 8'd0;
            i2c_stop_req       <= 1'b0;
            init_done          <= 1'b0;
            oled_error         <= 1'b0;
        end else begin
            // 脉冲信号默认清零
            i2c_start_req      <= 1'b0;
            i2c_write_byte_req <= 1'b0;
            i2c_stop_req       <= 1'b0;

            // 防撕裂锁存：在初始化完成且正在刷新时，若 note_code 改变，持续锁存最新的 pending_note
            if (init_done && state != S_IDLE && state != S_ERR_STOP && state != S_ERR_HALT) begin
                if (note_code != display_note) begin
                    pending_note <= note_code;
                    has_pending  <= 1'b1;
                end
            end

            case (state)
                //-------------------------------------------------------------
                // 1. 上电延时 20 ms
                //-------------------------------------------------------------
                S_PWR_WAIT: begin
                    if (pwr_timeout) begin
                        state         <= S_INIT_START;
                        i2c_start_req <= 1'b1; // 发送 START + 0x78
                    end else begin
                        pwr_cnt <= pwr_cnt + 1'b1;
                    end
                end

                //-------------------------------------------------------------
                // 2. 发送 27 字节初始化命令
                //-------------------------------------------------------------
                S_INIT_START: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            state              <= S_INIT_CTRL;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h00; // Co=0, D/C#=0 (连续命令流)
                        end
                    end
                end

                S_INIT_CTRL: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            cmd_idx            <= 5'd0;
                            state              <= S_INIT_SEND_CMD;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= get_init_cmd(5'd0);
                        end
                    end
                end

                S_INIT_SEND_CMD: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else if (cmd_idx == INIT_CMD_COUNT - 1) begin
                            state        <= S_INIT_STOP;
                            i2c_stop_req <= 1'b1; // 结束初始化命令流
                        end else begin
                            cmd_idx            <= cmd_idx + 1'b1;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= get_init_cmd(cmd_idx + 1'b1);
                        end
                    end
                end

                S_INIT_STOP: begin
                    if (i2c_byte_done) begin
                        curr_init_page <= 3'd0;
                        curr_init_col  <= 7'd0;
                        display_note   <= 3'd0; // 初始全屏铺底显示 000 (MUTE)
                        bram_page_idx  <= 2'd0;
                        bram_col_idx   <= 6'd0;
                        state          <= S_SCR_PAGE_START;
                        i2c_start_req  <= 1'b1;
                    end
                end

                //-------------------------------------------------------------
                // 3. 初始全屏铺底：设置 Page 寻址 (B0+page, 00, 10)
                //-------------------------------------------------------------
                S_SCR_PAGE_START: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            state              <= S_SCR_PAGE_CTRL;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h00; // 命令控制字节
                        end
                    end
                end

                S_SCR_PAGE_CTRL: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            sub_cnt            <= 2'd0;
                            state              <= S_SCR_PAGE_ADDR;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= {4'hB, 1'b0, curr_init_page}; // 0xB0 + curr_init_page
                        end
                    end
                end

                S_SCR_PAGE_ADDR: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else if (sub_cnt == 2'd0) begin
                            sub_cnt            <= 2'd1;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h00; // 列地址低 4 位归 0
                        end else if (sub_cnt == 2'd1) begin
                            sub_cnt            <= 2'd2;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h10; // 列地址高 4 位归 0
                        end else begin
                            state        <= S_SCR_PAGE_STOP1;
                            i2c_stop_req <= 1'b1;
                        end
                    end
                end

                S_SCR_PAGE_STOP1: begin
                    if (i2c_byte_done) begin
                        curr_init_col <= 7'd0;
                        bram_page_idx <= (curr_init_page >= 3'd2 && curr_init_page <= 3'd5) ? (curr_init_page[1:0] - 2'b10) : 2'd0;
                        bram_col_idx  <= 6'd0;
                        state         <= S_SCR_DATA_START;
                        i2c_start_req <= 1'b1;
                    end
                end

                //-------------------------------------------------------------
                // 初始全屏铺底：写 128 列显存
                //-------------------------------------------------------------
                S_SCR_DATA_START: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            state              <= S_SCR_DATA_CTRL;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h40; // Co=0, D/C#=1 (数据流)
                        end
                    end
                end

                S_SCR_DATA_CTRL: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            // 预取第 0 列数据
                            curr_init_col <= 7'd0;
                            state         <= S_SCR_DATA_FETCH;
                        end
                    end
                end

                S_SCR_DATA_FETCH: begin
                    // 等待 1 拍让 Block RAM 读出数据 (bram_dout 建立)
                    state <= S_SCR_DATA_SEND;
                end

                S_SCR_DATA_SEND: begin
                    i2c_write_byte_req <= 1'b1;
                    i2c_byte_in        <= get_init_byte(curr_init_page, curr_init_col, bram_dout, title_dout);
                    state              <= S_SCR_DATA_WAIT;
                end

                S_SCR_DATA_WAIT: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else if (curr_init_col == 7'd127) begin
                            state        <= S_SCR_DATA_STOP;
                            i2c_stop_req <= 1'b1;
                        end else begin
                            curr_init_col <= curr_init_col + 1'b1;
                            if (curr_init_page >= 3'd2 && curr_init_page <= 3'd5 && curr_init_col >= 7'd31 && curr_init_col < 7'd95) begin
                                bram_col_idx <= (curr_init_col + 1'b1) - 7'd32; // 设置下一列在 BRAM 的地址
                            end
                            state <= S_SCR_DATA_FETCH;
                        end
                    end
                end

                S_SCR_DATA_STOP: begin
                    if (i2c_byte_done) begin
                        if (curr_init_page == 3'd7) begin
                            state         <= S_ON_START;
                            i2c_start_req <= 1'b1; // 8 页全写完，去开显示
                        end else begin
                            curr_init_page <= curr_init_page + 1'b1;
                            state          <= S_SCR_PAGE_START;
                            i2c_start_req  <= 1'b1;
                        end
                    end
                end

                //-------------------------------------------------------------
                // 4. 开启显示 (0xAF) 并宣告初始化就绪
                //-------------------------------------------------------------
                S_ON_START: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            sub_cnt            <= 2'd0;
                            state              <= S_ON_CMD;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h00; // 命令控制字节
                        end
                    end
                end

                S_ON_CMD: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else if (sub_cnt == 2'd0) begin
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
                        init_done    <= 1'b1;
                        display_note <= 3'd0;
                        last_note    <= 3'd0;
                        has_pending  <= 1'b0;
                        state        <= S_IDLE; // 进入静止待命状态
                    end
                end

                //-------------------------------------------------------------
                // 5. 空闲待命状态 (完全 0 刷新，0 I2C 事务)
                //-------------------------------------------------------------
                S_IDLE: begin
                    if (has_pending) begin
                        display_note  <= pending_note;
                        last_note     <= pending_note;
                        has_pending   <= 1'b0;
                        dyn_page_idx  <= 2'd0;
                        state         <= S_DYN_PAGE_START;
                        i2c_start_req <= 1'b1;
                    end else if (note_code != last_note) begin
                        display_note  <= note_code;
                        last_note     <= note_code;
                        has_pending   <= 1'b0;
                        dyn_page_idx  <= 2'd0;
                        state         <= S_DYN_PAGE_START;
                        i2c_start_req <= 1'b1;
                    end
                end

                //-------------------------------------------------------------
                // 6. 动态局部增量刷新 (Page 2..5, 每页仅发 64 列数据, 列 32..95)
                //-------------------------------------------------------------
                S_DYN_PAGE_START: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            state              <= S_DYN_PAGE_CTRL;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h00; // 命令控制字节
                        end
                    end
                end

                S_DYN_PAGE_CTRL: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            sub_cnt            <= 2'd0;
                            state              <= S_DYN_PAGE_ADDR;
                            i2c_write_byte_req <= 1'b1;
                            // 页地址：0xB2, 0xB3, 0xB4, 0xB5
                            i2c_byte_in        <= 8'hB2 + dyn_page_idx;
                        end
                    end
                end

                S_DYN_PAGE_ADDR: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else if (sub_cnt == 2'd0) begin
                            sub_cnt            <= 2'd1;
                            i2c_write_byte_req <= 1'b1;
                            // 列起始地址低 4 位：0x00 (32 = 0x20，低4位为0)
                            i2c_byte_in        <= 8'h00;
                        end else if (sub_cnt == 2'd1) begin
                            sub_cnt            <= 2'd2;
                            i2c_write_byte_req <= 1'b1;
                            // 列起始地址高 4 位：0x12 (32 = 0x20，高4位为2)
                            i2c_byte_in        <= 8'h12;
                        end else begin
                            state        <= S_DYN_PAGE_STOP1;
                            i2c_stop_req <= 1'b1;
                        end
                    end
                end

                S_DYN_PAGE_STOP1: begin
                    if (i2c_byte_done) begin
                        dyn_col_cnt   <= 6'd0;
                        bram_page_idx <= dyn_page_idx;
                        bram_col_idx  <= 6'd0;
                        state         <= S_DYN_DATA_START;
                        i2c_start_req <= 1'b1;
                    end
                end

                S_DYN_DATA_START: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            state              <= S_DYN_DATA_CTRL;
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= 8'h40; // 数据控制字节
                        end
                    end
                end

                S_DYN_DATA_CTRL: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else begin
                            dyn_col_cnt  <= 6'd0;
                            bram_col_idx <= 6'd0;
                            state        <= S_DYN_DATA_FETCH;
                        end
                    end
                end

                S_DYN_DATA_FETCH: begin
                    // 等待 1 拍让 Block RAM 读出数据 (bram_dout 建立)
                    state <= S_DYN_DATA_SEND;
                end

                S_DYN_DATA_SEND: begin
                    i2c_write_byte_req <= 1'b1;
                    i2c_byte_in        <= bram_dout;
                    state              <= S_DYN_DATA_WAIT;
                end

                S_DYN_DATA_WAIT: begin
                    if (i2c_byte_done) begin
                        if (i2c_ack_error) begin
                            oled_error   <= 1'b1;
                            i2c_stop_req <= 1'b1;
                            state        <= S_ERR_STOP;
                        end else if (dyn_col_cnt == 6'd63) begin
                            state        <= S_DYN_DATA_STOP;
                            i2c_stop_req <= 1'b1; // 单页 64 列发送完毕
                        end else begin
                            dyn_col_cnt  <= dyn_col_cnt + 1'b1;
                            bram_col_idx <= dyn_col_cnt + 1'b1;
                            state        <= S_DYN_DATA_FETCH;
                        end
                    end
                end

                S_DYN_DATA_STOP: begin
                    if (i2c_byte_done) begin
                        if (dyn_page_idx == 2'd3) begin
                            // 动态区 4 页全部刷新完成！
                            if (has_pending) begin
                                // 刷新中途发生了按键跳变，立即无缝进行下一帧刷新
                                display_note  <= pending_note;
                                last_note     <= pending_note;
                                has_pending   <= 1'b0;
                                dyn_page_idx  <= 2'd0;
                                state         <= S_DYN_PAGE_START;
                                i2c_start_req <= 1'b1;
                            end else begin
                                // 无待处理更新，返回静止空闲
                                state <= S_IDLE;
                            end
                        end else begin
                            // 刷新下一个动态页
                            dyn_page_idx  <= dyn_page_idx + 1'b1;
                            bram_page_idx <= dyn_page_idx + 1'b1;
                            state         <= S_DYN_PAGE_START;
                            i2c_start_req <= 1'b1;
                        end
                    end
                end

                //-------------------------------------------------------------
                // 7. 错误停机状态 (NACK 异常终止，释放总线并冻结)
                //-------------------------------------------------------------
                S_ERR_STOP: begin
                    if (i2c_byte_done) begin
                        init_done <= 1'b0;
                        state     <= S_ERR_HALT;
                    end
                end

                S_ERR_HALT: begin
                    // 永久停机，保持 oled_error = 1，必须硬件复位才可恢复
                    oled_error <= 1'b1;
                    init_done  <= 1'b0;
                end

                default: state <= S_PWR_WAIT;
            endcase
        end
    end

endmodule
