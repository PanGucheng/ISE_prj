// Frozen UART behavior from commit 5447e81; do not optimize with DUT.
//=============================================================================
// finger_piano_stage2_oled_top.v
// Stage-2 OLED 集成物理顶层
//
// 架构：
//   1. 实例化 finger_piano_stage2_top，保留全部已有系统功能（按键滤波解码、三通道 ADC、
//      DDS 音频及 MCP4725 DAC 输出）；
//   2. 采样 note_debug[2:0] 作为 note_code[2:0] 送入 OLED 控制器（SSD1306 显示）；
//   3. 物理排针 P110/P111/P113 复用为调试与串口接口（与 periph_test 硬件引脚严格一致）：
//      - P110: uart_tx (115200 baud, 8N1)，当 ADS1115 发生异常时打印 "ADC ERROR CODE=x\r\n"
//      - P111: dbg_heartbeat (~1 Hz 方波心跳，证明 FPGA 配置及时钟正常)
//      - P113: dbg_unused (固定 1'b0 安全接地)
//   4. 物理引脚 P104 (SCL) 与 P105 (SDA) 驱动 SSD1306 OLED 独立总线。
//=============================================================================

`include "finger_piano_cfg.vh"

module finger_piano_stage2_oled_top_reference #(
    parameter integer SIM_FAST_INIT  = 0,
    parameter integer UART_BAUD_RATE = 115200
) (
    input  wire       clk,           // 唯一系统时钟 (12 MHz, P57)
    input  wire       rst_n,         // 外部异步低有效复位 (P3)

    input  wire [2:0] sensor_async,  // LM393 比较器输入 (P28, P29, P30)

    inout  wire       adc_i2c_scl,   // ADS1115 独立 I2C (P31)
    inout  wire       adc_i2c_sda,   // (P32)

    inout  wire       dac_i2c_scl,   // MCP4725 独立 I2C (P102)
    inout  wire       dac_i2c_sda,   // (P103)

    output wire       oled_i2c_scl,  // SSD1306 独立 I2C (P104)
    inout  wire       oled_i2c_sda,  // (P105)

    output wire       uart_tx,       // UART TX 115200 8N1 (P110)
    output reg        dbg_heartbeat, // 约 1 Hz 心跳方波 (P111)
    output wire       dbg_unused     // 固定 1'b0 (P113)
);

    //-------------------------------------------------------------------------
    // 1. 实例化基线物理顶层
    //-------------------------------------------------------------------------
    wire [2:0]  piano_note_debug;
    wire        piano_adc_error;
    wire [2:0]  piano_adc_error_code;
    wire        piano_adc_sample_valid;
    wire [15:0] piano_adc_ch0_raw;
    wire [15:0] piano_adc_ch1_raw;
    wire [15:0] piano_adc_ch2_raw;

    finger_piano_stage2_top u_piano (
        .clk              (clk),
        .rst_n            (rst_n),
        .sensor_async     (sensor_async),
        .adc_i2c_scl      (adc_i2c_scl),
        .adc_i2c_sda      (adc_i2c_sda),
        .dac_i2c_scl      (dac_i2c_scl),
        .dac_i2c_sda      (dac_i2c_sda),
        .note_debug       (piano_note_debug),
        .adc_error        (piano_adc_error),
        .adc_error_code   (piano_adc_error_code),
        .adc_sample_valid (piano_adc_sample_valid),
        .adc_ch0_raw      (piano_adc_ch0_raw),
        .adc_ch1_raw      (piano_adc_ch1_raw),
        .adc_ch2_raw      (piano_adc_ch2_raw)
    );

    //-------------------------------------------------------------------------
    // 2. 独立复位同步器 (换取基线顶层完全零侵入)
    //-------------------------------------------------------------------------
    reg [1:0] rst_sync_ff;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rst_sync_ff <= 2'b00;
        else
            rst_sync_ff <= {rst_sync_ff[0], 1'b1};
    end
    wire rst_n_sync = rst_sync_ff[1];

    //-------------------------------------------------------------------------
    // 3. SSD1306 OLED 主控制器与 I2C 发送器
    //-------------------------------------------------------------------------
    wire       i2c_start_req;
    wire       i2c_write_byte_req;
    wire [7:0] i2c_byte_in;
    wire       i2c_stop_req;
    wire       i2c_byte_done;
    wire       i2c_ack_error;

    oled_ssd1306_ctrl #(
        .SYS_CLK_HZ    (12000000),
        .SIM_FAST_INIT (SIM_FAST_INIT)
    ) u_oled_ctrl (
        .clk                (clk),
        .rst_n_sync         (rst_n_sync),
        .note_code          (piano_note_debug),
        .i2c_start_req      (i2c_start_req),
        .i2c_write_byte_req (i2c_write_byte_req),
        .i2c_byte_in        (i2c_byte_in),
        .i2c_stop_req       (i2c_stop_req),
        .i2c_byte_done      (i2c_byte_done),
        .i2c_ack_error      (i2c_ack_error),
        .init_done          (oled_init_done),
        .oled_error         (oled_error)
    );

    oled_i2c_write #(
        .SYS_CLK_HZ (12000000),
        .I2C_BUS_HZ (100000)
    ) u_oled_i2c (
        .clk            (clk),
        .rst_n_sync     (rst_n_sync),
        .start_req      (i2c_start_req),
        .write_byte_req (i2c_write_byte_req),
        .byte_in        (i2c_byte_in),
        .stop_req       (i2c_stop_req),
        .byte_done      (i2c_byte_done),
        .ack_error      (i2c_ack_error),
        .oled_scl       (oled_i2c_scl),
        .oled_sda       (oled_i2c_sda)
    );

    //-------------------------------------------------------------------------
    // 4. 心跳方波 (P111) 与 OLED 错误指示 (P113)
    //-------------------------------------------------------------------------
    assign dbg_unused = oled_error;

    reg [22:0] heartbeat_cnt;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            heartbeat_cnt <= 23'd0;
            dbg_heartbeat <= 1'b0;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 23'd1;
            dbg_heartbeat <= heartbeat_cnt[22];
        end
    end

    //-------------------------------------------------------------------------
    // 5. UART 全系统多通道诊断日志状态机 (P110, 115200 8N1)
    //-------------------------------------------------------------------------
    localparam [2:0] MSG_NONE      = 3'd0,
                     MSG_READY     = 3'd1,
                     MSG_OLED_OK   = 3'd2,
                     MSG_OLED_NACK = 3'd3,
                     MSG_ADC_ERR   = 3'd4,
                     MSG_NOTE      = 3'd5,
                     MSG_ADC_OK    = 3'd6;

    reg [7:0]  boot_timer;
    reg        boot_pending;
    reg        oled_ok_pending;
    reg        oled_err_pending;
    reg        adc_err_pending;
    reg [2:0]  latched_ecode;
    reg        note_pending;
    reg [2:0]  latched_note;
    reg [2:0]  note_prev;

    reg        adc_has_sampled;
    reg        adc_ok_pending;

    reg oled_init_done_d;
    reg oled_error_d;
    reg adc_error_d;

    // 状态机声明与寄存器定义
    localparam [1:0] ST_IDLE = 2'd0,
                     ST_SEND = 2'd1,
                     ST_WAIT = 2'd2;

    reg [1:0]  tx_fsm;
    reg [2:0]  send_msg_type;
    reg [4:0]  send_msg_len;
    reg [4:0]  char_idx;
    reg [1:0]  ch_idx;
    reg [3:0]  step_idx;
    reg [15:0] hex_sr;
    reg [2:0]  send_ecode;
    reg [2:0]  send_note;

    reg [7:0]  uart_tx_byte;
    reg        uart_tx_valid;
    wire       uart_tx_ready;

    // 事件捕获与边沿检测
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            boot_timer       <= 8'd0;
            boot_pending     <= 1'b0;
            oled_ok_pending  <= 1'b0;
            oled_err_pending <= 1'b0;
            adc_err_pending  <= 1'b0;
            latched_ecode    <= 3'd0;
            note_pending     <= 1'b0;
            latched_note     <= 3'd0;
            note_prev        <= 3'd0;
            oled_init_done_d <= 1'b0;
            oled_error_d     <= 1'b0;
            adc_error_d      <= 1'b0;
            adc_has_sampled  <= 1'b0;
            adc_ok_pending   <= 1'b0;
        end else begin
            oled_init_done_d <= oled_init_done;
            oled_error_d     <= oled_error;
            adc_error_d      <= piano_adc_error;

            // 开机上电延迟 200 个时钟周期后发送 READY (确保 TX 引脚处于稳定空闲态)
            if (boot_timer < 8'd200) begin
                boot_timer <= boot_timer + 8'd1;
                if (boot_timer == 8'd199) begin
                    boot_pending <= 1'b1;
                end
            end

            // OLED OK: 上升沿触发
            if (oled_init_done && !oled_init_done_d) begin
                oled_ok_pending <= 1'b1;
            end

            // OLED NACK: 上升沿触发
            if (oled_error && !oled_error_d) begin
                oled_err_pending <= 1'b1;
            end

            // ADC 错误: 上升沿触发
            if (piano_adc_error && !adc_error_d) begin
                adc_err_pending <= 1'b1;
                latched_ecode   <= piano_adc_error_code;
            end

            // 音符改变: 非 0 且变化
            if (piano_note_debug != 3'd0 && piano_note_debug != note_prev) begin
                note_pending <= 1'b1;
                latched_note <= piano_note_debug;
                note_prev    <= piano_note_debug;
            end else if (piano_note_debug == 3'd0) begin
                note_prev <= 3'd0;
            end

            // ADC 数据就绪标志
            if (piano_adc_sample_valid) begin
                adc_has_sampled <= 1'b1;
            end

            if (heartbeat_cnt == 23'd0 && adc_has_sampled) begin
                adc_ok_pending <= 1'b1;
            end

            // 发送握手清除
            if (tx_fsm == ST_SEND && ((send_msg_type == MSG_ADC_OK) ? (ch_idx == 2'd3 && step_idx == 4'd0) : (char_idx == 5'd0))) begin
                case (send_msg_type)
                    MSG_READY:     boot_pending     <= 1'b0;
                    MSG_OLED_OK:   oled_ok_pending  <= 1'b0;
                    MSG_OLED_NACK: oled_err_pending <= 1'b0;
                    MSG_ADC_ERR:   adc_err_pending  <= 1'b0;
                    MSG_NOTE:      note_pending     <= 1'b0;
                    MSG_ADC_OK:    adc_ok_pending   <= 1'b0;
                    default: ;
                endcase
            end
        end
    end

    function [7:0] hex2char;
        input [3:0] nibble;
        begin
            hex2char = {4'd0, nibble} + ((nibble < 4'd10) ? 8'h30 : 8'h37);
        end
    endfunction

    reg [7:0] cur_char;
    always @(*) begin
        if (send_msg_type == MSG_ADC_OK) begin
            if (ch_idx == 2'd3) begin
                case (step_idx)
                    4'd0:    cur_char = "A";
                    4'd1:    cur_char = "D";
                    4'd2:    cur_char = "C";
                    4'd3:    cur_char = " ";
                    4'd4:    cur_char = "O";
                    4'd5:    cur_char = "K";
                    default: cur_char = " ";
                endcase
            end else begin
                case (step_idx)
                    4'd0:    cur_char = "C";
                    4'd1:    cur_char = "H";
                    4'd2:    cur_char = 8'h30 + {6'd0, ch_idx};
                    4'd3:    cur_char = "=";
                    4'd4:    cur_char = "0";
                    4'd5:    cur_char = "x";
                    4'd6, 4'd7, 4'd8, 4'd9: cur_char = hex2char(hex_sr[15:12]);
                    4'd10:   cur_char = (ch_idx == 2'd2) ? 8'h0D : " ";
                    4'd11:   cur_char = 8'h0A;
                    default: cur_char = " ";
                endcase
            end
        end else if (char_idx == send_msg_len) begin
            cur_char = 8'h0A;
        end else if (char_idx == send_msg_len - 5'd1) begin
            cur_char = 8'h0D;
        end else begin
            case (send_msg_type)
                MSG_READY: begin
                    case (char_idx)
                        5'd0:    cur_char = "R";
                        5'd1:    cur_char = "E";
                        5'd2:    cur_char = "A";
                        5'd3:    cur_char = "D";
                        default: cur_char = "Y";
                    endcase
                end
                MSG_OLED_OK, MSG_OLED_NACK: begin
                    case (char_idx)
                        5'd0:    cur_char = "O";
                        5'd1:    cur_char = "L";
                        5'd2:    cur_char = "E";
                        5'd3:    cur_char = "D";
                        5'd4:    cur_char = " ";
                        5'd5:    cur_char = (send_msg_type == MSG_OLED_OK) ? "O" : "N";
                        5'd6:    cur_char = (send_msg_type == MSG_OLED_OK) ? "K" : "A";
                        5'd7:    cur_char = "C";
                        default: cur_char = "K";
                    endcase
                end
                MSG_ADC_ERR: begin
                    case (char_idx)
                        5'd0:    cur_char = "A";
                        5'd1:    cur_char = "D";
                        5'd2:    cur_char = "C";
                        5'd3:    cur_char = " ";
                        5'd4:    cur_char = "E";
                        5'd5:    cur_char = "R";
                        5'd6:    cur_char = "R";
                        5'd7:    cur_char = "=";
                        default: cur_char = 8'h30 + {5'd0, send_ecode};
                    endcase
                end
                MSG_NOTE: begin
                    case (char_idx)
                        5'd0:    cur_char = "N";
                        5'd1:    cur_char = "O";
                        5'd2:    cur_char = "T";
                        5'd3:    cur_char = "E";
                        5'd4:    cur_char = "=";
                        default: cur_char = 8'h30 + {5'd0, send_note};
                    endcase
                end
                default: cur_char = " ";
            endcase
        end
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            tx_fsm        <= ST_IDLE;
            send_msg_type <= MSG_NONE;
            send_msg_len  <= 5'd0;
            char_idx      <= 5'd0;
            ch_idx        <= 2'd0;
            step_idx      <= 4'd0;
            hex_sr        <= 16'd0;
            send_ecode    <= 3'd0;
            send_note     <= 3'd0;
            uart_tx_byte  <= 8'h00;
            uart_tx_valid <= 1'b0;
        end else begin
            uart_tx_valid <= 1'b0;

            case (tx_fsm)
                ST_IDLE: begin
                    char_idx <= 5'd0;
                    if (boot_pending) begin
                        send_msg_type <= MSG_READY;
                        send_msg_len  <= 5'd6;
                        tx_fsm        <= ST_SEND;
                    end else if (oled_err_pending) begin
                        send_msg_type <= MSG_OLED_NACK;
                        send_msg_len  <= 5'd10;
                        tx_fsm        <= ST_SEND;
                    end else if (oled_ok_pending) begin
                        send_msg_type <= MSG_OLED_OK;
                        send_msg_len  <= 5'd8;
                        tx_fsm        <= ST_SEND;
                    end else if (adc_err_pending) begin
                        send_msg_type <= MSG_ADC_ERR;
                        send_msg_len  <= 5'd10;
                        send_ecode    <= latched_ecode;
                        tx_fsm        <= ST_SEND;
                    end else if (note_pending) begin
                        send_msg_type <= MSG_NOTE;
                        send_msg_len  <= 5'd7;
                        send_note     <= latched_note;
                        tx_fsm        <= ST_SEND;
                    end else if (adc_ok_pending) begin
                        send_msg_type <= MSG_ADC_OK;
                        ch_idx        <= 2'd3;
                        step_idx      <= 4'd0;
                        hex_sr        <= 16'd0;
                        tx_fsm        <= ST_SEND;
                    end
                end

                ST_SEND: begin
                    if (uart_tx_ready) begin
                        uart_tx_byte  <= cur_char;
                        uart_tx_valid <= 1'b1;
                        tx_fsm        <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    uart_tx_valid <= 1'b0;
                    if (uart_tx_ready && !uart_tx_valid) begin
                        if (send_msg_type == MSG_ADC_OK) begin
                            if (ch_idx == 2'd3) begin
                                if (step_idx == 4'd6) begin
                                    ch_idx   <= 2'd0;
                                    step_idx <= 4'd0;
                                    hex_sr   <= piano_adc_ch0_raw;
                                    tx_fsm   <= ST_SEND;
                                end else begin
                                    step_idx <= step_idx + 4'd1;
                                    tx_fsm   <= ST_SEND;
                                end
                            end else begin
                                if (step_idx >= 4'd6 && step_idx <= 4'd9) begin
                                    hex_sr <= {hex_sr[11:0], 4'b0};
                                end

                                if (ch_idx == 2'd2 && step_idx == 4'd11) begin
                                    tx_fsm <= ST_IDLE;
                                end else if (ch_idx < 2'd2 && step_idx == 4'd10) begin
                                    ch_idx   <= ch_idx + 2'd1;
                                    step_idx <= 4'd0;
                                    hex_sr   <= (ch_idx == 2'd0) ? piano_adc_ch1_raw : piano_adc_ch2_raw;
                                    tx_fsm   <= ST_SEND;
                                end else begin
                                    step_idx <= step_idx + 4'd1;
                                    tx_fsm   <= ST_SEND;
                                end
                            end
                        end else begin
                            if (char_idx == send_msg_len) begin
                                tx_fsm <= ST_IDLE;
                            end else begin
                                char_idx <= char_idx + 5'd1;
                                tx_fsm   <= ST_SEND;
                            end
                        end
                    end
                end

                default: tx_fsm <= ST_IDLE;
            endcase
        end
    end

    uart_tx #(
        .CLK_HZ    (`SYS_CLK_HZ),
        .BAUD_RATE (UART_BAUD_RATE)
    ) u_uart_tx (
        .clk        (clk),
        .rst_n_sync (rst_n_sync),
        .tx_byte    (uart_tx_byte),
        .tx_valid   (uart_tx_valid),
        .tx_ready   (uart_tx_ready),
        .tx_pin     (uart_tx)
    );

endmodule
