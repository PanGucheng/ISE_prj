//=============================================================================
// oled_test_top.v
// Stage OLED-2/3 独立屏幕与音符显示测试顶层模块
//
// 硬件引脚：
//   - clk:          P57  (12 MHz 晶振输入)
//   - rst_n:        P3   (外部低有效复位按键)
//   - oled_i2c_scl: P104 (独立 OLED SCL，开漏，板级 4.7k 上拉到 3.3V)
//   - oled_i2c_sda: P105 (独立 OLED SDA，开漏，板级 4.7k 上拉到 3.3V)
//   - dbg_led:      P111 (状态指示：初始化中 1 Hz 心跳，成功常亮，报错熄灭)
//   - dbg_unused:   P113 (OLED 错误标志输出：0 正常，1 发生 NACK 停机)
//=============================================================================

module oled_test_top #(
    parameter integer SYS_CLK_HZ       = 12000000,
    parameter integer SIM_FAST_INIT    = 0,
    parameter integer AUTO_STEP_CYCLES = 18000000   // 硬件下 1.5 秒步进一个音符 (0 时禁止自动步进)
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
    wire       i2c_byte_done;
    wire       i2c_ack_error;
    wire       init_done;
    wire       oled_error;

    // 3. 音符自动步进发生器 (供硬件直接上板巡检全部 8 种音符状态)
    reg [24:0] step_cnt;
    reg [2:0]  auto_note;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            step_cnt  <= 25'd0;
            auto_note <= 3'd0;
        end else if (init_done && AUTO_STEP_CYCLES > 0) begin
            if (step_cnt >= AUTO_STEP_CYCLES - 1) begin
                step_cnt  <= 25'd0;
                auto_note <= auto_note + 1'b1;
            end else begin
                step_cnt <= step_cnt + 1'b1;
            end
        end
    end

    wire [2:0] current_note = auto_note;

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
        .byte_done      (i2c_byte_done),
        .ack_error      (i2c_ack_error),
        .oled_scl       (oled_i2c_scl),
        .oled_sda       (oled_i2c_sda)
    );

    oled_ssd1306_ctrl #(
        .SYS_CLK_HZ    (SYS_CLK_HZ),
        .SIM_FAST_INIT (SIM_FAST_INIT)
    ) u_ctrl (
        .clk                (clk),
        .rst_n_sync         (rst_n_sync),
        .note_code          (current_note),
        .i2c_start_req      (i2c_start_req),
        .i2c_write_byte_req (i2c_write_byte_req),
        .i2c_byte_in        (i2c_byte_in),
        .i2c_stop_req       (i2c_stop_req),
        .i2c_byte_done      (i2c_byte_done),
        .i2c_ack_error      (i2c_ack_error),
        .init_done          (init_done),
        .oled_error         (oled_error)
    );

    // 4. 调试与心跳指示
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

    // 若发生错误则常灭；初始化中心跳闪烁；初始化成功常亮
    assign dbg_led    = oled_error ? 1'b0 : (init_done ? 1'b1 : hb_led);
    assign dbg_unused = oled_error;

endmodule
