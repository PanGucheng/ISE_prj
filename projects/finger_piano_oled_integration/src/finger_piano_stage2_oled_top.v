//=============================================================================
// finger_piano_stage2_oled_top.v
// Stage-2 OLED 集成探针顶层 (wrapper only)
//
// 架构：
//   1. 实例化未改动的 finger_piano_stage2_top，保留全部已有输入/输出接口；
//   2. 采样 note_debug[2:0] 作为 note_code[2:0] 送入 OLED 控制器；
//   3. 剥离全部独立测试用的辅助逻辑 (auto_note, 1.5s 步进计数器, 心跳闪烁, dbg_led, dbg_unused)；
//   4. 仅保留真正的硬件显示链 (oled_ssd1306_ctrl, oled_i2c_write, oled_bitmap_rom, oled_title_rom)；
//   5. 驱动物理引脚 P104 (SCL) 与 P105 (SDA)。
//=============================================================================

`include "finger_piano_cfg.vh"

module finger_piano_stage2_oled_top (
    input  wire       clk,           // 唯一系统时钟 (12 MHz, P57)
    input  wire       rst_n,         // 外部异步低有效复位 (P3)

    input  wire [2:0] sensor_async,  // LM393 比较器输入 (P28, P29, P30)

    inout  wire       adc_i2c_scl,   // ADS1115 独立 I2C (P31)
    inout  wire       adc_i2c_sda,   // (P32)

    inout  wire       dac_i2c_scl,   // MCP4725 独立 I2C (P102)
    inout  wire       dac_i2c_sda,   // (P103)

    output wire [2:0] note_debug,    // 当前音符编码输出 (P110, P111, P113)

    output wire       oled_i2c_scl,  // SSD1306 独立 I2C (P104)
    inout  wire       oled_i2c_sda   // (P105)
);

    //-------------------------------------------------------------------------
    // 1. 实例化未改动的基线物理顶层
    //-------------------------------------------------------------------------
    finger_piano_stage2_top u_piano (
        .clk          (clk),
        .rst_n        (rst_n),
        .sensor_async (sensor_async),
        .adc_i2c_scl  (adc_i2c_scl),
        .adc_i2c_sda  (adc_i2c_sda),
        .dac_i2c_scl  (dac_i2c_scl),
        .dac_i2c_sda  (dac_i2c_sda),
        .note_debug   (note_debug)
    );

    //-------------------------------------------------------------------------
    // 2. 独立复位同步器 (换取基线顶层完全零侵入)
    //-------------------------------------------------------------------------
    reg [1:0] oled_rst_sync_ff;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            oled_rst_sync_ff <= 2'b00;
        else
            oled_rst_sync_ff <= {oled_rst_sync_ff[0], 1'b1};
    end
    wire oled_rst_n_sync = oled_rst_sync_ff[1];

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
        .SIM_FAST_INIT (0)
    ) u_oled_ctrl (
        .clk                (clk),
        .rst_n_sync         (oled_rst_n_sync),
        .note_code          (note_debug),
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
        .rst_n_sync     (oled_rst_n_sync),
        .start_req      (i2c_start_req),
        .write_byte_req (i2c_write_byte_req),
        .byte_in        (i2c_byte_in),
        .stop_req       (i2c_stop_req),
        .byte_done      (i2c_byte_done),
        .ack_error      (i2c_ack_error),
        .oled_scl       (oled_i2c_scl),
        .oled_sda       (oled_i2c_sda)
    );

endmodule
