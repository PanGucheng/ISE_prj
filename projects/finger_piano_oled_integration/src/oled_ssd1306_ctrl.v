//=============================================================================
// oled_ssd1306_ctrl.v (R2+ 极简双 Block RAM 零分布式 ROM 流式发送引擎)
// SSD1306 OLED 主控制器
//
// 架构革新：
//   1. 彻底消除所有分布式 ROM：
//      - BRAM 1 (RAMB16_S9): 8 种音符 64x32 动态点阵 (2048 字节)
//      - BRAM 2 (RAMB16_S9): 27 字节初始化序列 + 页面寻址/开显命令 + 标题栏点阵 (2048 字节)
//   2. 极简单一数据通路：
//      - stream_payload 简化为单一 2 选 1 逻辑 (SRC_NOTE_DATA ? BRAM1 : BRAM2)；
//      - burst_last 与 burst_is_data 直接由 burst_src 组合逻辑导出，彻底消除触发器；
//   3. 严格时序与协议兼容：
//      - 严格保持 27 字节 STM32 reference 初始化序列；
//      - Page Addressing Mode (0x10)；
//      - 标题 Page 0~1 (128 列) + 动态音符 Page 2~5 (64 列居中，列 32..95)；
//      - 音符不变 0 刷新，pending-note 防撕裂原子补刷，从机 NACK 立即停机并释放总线。
//=============================================================================

