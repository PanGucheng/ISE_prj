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

module finger_piano_stage2_oled_top #(
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
    wire [2:0] piano_note_debug;
    wire       piano_adc_error;
    wire [2:0] piano_adc_error_code;

    finger_piano_stage2_top u_piano (
        .clk            (clk),
        .rst_n          (rst_n),
        .sensor_async   (sensor_async),
        .adc_i2c_scl    (adc_i2c_scl),
        .adc_i2c_sda    (adc_i2c_sda),
        .dac_i2c_scl    (dac_i2c_scl),
        .dac_i2c_sda    (dac_i2c_sda),
        .note_debug     (piano_note_debug),
        .adc_error      (piano_adc_error),
        .adc_error_code (piano_adc_error_code)
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
        .init_done          (),
        .oled_error         ()
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
    // 4. 心跳方波 (P111) 与安全接地 (P113)
    //-------------------------------------------------------------------------
    assign dbg_unused = 1'b0;

    reg [22:0] heartbeat_cnt;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            heartbeat_cnt <= 23'd0;
            dbg_heartbeat <= 1'b0;
        end else if (heartbeat_cnt == 23'd5999999) begin
            heartbeat_cnt <= 23'd0;
            dbg_heartbeat <= ~dbg_heartbeat;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 23'd1;
        end
    end

    //-------------------------------------------------------------------------
    // 5. UART 错误状态捕获与报文发送状态机 (P110)
    //-------------------------------------------------------------------------
    reg        err_pending;
    reg [2:0]  latched_ecode;
    reg        err_cleared;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            err_pending   <= 1'b0;
            latched_ecode <= 3'd0;
        end else if (piano_adc_error) begin
            err_pending   <= 1'b1;
            latched_ecode <= piano_adc_error_code;
        end else if (err_cleared) begin
            err_pending   <= 1'b0;
        end
    end

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SEND = 2'd1;
    localparam [1:0] ST_WAIT = 2'd2;

    reg [1:0]  tx_fsm;
    reg [4:0]  char_idx;
    reg [2:0]  send_ecode;
    reg [7:0]  uart_tx_byte;
    reg        uart_tx_valid;
    wire       uart_tx_ready;

    reg [7:0] cur_char;
    always @(*) begin
        case (char_idx)
            5'd0:  cur_char = "A";
            5'd1:  cur_char = "D";
            5'd2:  cur_char = "C";
            5'd3:  cur_char = " ";
            5'd4:  cur_char = "E";
            5'd5:  cur_char = "R";
            5'd6:  cur_char = "R";
            5'd7:  cur_char = "O";
            5'd8:  cur_char = "R";
            5'd9:  cur_char = " ";
            5'd10: cur_char = "C";
            5'd11: cur_char = "O";
            5'd12: cur_char = "D";
            5'd13: cur_char = "E";
            5'd14: cur_char = "=";
            5'd15: cur_char = 8'h30 + {5'd0, send_ecode};
            5'd16: cur_char = 8'h0D; // \r
            5'd17: cur_char = 8'h0A; // \n
            default: cur_char = " ";
        endcase
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            tx_fsm        <= ST_IDLE;
            char_idx      <= 5'd0;
            send_ecode    <= 3'd0;
            uart_tx_byte  <= 8'h00;
            uart_tx_valid <= 1'b0;
            err_cleared   <= 1'b0;
        end else begin
            err_cleared   <= 1'b0;
            uart_tx_valid <= 1'b0;

            case (tx_fsm)
                ST_IDLE: begin
                    char_idx <= 5'd0;
                    if (err_pending) begin
                        send_ecode  <= latched_ecode;
                        err_cleared <= 1'b1;
                        tx_fsm      <= ST_SEND;
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
                        if (char_idx == 5'd17) begin
                            tx_fsm <= ST_IDLE;
                        end else begin
                            char_idx <= char_idx + 5'd1;
                            tx_fsm   <= ST_SEND;
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
