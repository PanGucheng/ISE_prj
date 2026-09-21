//=============================================================================
// periph_test_top.v
// P9 ADS1115 ADC UART 调试版本顶层
//
// 硬件引脚与电气规范:
//   P57  : clk (12 MHz 唯一系统时钟)
//   P3   : rst_n (外部低有效复位)
//   P31  : adc_i2c_scl (ADS1115 独立开漏 100 kHz I2C, 无内部上拉)
//   P32  : adc_i2c_sda (ADS1115 独立开漏 100 kHz I2C, 无内部上拉)
//   P102 : dac_i2c_scl (关闭 DAC 诊断链, 保持 1'bz 高阻释放)
//   P103 : dac_i2c_sda (关闭 DAC 诊断链, 保持 1'bz 高阻释放)
//   P110 : uart_tx (115200 baud, 8N1, 104 拍/bit, 仅发送)
//   P111 : dbg_heartbeat (约 1 Hz 方波, 6,000,000 拍翻转)
//   P113 : dbg_unused (固定 1'b0 安全接地)
//
// 报文与数据机制:
//   1. 正常上报: 约 100 ms 一次, 纯 ASCII:
//      ADC OK CH0=0x1234 CH1=0x5678 CH2=0x9ABC\r\n
//   2. 首次采样门控: have_valid_sample=0 期间保持静默, 不输出假 0x0000 报文。
//   3. 单槽最新值缓存: latest_ch0/ch1/ch2 原子更新, 零阻塞 ADS1115 采样。
//   4. 错误上报: adc_error 到来时锁存错误码并置位 err_pending。
//      非抢占式行完整性: 若正发正常报文, 先发完当前行, 再立即优先发错误报文:
//      ADC ERROR CODE=x\r\n
//      (错误码严格沿用 ads1115_ctrl.v 定义: 1=地址NACK, 2=数据NACK, 3=超时,
//       4=其它错误包括转换超时或协议异常)
//=============================================================================