`timescale 1ns / 1ps

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
    // 1. 数据源与微引擎控制定义
    //-------------------------------------------------------------------------
    localparam [2:0]
        SRC_INIT_CMD   = 3'd0,
        SRC_NOTE_CMD   = 3'd1,
        SRC_TITLE_CMD  = 3'd2,
        SRC_DISP_ON    = 3'd3,
        SRC_TITLE_DATA = 3'd4,
        SRC_NOTE_DATA  = 3'd5;

    localparam [2:0]
        BST_IDLE  = 3'd0,
        BST_START = 3'd1,
        BST_CTRL  = 3'd2,
        BST_FETCH = 3'd3,
        BST_SEND  = 3'd4,
        BST_WAIT  = 3'd5,
        BST_STOP  = 3'd6;

    localparam [3:0]
        SEQ_PWR_WAIT       = 4'd0,
        SEQ_INIT_CMD       = 4'd1,
        SEQ_TITLE_PAGE_CMD = 4'd2,
        SEQ_TITLE_PAGE_DATA= 4'd3,
        SEQ_NOTE_PAGE_CMD  = 4'd4,
        SEQ_NOTE_PAGE_DATA = 4'd5,
        SEQ_DISP_ON        = 4'd6,
        SEQ_IDLE           = 4'd7,
        SEQ_ERROR          = 4'd8;

    // 组合逻辑导出微引擎突发属性：SRC_TITLE_DATA(4) 与 SRC_NOTE_DATA(5) bit 2 均为 1
    reg  [2:0] burst_src;
    wire       burst_is_data = burst_src[2];
    wire [6:0] burst_last    = (burst_src == SRC_TITLE_DATA) ? 7'd127 :
                               (burst_src == SRC_NOTE_DATA)  ? 7'd63  :
                               (burst_src == SRC_INIT_CMD)   ? 7'd26  :
                               (burst_src == SRC_DISP_ON)    ? 7'd0   : 7'd2;

    //-------------------------------------------------------------------------
    // 2. 状态与内部寄存器
    //-------------------------------------------------------------------------
    reg [17:0] pwr_cnt;
    wire       pwr_timeout = (POWER_ON_DELAY_CYCLES < 100) ?
                             (pwr_cnt >= POWER_ON_DELAY_CYCLES) : pwr_cnt[17];

    reg [3:0]  seq_state;
    reg [2:0]  bst_state;
    reg        burst_req;

    reg        is_init_flow;
    reg [1:0]  cur_page;
    reg [6:0]  byte_cnt;

    reg [2:0]  display_note;
    reg [2:0]  active_note;
    reg [2:0]  pending_note;
    reg        has_pending;

    // 仿真/观测别名 (保持与原有 TB 的握手点兼容)
    // synthesis translate_off
    wire [4:0] state = (seq_state == SEQ_IDLE) ? 5'd18 :
                       (seq_state == SEQ_NOTE_PAGE_DATA) ? 5'd26 : 5'd0;
    wire [1:0] dyn_page_idx = cur_page;
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // 3. 存储器接口 (2 x RAMB16: 动态点阵 BRAM + 静态配置/标题 BRAM)
    //-------------------------------------------------------------------------
    wire [7:0]  bram_dout;
    wire [10:0] bram_addr = {active_note, cur_page, byte_cnt[5:0]};

    oled_bitmap_rom u_bitmap_bram (
        .clk  (clk),
        .addr (bram_addr),
        .dout (bram_dout)
    );

    wire [7:0]  fixed_dout;
    reg  [10:0] fixed_bram_addr;
    always @(*) begin
        case (burst_src)
            SRC_INIT_CMD:   fixed_bram_addr = {6'd0, byte_cnt[4:0]};
            SRC_NOTE_CMD:   fixed_bram_addr = {6'b000001, 1'b0, cur_page[1:0], byte_cnt[1:0]}; // 0x020
            SRC_TITLE_CMD:  fixed_bram_addr = {7'b0000011, 1'b0, cur_page[0], byte_cnt[1:0]};   // 0x030 + cur_page[0]*4 + byte_cnt
            SRC_DISP_ON:    fixed_bram_addr = 11'h038;
            SRC_TITLE_DATA: fixed_bram_addr = {3'b001, cur_page[0], byte_cnt[6:0]};             // 0x100 + cur_page[0]*128 + byte_cnt
            default:        fixed_bram_addr = 11'd0;
        endcase
    end

    oled_fixed_rom u_fixed_rom (
        .clk  (clk),
        .addr (fixed_bram_addr),
        .dout (fixed_dout)
    );

    // 单一流式数据字节产生器：极简 2 选 1 数据通道
    wire [7:0] stream_payload = (burst_src == SRC_NOTE_DATA) ? bram_dout : fixed_dout;

    //-------------------------------------------------------------------------
    // 4. 主时序与状态转移逻辑
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            pwr_cnt            <= 18'd0;
            seq_state          <= SEQ_PWR_WAIT;
            bst_state          <= BST_IDLE;
            burst_req          <= 1'b0;
            burst_src          <= SRC_INIT_CMD;
            is_init_flow       <= 1'b1;
            cur_page           <= 2'd0;
            byte_cnt           <= 7'd0;
            display_note       <= 3'd0;
            active_note        <= 3'd0;
            pending_note       <= 3'd0;
            has_pending        <= 1'b0;
            init_done          <= 1'b0;
            oled_error         <= 1'b0;
            i2c_start_req      <= 1'b0;
            i2c_write_byte_req <= 1'b0;
            i2c_byte_in        <= 8'd0;
            i2c_stop_req       <= 1'b0;
        end else begin
            // 默认单周期请求脉冲自清
            i2c_start_req      <= 1'b0;
            i2c_write_byte_req <= 1'b0;
            i2c_stop_req       <= 1'b0;
            burst_req          <= 1'b0;

            // 动态防撕裂侦测：在音符刷新期间若输入变化，记录 pending_note
            if (seq_state == SEQ_NOTE_PAGE_CMD || seq_state == SEQ_NOTE_PAGE_DATA) begin
                if (note_code != active_note) begin
                    pending_note <= note_code;
                    has_pending  <= 1'b1;
                end
            end

            // 全局 NACK 错误检测与停机：必须在 i2c_byte_done 时判定，以确保正确发出 STOP 释放物理总线
            if (i2c_byte_done && i2c_ack_error && seq_state != SEQ_ERROR && seq_state != SEQ_PWR_WAIT) begin
                i2c_stop_req <= 1'b1; // 发出 STOP 释放物理总线
                bst_state    <= BST_STOP;
                seq_state    <= SEQ_ERROR;
            end else begin
                //-------------------------------------------------------------
                // 4.1 通用 Burst 发送微引擎
                //-------------------------------------------------------------
                case (bst_state)
                    BST_IDLE: begin
                        if (burst_req) begin
                            i2c_start_req <= 1'b1;
                            bst_state     <= BST_START;
                        end
                    end

                    BST_START: begin
                        if (i2c_byte_done) begin
                            // 发送控制字节：0x00 (命令流) 或 0x40 (数据流)
                            i2c_write_byte_req <= 1'b1;
                            i2c_byte_in        <= burst_is_data ? 8'h40 : 8'h00;
                            byte_cnt           <= 7'd0;
                            bst_state          <= BST_CTRL;
                        end
                    end

                    BST_CTRL: begin
                        if (i2c_byte_done) begin
                            // 控制字节发送完成，准备取第 0 个 payload 字节
                            bst_state <= BST_FETCH;
                        end
                    end

                    BST_FETCH: begin
                        // 留出 1 拍时钟给 Block RAM 建立数据 (bram_dout / fixed_dout)
                        bst_state <= BST_SEND;
                    end

                    BST_SEND: begin
                        i2c_write_byte_req <= 1'b1;
                        i2c_byte_in        <= stream_payload;
                        bst_state          <= BST_WAIT;
                    end

                    BST_WAIT: begin
                        if (i2c_byte_done) begin
                            if (byte_cnt == burst_last) begin
                                // 全部字节传输完毕，发出 STOP
                                i2c_stop_req <= 1'b1;
                                bst_state    <= BST_STOP;
                            end else begin
                                byte_cnt  <= byte_cnt + 1'b1;
                                bst_state <= BST_FETCH; // 读取下一字节
                            end
                        end
                    end

                    BST_STOP: begin
                        if (i2c_byte_done) begin
                            bst_state <= BST_IDLE;
                        end
                    end

                    default: bst_state <= BST_IDLE;
                endcase

                //-------------------------------------------------------------
                // 4.2 阶段 Sequencer
                //-------------------------------------------------------------
                case (seq_state)
                    SEQ_PWR_WAIT: begin
                        if (!pwr_timeout) begin
                            pwr_cnt <= pwr_cnt + 1'b1;
                        end else begin
                            // 上电延时完成，启动 27 字节初始化序列
                            burst_req <= 1'b1;
                            burst_src <= SRC_INIT_CMD;
                            seq_state <= SEQ_INIT_CMD;
                        end
                    end

                    SEQ_INIT_CMD: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            // 启动标题 Page 0 命令
                            cur_page  <= 2'd0;
                            burst_req <= 1'b1;
                            burst_src <= SRC_TITLE_CMD;
                            seq_state <= SEQ_TITLE_PAGE_CMD;
                        end
                    end

                    SEQ_TITLE_PAGE_CMD: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            // 发送标题当前页数据 (128 字节)
                            burst_req <= 1'b1;
                            burst_src <= SRC_TITLE_DATA;
                            seq_state <= SEQ_TITLE_PAGE_DATA;
                        end
                    end

                    SEQ_TITLE_PAGE_DATA: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            if (cur_page == 2'd0) begin
                                // 标题 Page 0 传输完成，切到 Page 1
                                cur_page  <= 2'd1;
                                burst_req <= 1'b1;
                                burst_src <= SRC_TITLE_CMD;
                                seq_state <= SEQ_TITLE_PAGE_CMD;
                            end else begin
                                // 标题刷完，准备初始显示 MUTE (Note 0)，复用动态刷新通路
                                is_init_flow <= 1'b1;
                                active_note  <= 3'd0;
                                display_note <= 3'd0;
                                cur_page     <= 2'd0;
                                burst_req    <= 1'b1;
                                burst_src    <= SRC_NOTE_CMD;
                                seq_state    <= SEQ_NOTE_PAGE_CMD;
                            end
                        end
                    end

                    // 音符刷新：Page 命令 (3 字节)
                    SEQ_NOTE_PAGE_CMD: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            // 发送音符 Page 数据 (64 字节)
                            burst_req <= 1'b1;
                            burst_src <= SRC_NOTE_DATA;
                            seq_state <= SEQ_NOTE_PAGE_DATA;
                        end
                    end

                    // 音符刷新：Page 数据 (64 字节)
                    SEQ_NOTE_PAGE_DATA: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            if (cur_page < 2'd3) begin
                                // 下一页
                                cur_page  <= cur_page + 1'b1;
                                burst_req <= 1'b1;
                                burst_src <= SRC_NOTE_CMD;
                                seq_state <= SEQ_NOTE_PAGE_CMD;
                            end else begin
                                // 4 个 Page 全部刷新完成！
                                if (is_init_flow) begin
                                    // 初始上电流程：发开显示命令
                                    is_init_flow <= 1'b0;
                                    burst_req    <= 1'b1;
                                    burst_src    <= SRC_DISP_ON;
                                    seq_state    <= SEQ_DISP_ON;
                                end else begin
                                    // 检查是否在刷新途中触发了 pending_note
                                    if (has_pending) begin
                                        active_note  <= pending_note;
                                        display_note <= active_note;
                                        has_pending  <= 1'b0;
                                        cur_page     <= 2'd0;
                                        burst_req    <= 1'b1;
                                        burst_src    <= SRC_NOTE_CMD;
                                        seq_state    <= SEQ_NOTE_PAGE_CMD;
                                    end else begin
                                        display_note <= active_note;
                                        seq_state    <= SEQ_IDLE;
                                    end
                                end
                            end
                        end
                    end

                    SEQ_DISP_ON: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            init_done    <= 1'b1;
                            display_note <= 3'd0;
                            seq_state    <= SEQ_IDLE;
                        end
                    end

                    SEQ_IDLE: begin
                        // 音符改变且不相等时触发刷新
                        if (note_code != display_note) begin
                            active_note  <= note_code;
                            has_pending  <= 1'b0;
                            cur_page     <= 2'd0;
                            burst_req    <= 1'b1;
                            burst_src    <= SRC_NOTE_CMD;
                            seq_state    <= SEQ_NOTE_PAGE_CMD;
                        end
                    end

                    SEQ_ERROR: begin
                        // 确认 STOP 序列执行完成、I2C 总线已释放回高阻后，置位 oled_error
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            oled_error <= 1'b1;
                            init_done  <= 1'b0;
                        end
                    end

                    default: seq_state <= SEQ_IDLE;
                endcase
            end
        end
    end

endmodule
