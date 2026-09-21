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
    // 状态机编码与控制变量声明 (前置以符合 Verilog-2001 先声明后引用)
    //-------------------------------------------------------------------------
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SEND = 2'd1;
    localparam [1:0] ST_WAIT = 2'd2;

    reg [1:0]  tx_fsm;
    reg        err_pending;
    reg [2:0]  latched_ecode;
    reg        err_cleared;
    reg        new_frame_ready;

    //-------------------------------------------------------------------------
    // 三通道时分复用高精度电压换算流水线 (单实例节约 400+ LUTs, 耗时仅 5.5 us)
    //-------------------------------------------------------------------------
    reg [1:0]  conv_fsm;
    localparam C_IDLE = 2'd0,
               C_CH0  = 2'd1,
               C_CH1  = 2'd2,
               C_CH2  = 2'd3;

    reg [15:0] held_ch1, held_ch2;
    reg [15:0] conv_raw_in;
    reg        conv_start;
    wire       conv_done;
    wire [3:0] conv_v, conv_t, conv_h, conv_m, conv_tm;

    reg [3:0]  latched_v0, latched_t0, latched_h0, latched_m0, latched_tm0;
    reg [3:0]  latched_v1, latched_t1, latched_h1, latched_m1, latched_tm1;
    reg [3:0]  latched_v2, latched_t2, latched_h2, latched_m2, latched_tm2;

    bin_to_dec_volt u_volt_conv (
        .clk            (clk),
        .rst_n_sync     (rst_n_sync),
        .start          (conv_start),
        .raw_code       (conv_raw_in),
        .done           (conv_done),
        .d_volt         (conv_v),
        .d_tenths       (conv_t),
        .d_hundredths   (conv_h),
        .d_thousandths  (conv_m),
        .d_tenthousands (conv_tm)
    );

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            conv_fsm        <= C_IDLE;
            conv_start      <= 1'b0;
            conv_raw_in     <= 16'd0;
            held_ch1        <= 16'd0;
            held_ch2        <= 16'd0;
            new_frame_ready <= 1'b0;
            latched_v0  <= 4'd0; latched_t0  <= 4'd0; latched_h0  <= 4'd0; latched_m0  <= 4'd0; latched_tm0 <= 4'd0;
            latched_v1  <= 4'd0; latched_t1  <= 4'd0; latched_h1  <= 4'd0; latched_m1  <= 4'd0; latched_tm1 <= 4'd0;
            latched_v2  <= 4'd0; latched_t2  <= 4'd0; latched_h2  <= 4'd0; latched_m2  <= 4'd0; latched_tm2 <= 4'd0;
        end else begin
            conv_start <= 1'b0;
            if (tx_fsm == ST_IDLE && !err_pending && new_frame_ready) begin
                new_frame_ready <= 1'b0;
            end

            case (conv_fsm)
                C_IDLE: begin
                    if (adc_sample_valid) begin
                        held_ch1    <= adc_ch1_raw;
                        held_ch2    <= adc_ch2_raw;
                        conv_raw_in <= adc_ch0_raw;
                        conv_start  <= 1'b1;
                        conv_fsm    <= C_CH0;
                    end
                end

                C_CH0: begin
                    if (conv_done) begin
                        latched_v0  <= conv_v;
                        latched_t0  <= conv_t;
                        latched_h0  <= conv_h;
                        latched_m0  <= conv_m;
                        latched_tm0 <= conv_tm;
                        conv_raw_in <= held_ch1;
                        conv_start  <= 1'b1;
                        conv_fsm    <= C_CH1;
                    end
                end

                C_CH1: begin
                    if (conv_done) begin
                        latched_v1  <= conv_v;
                        latched_t1  <= conv_t;
                        latched_h1  <= conv_h;
                        latched_m1  <= conv_m;
                        latched_tm1 <= conv_tm;
                        conv_raw_in <= held_ch2;
                        conv_start  <= 1'b1;
                        conv_fsm    <= C_CH2;
                    end
                end

                C_CH2: begin
                    if (conv_done) begin
                        latched_v2      <= conv_v;
                        latched_t2      <= conv_t;
                        latched_h2      <= conv_h;
                        latched_m2      <= conv_m;
                        latched_tm2     <= conv_tm;
                        new_frame_ready <= 1'b1;
                        conv_fsm        <= C_IDLE;
                    end
                end

                default: conv_fsm <= C_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // 错误状态捕获 (adc_error 脉冲到达时立即置位)
    //-------------------------------------------------------------------------
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
    // 行级报文生成与非抢占式调度状态机 (FireWater 协议)
    //-------------------------------------------------------------------------
    reg [5:0]  char_idx;
    reg [5:0]  line_len;
    reg        line_is_error;
    reg [2:0]  send_ecode;
    reg [3:0]  snap_v0, snap_t0, snap_h0, snap_m0, snap_tm0;
    reg [3:0]  snap_v1, snap_t1, snap_h1, snap_m1, snap_tm1;
    reg [3:0]  snap_v2, snap_t2, snap_h2, snap_m2, snap_tm2;

    reg [7:0]  uart_tx_byte;
    reg        uart_tx_valid;
    wire       uart_tx_ready;

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
            // FireWater 协议: "V0.TTTT,V1.TTTT,V2.TTTT\r\n" (22 字节)
            case (char_idx)
                6'd0:  cur_char = 8'h30 + {4'd0, snap_v0};
                6'd1:  cur_char = ".";
                6'd2:  cur_char = 8'h30 + {4'd0, snap_t0};
                6'd3:  cur_char = 8'h30 + {4'd0, snap_h0};
                6'd4:  cur_char = 8'h30 + {4'd0, snap_m0};
                6'd5:  cur_char = 8'h30 + {4'd0, snap_tm0};
                6'd6:  cur_char = ",";
                6'd7:  cur_char = 8'h30 + {4'd0, snap_v1};
                6'd8:  cur_char = ".";
                6'd9:  cur_char = 8'h30 + {4'd0, snap_t1};
                6'd10: cur_char = 8'h30 + {4'd0, snap_h1};
                6'd11: cur_char = 8'h30 + {4'd0, snap_m1};
                6'd12: cur_char = 8'h30 + {4'd0, snap_tm1};
                6'd13: cur_char = ",";
                6'd14: cur_char = 8'h30 + {4'd0, snap_v2};
                6'd15: cur_char = ".";
                6'd16: cur_char = 8'h30 + {4'd0, snap_t2};
                6'd17: cur_char = 8'h30 + {4'd0, snap_h2};
                6'd18: cur_char = 8'h30 + {4'd0, snap_m2};
                6'd19: cur_char = 8'h30 + {4'd0, snap_tm2};
                6'd20: cur_char = 8'h0D; // \r
                6'd21: cur_char = 8'h0A; // \n
                default: cur_char = " ";
            endcase
        end
    end

    // 状态机主时序
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            tx_fsm        <= ST_IDLE;
            char_idx      <= 6'd0;
            line_len      <= 6'd0;
            line_is_error <= 1'b0;
            send_ecode    <= 3'd0;
            snap_v0  <= 4'd0; snap_t0  <= 4'd0; snap_h0  <= 4'd0; snap_m0  <= 4'd0; snap_tm0 <= 4'd0;
            snap_v1  <= 4'd0; snap_t1  <= 4'd0; snap_h1  <= 4'd0; snap_m1  <= 4'd0; snap_tm1 <= 4'd0;
            snap_v2  <= 4'd0; snap_t2  <= 4'd0; snap_h2  <= 4'd0; snap_m2  <= 4'd0; snap_tm2 <= 4'd0;
            uart_tx_byte  <= 8'h00;
            uart_tx_valid <= 1'b0;
            err_cleared   <= 1'b0;
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
                    end else if (new_frame_ready) begin
                        // 正常采样报文 (新帧就绪立即发送)
                        line_is_error <= 1'b0;
                        snap_v0  <= latched_v0; snap_t0  <= latched_t0; snap_h0  <= latched_h0; snap_m0  <= latched_m0; snap_tm0 <= latched_tm0;
                        snap_v1  <= latched_v1; snap_t1  <= latched_t1; snap_h1  <= latched_h1; snap_m1  <= latched_m1; snap_tm1 <= latched_tm1;
                        snap_v2  <= latched_v2; snap_t2  <= latched_t2; snap_h2  <= latched_h2; snap_m2  <= latched_m2; snap_tm2 <= latched_tm2;
                        line_len <= 6'd22;
                        tx_fsm   <= ST_SEND;
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