`include "finger_piano_cfg.vh"

module periph_test_top #(
    parameter integer HEARTBEAT_HALF_CYC = 6000000, // 1 Hz 方波 @ 12 MHz (500 ms 翻转)
    parameter integer REPORT_CYCLES      = 1200000, // 100 ms 报告周期 @ 12 MHz
    parameter integer UART_BAUD_RATE     = 115200
) (
    input  wire clk,           // P57, 12 MHz
    input  wire rst_n,         // P3, 外部低有效复位

    inout  wire adc_i2c_scl,   // P31, ADS1115 SCL
    inout  wire adc_i2c_sda,   // P32, ADS1115 SDA

    inout  wire dac_i2c_scl,   // P102, 保持 1'bz
    inout  wire dac_i2c_sda,   // P103, 保持 1'bz

    output wire uart_tx,       // P110, UART TX
    output reg  dbg_heartbeat, // P111, 约 1 Hz heartbeat
    output wire dbg_unused     // P113, 固定 1'b0
);

    //-------------------------------------------------------------------------
    // 安全静默与释放
    //-------------------------------------------------------------------------
    assign dac_i2c_scl = 1'bz;
    assign dac_i2c_sda = 1'bz;
    assign dbg_unused  = 1'b0;

    //-------------------------------------------------------------------------
    // 复位同步 (reset_sync 实例)
    //-------------------------------------------------------------------------
    wire rst_n_sync;

    reset_sync u_reset_sync (
        .clk        (clk),
        .rst_n      (rst_n),
        .rst_n_sync (rst_n_sync)
    );

    //-------------------------------------------------------------------------
    // Heartbeat: 约 1 Hz 方波 (P111)
    //-------------------------------------------------------------------------
    reg [22:0] heartbeat_cnt; // 2^23 = 8388608 > 6000000

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            heartbeat_cnt <= 23'd0;
            dbg_heartbeat <= 1'b0;
        end else if (heartbeat_cnt == HEARTBEAT_HALF_CYC - 1) begin
            heartbeat_cnt <= 23'd0;
            dbg_heartbeat <= ~dbg_heartbeat;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 23'd1;
        end
    end

    //-------------------------------------------------------------------------
    // ADS1115 控制器 (保持 100 kHz 速率与独立开漏总线)
    //-------------------------------------------------------------------------
    localparam integer P9_ADC_I2C_HZ = 100000;

    wire [15:0] adc_ch0_raw;
    wire [15:0] adc_ch1_raw;
    wire [15:0] adc_ch2_raw;
    wire        adc_sample_valid;
    wire        adc_busy;
    wire        adc_error;
    wire [2:0]  adc_error_code;

    ads1115_ctrl #(
        .ENABLE (1),
        .I2C_HZ (P9_ADC_I2C_HZ)
    ) u_ads1115 (
        .clk              (clk),
        .rst_n_sync       (rst_n_sync),
        .adc_i2c_scl      (adc_i2c_scl),
        .adc_i2c_sda      (adc_i2c_sda),
        .adc_ch0_raw      (adc_ch0_raw),
        .adc_ch1_raw      (adc_ch1_raw),
        .adc_ch2_raw      (adc_ch2_raw),
        .adc_sample_valid (adc_sample_valid),
        .adc_busy         (adc_busy),
        .adc_error        (adc_error),
        .error_code       (adc_error_code)
    );

    //-------------------------------------------------------------------------
    //-------------------------------------------------------------------------
    // 首次采样有效门控标志
    //-------------------------------------------------------------------------
    reg have_valid_sample;

    //-------------------------------------------------------------------------
    // CH0 电压转换 (16-bit 原始码转 4 位小数伏特 BCD)
    //-------------------------------------------------------------------------
    wire       volt_done;
    wire [3:0] conv_volt;
    wire [3:0] conv_tenths;
    wire [3:0] conv_hundredths;
    wire [3:0] conv_thousandths;
    wire [3:0] conv_tenthousands;

    reg [3:0]  latched_volt;
    reg [3:0]  latched_tenths;
    reg [3:0]  latched_hundredths;
    reg [3:0]  latched_thousandths;
    reg [3:0]  latched_tenthousands;

    bin_to_dec_volt u_volt_conv (
        .clk              (clk),
        .rst_n_sync       (rst_n_sync),
        .start            (adc_sample_valid),
        .raw_code         (adc_ch0_raw),
        .done             (volt_done),
        .d_volt           (conv_volt),
        .d_tenths         (conv_tenths),
        .d_hundredths     (conv_hundredths),
        .d_thousandths    (conv_thousandths),
        .d_tenthousands   (conv_tenthousands)
    );

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            have_valid_sample    <= 1'b0;
            latched_volt         <= 4'd0;
            latched_tenths       <= 4'd0;
            latched_hundredths   <= 4'd0;
            latched_thousandths  <= 4'd0;
            latched_tenthousands <= 4'd0;
        end else if (volt_done) begin
            have_valid_sample    <= 1'b1;
            latched_volt         <= conv_volt;
            latched_tenths       <= conv_tenths;
            latched_hundredths   <= conv_hundredths;
            latched_thousandths  <= conv_thousandths;
            latched_tenthousands <= conv_tenthousands;
        end
    end

    //-------------------------------------------------------------------------
    // 错误状态捕获 (adc_error 脉冲到达时立即置位)
    //-------------------------------------------------------------------------
    reg       err_pending;
    reg [2:0] latched_ecode;
    reg       err_cleared;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            err_pending   <= 1'b0;
            latched_ecode <= 3'd0;
        end else if (adc_error) begin
            err_pending   <= 1'b1;
            latched_ecode <= adc_error_code;
        end else if (err_cleared) begin
            err_pending   <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // 100 ms 报告定时器
    //-------------------------------------------------------------------------
    reg [20:0] timer_100ms_cnt; // 2^21 = 2097152 > 1200000
    reg        timer_100ms_tick;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            timer_100ms_cnt  <= 21'd0;
            timer_100ms_tick <= 1'b0;
        end else if (timer_100ms_cnt == REPORT_CYCLES - 1) begin
            timer_100ms_cnt  <= 21'd0;
            timer_100ms_tick <= 1'b1;
        end else begin
            timer_100ms_cnt  <= timer_100ms_cnt + 21'd1;
            timer_100ms_tick <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // 行级报文生成与非抢占式调度状态机 (FireWater 协议)
    //-------------------------------------------------------------------------
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SEND = 2'd1;
    localparam [1:0] ST_WAIT = 2'd2;

    reg [1:0]  tx_fsm;
    reg [5:0]  char_idx;
    reg [5:0]  line_len;
    reg        line_is_error;
    reg [2:0]  send_ecode;
    reg [3:0]  snap_volt;
    reg [3:0]  snap_tenths;
    reg [3:0]  snap_hundredths;
    reg [3:0]  snap_thousandths;
    reg [3:0]  snap_tenthousands;
    reg        report_pending;

    reg [7:0]  uart_tx_byte;
    reg        uart_tx_valid;
    wire       uart_tx_ready;

    // 当 100ms tick 产生且处于发送状态时, 记录一次待发
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            report_pending <= 1'b0;
        end else if (timer_100ms_tick && have_valid_sample) begin
            report_pending <= 1'b1;
        end else if (tx_fsm == ST_IDLE && !err_pending && report_pending) begin
            report_pending <= 1'b0;
        end
    end

    // 当前字符索引查找
    reg [7:0] cur_char;
    always @(*) begin
        if (line_is_error) begin
            // "ADC ERROR CODE=x\r\n" (18 字节)
            case (char_idx)
                6'd0:  cur_char = "A";
                6'd1:  cur_char = "D";
                6'd2:  cur_char = "C";
                6'd3:  cur_char = " ";
                6'd4:  cur_char = "E";
                6'd5:  cur_char = "R";
                6'd6:  cur_char = "R";
                6'd7:  cur_char = "O";
                6'd8:  cur_char = "R";
                6'd9:  cur_char = " ";
                6'd10: cur_char = "C";
                6'd11: cur_char = "O";
                6'd12: cur_char = "D";
                6'd13: cur_char = "E";
                6'd14: cur_char = "=";
                6'd15: cur_char = 8'h30 + {5'd0, send_ecode}; // '0' + code
                6'd16: cur_char = 8'h0D; // \r
                6'd17: cur_char = 8'h0A; // \n
                default: cur_char = " ";
            endcase
        end else begin
            // FireWater 协议: "ch0:X.XXXX\r\n" (12 字节)
            case (char_idx)
                6'd0:  cur_char = "c";
                6'd1:  cur_char = "h";
                6'd2:  cur_char = "0";
                6'd3:  cur_char = ":";
                6'd4:  cur_char = 8'h30 + {4'd0, snap_volt};
                6'd5:  cur_char = ".";
                6'd6:  cur_char = 8'h30 + {4'd0, snap_tenths};
                6'd7:  cur_char = 8'h30 + {4'd0, snap_hundredths};
                6'd8:  cur_char = 8'h30 + {4'd0, snap_thousandths};
                6'd9:  cur_char = 8'h30 + {4'd0, snap_tenthousands};
                6'd10: cur_char = 8'h0D; // \r
                6'd11: cur_char = 8'h0A; // \n
                default: cur_char = " ";
            endcase
        end
    end

    // 状态机主时序
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            tx_fsm            <= ST_IDLE;
            char_idx          <= 6'd0;
            line_len          <= 6'd0;
            line_is_error     <= 1'b0;
            send_ecode        <= 3'd0;
            snap_volt         <= 4'd0;
            snap_tenths       <= 4'd0;
            snap_hundredths   <= 4'd0;
            snap_thousandths  <= 4'd0;
            snap_tenthousands <= 4'd0;
            uart_tx_byte      <= 8'h00;
            uart_tx_valid     <= 1'b0;
            err_cleared       <= 1'b0;
        end else begin
            err_cleared   <= 1'b0;
            uart_tx_valid <= 1'b0;

            case (tx_fsm)
                ST_IDLE: begin
                    char_idx <= 6'd0;
                    if (err_pending) begin
                        // 错误报文优先级最高
                        line_is_error <= 1'b1;
                        send_ecode    <= latched_ecode;
                        line_len      <= 6'd18;
                        err_cleared   <= 1'b1; // 清除 pending
                        tx_fsm        <= ST_SEND;
                    end else if ((timer_100ms_tick || report_pending) && have_valid_sample) begin
                        // 正常采样报文 (必须在首次有效采样之后)
                        line_is_error     <= 1'b0;
                        snap_volt         <= latched_volt;
                        snap_tenths       <= latched_tenths;
                        snap_hundredths   <= latched_hundredths;
                        snap_thousandths  <= latched_thousandths;
                        snap_tenthousands <= latched_tenthousands;
                        line_len          <= 6'd12;
                        tx_fsm            <= ST_SEND;
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
                    // uart_tx 采纳并开始发送后 tx_ready 变低, 发送完成后重新变高
                    if (uart_tx_ready && !uart_tx_valid) begin
                        if (char_idx == line_len - 1) begin
                            // 整行完整结束
                            tx_fsm <= ST_IDLE;
                        end else begin
                            char_idx <= char_idx + 6'd1;
                            tx_fsm   <= ST_SEND;
                        end
                    end
                end

                default: tx_fsm <= ST_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // UART TX 发送器实例 (P110)
    //-------------------------------------------------------------------------
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
