//=============================================================================
// oled_ssd1306_ctrl.v
// SSD1306 OLED 主控制器 (R3 严谨优化版: 21.8ms 纯净上电 + 8页清零 + 零撕裂无回跳微引擎)
//
// 架构特性：
//   1. 纯净硬件上电延时：
//      - 硬件综合下由 19-bit 计数器 MSB 导出 21.85ms 延时 (>=20ms, 0 LUT 比较器)；
//      - 仿真下由 SIM_FAST_INIT 专用 generate 块提供快速超时，综合无任何残留。
//   2. 等价 STM32 Reference 的显存清零初始化：
//      - 27 字节标准初始化命令后，依次对 Page 0~7 发送 0xB0|p, 0x00, 0x10 并写入 128 个 0x00；
//      - 常量零数据流直读 BRAM2 未用区域 (0x200)，保持极简单一 2 选 1 数据通道。
//   3. 零撕裂与无回跳判定：
//      - 彻底消除 pending_note 与 has_pending，帧末直接比对 note_code != active_note；
//      - 天然支持 A->B->A 零多余刷新与 A->B->C 自动跳过过时中间状态 B。
//   4. 极致 LUT 压缩：分解 BRAM 地址多路选择网络，节省数十个 LUT，确保全系统 Slice 严守预算。
//=============================================================================

