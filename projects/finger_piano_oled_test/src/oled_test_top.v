//=============================================================================
// oled_test_top.v
// Stage OLED-1 最小点屏测试顶层模块
//
// 引脚分配：
//   - clk:          P57  (12 MHz 晶振输入)
//   - rst_n:        P3   (外部低有效复位按键)
//   - oled_i2c_scl: P104 (独立 OLED SCL，开漏，需外挂 4.7k 上拉到 3.3V)
//   - oled_i2c_sda: P105 (独立 OLED SDA，开漏，需外挂 4.7k 上拉到 3.3V)
//   - dbg_led:      P111 (1 Hz 心跳闪烁，初始化完成后常亮或快闪指示)
//   - dbg_unused:   P113 (固定接地 1'b0)
//=============================================================================

module oled_test_top #(
    parameter integer SYS_CLK_HZ            = 12000000,
    parameter integer POWER_ON_DELAY_CYCLES = 240000     // 20 ms @ 12 MHz
) (
    input  wire clk,
    input  wire rst_n,

    inout  wire oled_i2c_scl,
    inout  wire oled_i2c_sda,

    output wire dbg_led,
    output wire dbg_unused
);

    // 1. 复位同步
    wire rst_n_sync;
    reset_sync u_reset_sync (
        .clk        (clk),
        .rst_n      (rst_n),
        .rst_n_sync (rst_n_sync)
    );

    // 2. I2C 极简写控制器与 OLED 主控状态机连线
    wire       i2c_start_req;
    wire       i2c_write_byte_req;
    wire [7:0] i2c_byte_in;
    wire       i2c_stop_req;
    wire       i2c_busy;
    wire       i2c_byte_done;
    wire       i2c_ack_error;
    wire       init_done;

    oled_i2c_write #(
        .SYS_CLK_HZ     (SYS_CLK_HZ),
        .I2C_BUS_HZ     (100000),
        .I2C_ADDR_WRITE (8'h78)
    ) u_i2c (
        .clk            (clk),
        .rst_n_sync     (rst_n_sync),
        .start_req      (i2c_start_req),
        .write_byte_req (i2c_write_byte_req),
        .byte_in        (i2c_byte_in),
        .stop_req       (i2c_stop_req),
        .busy           (i2c_busy),
        .byte_done      (i2c_byte_done),
        .ack_error      (i2c_ack_error),
        .oled_scl       (oled_i2c_scl),
        .oled_sda       (oled_i2c_sda)
    );

    oled_ssd1306_ctrl #(
        .SYS_CLK_HZ            (SYS_CLK_HZ),
        .POWER_ON_DELAY_CYCLES (POWER_ON_DELAY_CYCLES)
    ) u_ctrl (
        .clk                (clk),
        .rst_n_sync         (rst_n_sync),
        .i2c_start_req      (i2c_start_req),
        .i2c_write_byte_req (i2c_write_byte_req),
        .i2c_byte_in        (i2c_byte_in),
        .i2c_stop_req       (i2c_stop_req),
        .i2c_busy           (i2c_busy),
        .i2c_byte_done      (i2c_byte_done),
        .i2c_ack_error      (i2c_ack_error),
        .init_done          (init_done)
    );

    // 3. 心跳指示计数器 (12 MHz 下 500 ms 翻转一次)
    reg [22:0] hb_cnt;
    reg        hb_led;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            hb_cnt <= 23'd0;
            hb_led <= 1'b0;
        end else begin
            if (hb_cnt >= 23'd5999999) begin
                hb_cnt <= 23'd0;
                hb_led <= ~hb_led;
            end else begin
                hb_cnt <= hb_cnt + 1'b1;
            end
        end
    end

    // 初始化完成前 1 Hz 心跳，完成后点亮
    assign dbg_led    = init_done ? 1'b1 : hb_led;
    assign dbg_unused = 1'b0;

endmodule