`timescale 1ns / 1ps

module oled_ssd1306_ctrl #(
    parameter integer SYS_CLK_HZ    = 12000000,
    parameter integer SIM_FAST_INIT = 0
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
    localparam [3:0]
        SRC_INIT_CMD   = 4'd0,
        SRC_CLEAR_CMD  = 4'd1,
        SRC_TITLE_CMD  = 4'd2,
        SRC_NOTE_CMD   = 4'd3,
        SRC_DISP_ON    = 4'd4,
        SRC_CLEAR_DATA = 4'd8,
        SRC_TITLE_DATA = 4'd9,
        SRC_NOTE_DATA  = 4'd10;

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
        SEQ_CLEAR_PAGE_CMD = 4'd2,
        SEQ_CLEAR_PAGE_DATA= 4'd3,
        SEQ_TITLE_PAGE_CMD = 4'd4,
        SEQ_TITLE_PAGE_DATA= 4'd5,
        SEQ_NOTE_PAGE_CMD  = 4'd6,
        SEQ_NOTE_PAGE_DATA = 4'd7,
        SEQ_DISP_ON        = 4'd8,
        SEQ_IDLE           = 4'd9,
        SEQ_ERROR          = 4'd10;

    // 组合逻辑导出微引擎突发属性：数据流 bit 3 均为 1 (8, 9, 10)
    reg  [3:0] burst_src;
    wire       burst_is_data = burst_src[3];
    wire       burst_is_init = (burst_src == SRC_INIT_CMD);
    wire [6:0] burst_last    = {
        burst_is_data & ~burst_src[1],
        burst_is_data,
        burst_is_data | burst_is_init,
        burst_is_data | burst_is_init,
        burst_is_data,
        burst_is_data | (burst_src != SRC_DISP_ON),
        burst_is_data
    };

    //-------------------------------------------------------------------------
    // 2. 上电延时 (纯净仿真与硬件分支解耦)
    //-------------------------------------------------------------------------
    wire pwr_timeout;

    generate
        if (SIM_FAST_INIT) begin : GEN_SIM_PWR
            reg [3:0] pwr_sim_cnt;
            always @(posedge clk or negedge rst_n_sync) begin
                if (!rst_n_sync)
                    pwr_sim_cnt <= 4'd0;
                else if (!pwr_sim_cnt[3])
                    pwr_sim_cnt <= pwr_sim_cnt + 1'b1;
            end
            assign pwr_timeout = pwr_sim_cnt[3];
        end else begin : GEN_HW_PWR
            // 2^18 周期 @ 12MHz = 262,144 / 12,000,000 = 21.845 ms (>= 20 ms)
            reg [18:0] pwr_cnt;
            always @(posedge clk or negedge rst_n_sync) begin
                if (!rst_n_sync)
                    pwr_cnt <= 19'd0;
                else if (!pwr_cnt[18])
                    pwr_cnt <= pwr_cnt + 1'b1;
            end
            assign pwr_timeout = pwr_cnt[18];
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 3. 状态与内部寄存器
    //-------------------------------------------------------------------------
    reg [3:0] seq_state;
    reg [2:0] bst_state;
    reg       burst_req;

    reg [2:0] cur_page;   // 0..7 (清屏 0..7，音符 0..3，标题 0..1)
    reg [6:0] byte_cnt;   // 0..127 字节发送计数器

    reg [2:0] active_note;

    // 仿真/观测别名 (保持与原有 TB 的握手点兼容)
    // synthesis translate_off
    wire [4:0] state = (seq_state == SEQ_IDLE) ? 5'd18 :
                       (seq_state == SEQ_NOTE_PAGE_DATA) ? 5'd26 : 5'd0;
    wire [1:0] dyn_page_idx = cur_page[1:0];
    wire [2:0] display_note = active_note;
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // 4. 存储器接口 (2 x RAMB16: 动态点阵 BRAM + 静态配置/标题 BRAM)
    //-------------------------------------------------------------------------
    wire [7:0]  bram_dout;
    wire [10:0] bram_addr = {active_note, cur_page[1:0], byte_cnt[5:0]};

    oled_bitmap_rom u_bitmap_bram (
        .clk  (clk),
        .addr (bram_addr),
        .dout (bram_dout)
    );

    wire [7:0] fixed_dout;

    // 分解高效中间地址编码 (节省约 30 个 LUT)
    reg [5:0] addr_mid;
    always @(*) begin
        case (burst_src)
            SRC_TITLE_DATA: addr_mid = {cur_page[0], byte_cnt[6:2]};
            SRC_INIT_CMD:   addr_mid = {3'b000, byte_cnt[4:2]};
            SRC_DISP_ON:    addr_mid = 6'b001110;                // 0x38 >> 2 = 14
            SRC_NOTE_CMD:   addr_mid = {4'b0010, cur_page[1:0]}; // 0x20 >> 2 = 8
            default:        addr_mid = {3'b010, cur_page[2:0]};  // 0x40 >> 2 = 16 (0x200..0x7FF 空间全0)
        endcase
    end

    wire [10:0] fixed_bram_addr = {
        1'b0,
        (burst_src == SRC_CLEAR_DATA),
        (burst_src == SRC_TITLE_DATA),
        addr_mid,
        byte_cnt[1:0]
    };

    oled_fixed_rom u_fixed_rom (
        .clk  (clk),
        .addr (fixed_bram_addr),
        .dout (fixed_dout)
    );

    // 单一流式数据字节产生器：极简 2 选 1 数据通道 (清屏全0直接借用 BRAM2 未用空间)
    wire [7:0] stream_payload = (burst_src == SRC_NOTE_DATA) ? bram_dout : fixed_dout;

    //-------------------------------------------------------------------------
    // 5. 主时序与状态转移逻辑
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            seq_state          <= SEQ_PWR_WAIT;
            bst_state          <= BST_IDLE;
            burst_req          <= 1'b0;
            burst_src          <= SRC_INIT_CMD;
            cur_page           <= 3'd0;
            byte_cnt           <= 7'd0;
            active_note        <= 3'd0;
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

            // 全局 NACK 错误检测与停机：必须在 i2c_byte_done 时判定，以确保正确发出 STOP 释放物理总线
            if (i2c_byte_done && i2c_ack_error && seq_state != SEQ_ERROR && seq_state != SEQ_PWR_WAIT) begin
                i2c_stop_req <= 1'b1; // 发出 STOP 释放物理总线
                bst_state    <= BST_STOP;
                seq_state    <= SEQ_ERROR;
            end else begin
                //-------------------------------------------------------------
                // 5.1 通用 Burst 发送微引擎
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
                // 5.2 阶段 Sequencer
                //-------------------------------------------------------------
                case (seq_state)
                    SEQ_PWR_WAIT: begin
                        if (pwr_timeout) begin
                            // 上电延时完成，启动 27 字节初始化序列
                            burst_req <= 1'b1;
                            burst_src <= SRC_INIT_CMD;
                            seq_state <= SEQ_INIT_CMD;
                        end
                    end

                    SEQ_INIT_CMD: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            // 27 字节初始化完成，启动等价 STM32 的全 8 页显存清零流
                            cur_page  <= 3'd0;
                            burst_req <= 1'b1;
                            burst_src <= SRC_CLEAR_CMD;
                            seq_state <= SEQ_CLEAR_PAGE_CMD;
                        end
                    end

                    SEQ_CLEAR_PAGE_CMD: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            // 发送当前页 128 字节 0x00
                            burst_req <= 1'b1;
                            burst_src <= SRC_CLEAR_DATA;
                            seq_state <= SEQ_CLEAR_PAGE_DATA;
                        end
                    end

                    SEQ_CLEAR_PAGE_DATA: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            if (cur_page < 3'd7) begin
                                // 下一页清零
                                cur_page  <= cur_page + 1'b1;
                                burst_req <= 1'b1;
                                burst_src <= SRC_CLEAR_CMD;
                                seq_state <= SEQ_CLEAR_PAGE_CMD;
                            end else begin
                                // 8 页清零全部完成！启动标题 Page 0
                                cur_page  <= 3'd0;
                                burst_req <= 1'b1;
                                burst_src <= SRC_TITLE_CMD;
                                seq_state <= SEQ_TITLE_PAGE_CMD;
                            end
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
                            if (cur_page == 3'd0) begin
                                // 标题 Page 0 传输完成，切到 Page 1
                                cur_page  <= 3'd1;
                                burst_req <= 1'b1;
                                burst_src <= SRC_TITLE_CMD;
                                seq_state <= SEQ_TITLE_PAGE_CMD;
                            end else begin
                                // 标题刷完，准备初始显示 MUTE (Note 0)，复用动态刷新通路
                                active_note  <= 3'd0;
                                cur_page     <= 3'd0;
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
                            if (cur_page < 3'd3) begin
                                // 下一页
                                cur_page  <= cur_page + 1'b1;
                                burst_req <= 1'b1;
                                burst_src <= SRC_NOTE_CMD;
                                seq_state <= SEQ_NOTE_PAGE_CMD;
                            end else begin
                                // 4 个 Page 全部刷新完成！确认当前帧完整上屏
                                if (!init_done) begin
                                    // 初始上电流程：发开显示命令 (0xAF)
                                    burst_req <= 1'b1;
                                    burst_src <= SRC_DISP_ON;
                                    seq_state <= SEQ_DISP_ON;
                                end else begin
                                    // 零撕裂与无回跳核心逻辑：帧末直接采样 note_code
                                    // 若输入发生变化（无论是 A->B->C 还是短跳变），立即以当前最新 note_code 开启新一轮完整刷新
                                    if (note_code != active_note) begin
                                        active_note <= note_code;
                                        cur_page    <= 3'd0;
                                        burst_req   <= 1'b1;
                                        burst_src   <= SRC_NOTE_CMD;
                                        seq_state   <= SEQ_NOTE_PAGE_CMD;
                                    end else begin
                                        // 保持当前音符，稳定回归 IDLE，0 总线开销
                                        seq_state   <= SEQ_IDLE;
                                    end
                                end
                            end
                        end
                    end

                    SEQ_DISP_ON: begin
                        if (bst_state == BST_STOP && i2c_byte_done) begin
                            init_done <= 1'b1;
                            seq_state <= SEQ_IDLE;
                        end
                    end

                    SEQ_IDLE: begin
                        // 音符改变且不相等时触发刷新
                        if (note_code != active_note) begin
                            active_note <= note_code;
                            cur_page    <= 3'd0;
                            burst_req   <= 1'b1;
                            burst_src   <= SRC_NOTE_CMD;
                            seq_state   <= SEQ_NOTE_PAGE_CMD;
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
