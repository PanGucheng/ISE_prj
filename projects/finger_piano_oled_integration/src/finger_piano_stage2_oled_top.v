//=============================================================================
// finger_piano_stage2_oled_top.v
// Stage-2 OLED 集成物理顶层 (无休止循环播放《See You Again》完整 14 小节旋律)
//
// 架构：
//   1. 实例化 finger_piano_stage2_top，保留全部已有系统功能（按键滤波解码、三通道 ADC、
//      DDS 音频及 MCP4725 DAC 输出）；
//   2. 采样 note_debug[2:0] 作为 note_code[2:0] 送入 OLED 控制器（SSD1306 显示）；
//   3. 物理排针 P110/P111/P113 调试接口：
//      - P110: uart_tx (固定拉高 1'b1 空闲态，精简掉 UART 发送机以释放资源存放完整长曲谱)
//      - P111: dbg_heartbeat (~1.4 Hz 方波心跳，证明 FPGA 配置及时钟正常)
//      - P113: dbg_unused (异或汇聚硬件采集信号，防止底层 ADC/压力链被 XST 修剪)
//   4. 物理引脚 P104 (SCL) 与 P105 (SDA) 驱动 SSD1306 OLED 独立总线；
//   5. 内置《See You Again》完整 14 小节（224 拍，约 39.2 秒）旋律发生器，持续循环播放。
//=============================================================================

`include "finger_piano_cfg.vh"

module finger_piano_stage2_oled_top #(
    parameter integer SIM_FAST_INIT          = 0,
    parameter integer UART_BAUD_RATE         = 115200,
    parameter integer ADC_NOTE_TRIGGER       = 1,
    parameter integer AUTO_PLAY              = 1,
    parameter [14:0]  PRESSURE_THRESHOLD     = 15'd8000,
    parameter [14:0]  PRESSURE_THRESHOLD_CH2 = 15'd2400
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

    output wire       uart_tx,       // 固定 1'b1 空闲高电平 (P110)
    output reg        dbg_heartbeat, // 约 1.4 Hz 心跳方波 (P111)
    output wire       dbg_unused     // 汇聚未修剪信号 (P113)
);

    //-------------------------------------------------------------------------
    // 1. 基线物理顶层连接线
    //-------------------------------------------------------------------------
    wire [2:0]  piano_note_debug;
    wire        piano_adc_error;
    wire [2:0]  piano_adc_error_code;
    wire        piano_adc_sample_valid;
    wire [15:0] piano_adc_ch0_raw;
    wire [15:0] piano_adc_ch1_raw;
    wire [15:0] piano_adc_ch2_raw;
    wire [14:0] piano_pressure_ch0;
    wire [14:0] piano_pressure_ch1;
    wire [14:0] piano_pressure_ch2;
    wire        piano_pressure_valid;

    //-------------------------------------------------------------------------
    // 2. 独立复位同步器与系统心跳分频器
    //-------------------------------------------------------------------------
    reg [1:0] rst_sync_ff;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rst_sync_ff <= 2'b00;
        else
            rst_sync_ff <= {rst_sync_ff[0], 1'b1};
    end
    wire rst_n_sync = rst_sync_ff[1];

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
    // 3. 压力门限判定 (手动备用)
    //-------------------------------------------------------------------------
    wire [2:0] adc_sensor_code;
    assign adc_sensor_code[0] = (piano_pressure_ch0 >= PRESSURE_THRESHOLD);
    assign adc_sensor_code[1] = (piano_pressure_ch1 >= PRESSURE_THRESHOLD);
    assign adc_sensor_code[2] = (piano_pressure_ch2 >= PRESSURE_THRESHOLD_CH2);

    wire [2:0] manual_sensor =
        (ADC_NOTE_TRIGGER != 0) ? adc_sensor_code : sensor_async;

    wire oled_init_done;
    wire oled_error;

    //-------------------------------------------------------------------------
    // 4. 《See You Again》完整 14 小节旋律发生器 (持续不间断循环播放)
    //-------------------------------------------------------------------------
    reg [7:0] song_step;
    reg [3:0] song_rom_entry;

    // 《See You Again》完整 14 小节旋律 ROM (224 步)
    always @(*) begin
        case (song_step)
            8'd0: song_rom_entry = 4'b0101; // --- 第 1 小节 ---
            8'd1: song_rom_entry = 4'b1101;
            8'd2: song_rom_entry = 4'b0010;
            8'd3: song_rom_entry = 4'b1010;
            8'd4: song_rom_entry = 4'b0001;
            8'd5: song_rom_entry = 4'b1001;
            8'd6: song_rom_entry = 4'b0011;
            8'd7: song_rom_entry = 4'b1011;
            8'd8: song_rom_entry = 4'b0000;
            8'd9: song_rom_entry = 4'b0000;
            8'd10: song_rom_entry = 4'b1001;
            8'd11: song_rom_entry = 4'b1010;
            8'd12: song_rom_entry = 4'b1011;
            8'd13: song_rom_entry = 4'b1010;
            8'd14: song_rom_entry = 4'b1001;
            8'd15: song_rom_entry = 4'b1010;
            8'd16: song_rom_entry = 4'b0101; // --- 第 2 小节 ---
            8'd17: song_rom_entry = 4'b1101;
            8'd18: song_rom_entry = 4'b0010;
            8'd19: song_rom_entry = 4'b1010;
            8'd20: song_rom_entry = 4'b0001;
            8'd21: song_rom_entry = 4'b1001;
            8'd22: song_rom_entry = 4'b0011;
            8'd23: song_rom_entry = 4'b1011;
            8'd24: song_rom_entry = 4'b0000;
            8'd25: song_rom_entry = 4'b0000;
            8'd26: song_rom_entry = 4'b1001;
            8'd27: song_rom_entry = 4'b1010;
            8'd28: song_rom_entry = 4'b1011;
            8'd29: song_rom_entry = 4'b1010;
            8'd30: song_rom_entry = 4'b1001;
            8'd31: song_rom_entry = 4'b1010;
            8'd32: song_rom_entry = 4'b0101; // --- 第 3 小节 ---
            8'd33: song_rom_entry = 4'b1101;
            8'd34: song_rom_entry = 4'b0010;
            8'd35: song_rom_entry = 4'b1010;
            8'd36: song_rom_entry = 4'b0001;
            8'd37: song_rom_entry = 4'b1001;
            8'd38: song_rom_entry = 4'b0011;
            8'd39: song_rom_entry = 4'b1011;
            8'd40: song_rom_entry = 4'b0000;
            8'd41: song_rom_entry = 4'b0000;
            8'd42: song_rom_entry = 4'b1001;
            8'd43: song_rom_entry = 4'b1010;
            8'd44: song_rom_entry = 4'b1011;
            8'd45: song_rom_entry = 4'b1010;
            8'd46: song_rom_entry = 4'b1001;
            8'd47: song_rom_entry = 4'b1010;
            8'd48: song_rom_entry = 4'b0101; // --- 第 4 小节 ---
            8'd49: song_rom_entry = 4'b1101;
            8'd50: song_rom_entry = 4'b0010;
            8'd51: song_rom_entry = 4'b1010;
            8'd52: song_rom_entry = 4'b0001;
            8'd53: song_rom_entry = 4'b1001;
            8'd54: song_rom_entry = 4'b0011;
            8'd55: song_rom_entry = 4'b1011;
            8'd56: song_rom_entry = 4'b0000;
            8'd57: song_rom_entry = 4'b0000;
            8'd58: song_rom_entry = 4'b0001;
            8'd59: song_rom_entry = 4'b1001;
            8'd60: song_rom_entry = 4'b0011;
            8'd61: song_rom_entry = 4'b1011;
            8'd62: song_rom_entry = 4'b0101;
            8'd63: song_rom_entry = 4'b1101;
            8'd64: song_rom_entry = 4'b0110; // --- 第 5 小节 ---
            8'd65: song_rom_entry = 4'b0110;
            8'd66: song_rom_entry = 4'b0110;
            8'd67: song_rom_entry = 4'b0110;
            8'd68: song_rom_entry = 4'b0110;
            8'd69: song_rom_entry = 4'b1110;
            8'd70: song_rom_entry = 4'b0101;
            8'd71: song_rom_entry = 4'b1101;
            8'd72: song_rom_entry = 4'b0000;
            8'd73: song_rom_entry = 4'b0000;
            8'd74: song_rom_entry = 4'b0000;
            8'd75: song_rom_entry = 4'b0000;
            8'd76: song_rom_entry = 4'b0000;
            8'd77: song_rom_entry = 4'b0000;
            8'd78: song_rom_entry = 4'b0000;
            8'd79: song_rom_entry = 4'b1001;
            8'd80: song_rom_entry = 4'b0010; // --- 第 6 小节 ---
            8'd81: song_rom_entry = 4'b1010;
            8'd82: song_rom_entry = 4'b0010;
            8'd83: song_rom_entry = 4'b1010;
            8'd84: song_rom_entry = 4'b0000;
            8'd85: song_rom_entry = 4'b0000;
            8'd86: song_rom_entry = 4'b1010;
            8'd87: song_rom_entry = 4'b1011;
            8'd88: song_rom_entry = 4'b0000;
            8'd89: song_rom_entry = 4'b0000;
            8'd90: song_rom_entry = 4'b0000;
            8'd91: song_rom_entry = 4'b0000;
            8'd92: song_rom_entry = 4'b0000;
            8'd93: song_rom_entry = 4'b0000;
            8'd94: song_rom_entry = 4'b1011;
            8'd95: song_rom_entry = 4'b1101;
            8'd96: song_rom_entry = 4'b0110; // --- 第 7 小节 ---
            8'd97: song_rom_entry = 4'b1110;
            8'd98: song_rom_entry = 4'b0111;
            8'd99: song_rom_entry = 4'b1111;
            8'd100: song_rom_entry = 4'b0110;
            8'd101: song_rom_entry = 4'b1110;
            8'd102: song_rom_entry = 4'b0101;
            8'd103: song_rom_entry = 4'b1101;
            8'd104: song_rom_entry = 4'b0011;
            8'd105: song_rom_entry = 4'b1011;
            8'd106: song_rom_entry = 4'b0010;
            8'd107: song_rom_entry = 4'b1010;
            8'd108: song_rom_entry = 4'b0001;
            8'd109: song_rom_entry = 4'b0001;
            8'd110: song_rom_entry = 4'b1001;
            8'd111: song_rom_entry = 4'b1110;
            8'd112: song_rom_entry = 4'b0010; // --- 第 8 小节 ---
            8'd113: song_rom_entry = 4'b1010;
            8'd114: song_rom_entry = 4'b0010;
            8'd115: song_rom_entry = 4'b1010;
            8'd116: song_rom_entry = 4'b0001;
            8'd117: song_rom_entry = 4'b1001;
            8'd118: song_rom_entry = 4'b0001;
            8'd119: song_rom_entry = 4'b1001;
            8'd120: song_rom_entry = 4'b0001;
            8'd121: song_rom_entry = 4'b0001;
            8'd122: song_rom_entry = 4'b0001;
            8'd123: song_rom_entry = 4'b1001;
            8'd124: song_rom_entry = 4'b0000;
            8'd125: song_rom_entry = 4'b0000;
            8'd126: song_rom_entry = 4'b1011;
            8'd127: song_rom_entry = 4'b1101;
            8'd128: song_rom_entry = 4'b0110; // --- 第 9 小节 ---
            8'd129: song_rom_entry = 4'b0110;
            8'd130: song_rom_entry = 4'b0110;
            8'd131: song_rom_entry = 4'b1110;
            8'd132: song_rom_entry = 4'b0000;
            8'd133: song_rom_entry = 4'b0000;
            8'd134: song_rom_entry = 4'b0101;
            8'd135: song_rom_entry = 4'b0101;
            8'd136: song_rom_entry = 4'b0101;
            8'd137: song_rom_entry = 4'b0101;
            8'd138: song_rom_entry = 4'b0101;
            8'd139: song_rom_entry = 4'b1101;
            8'd140: song_rom_entry = 4'b0000;
            8'd141: song_rom_entry = 4'b0000;
            8'd142: song_rom_entry = 4'b0000;
            8'd143: song_rom_entry = 4'b1001;
            8'd144: song_rom_entry = 4'b0010; // --- 第 10 小节 ---
            8'd145: song_rom_entry = 4'b1010;
            8'd146: song_rom_entry = 4'b0010;
            8'd147: song_rom_entry = 4'b1010;
            8'd148: song_rom_entry = 4'b0001;
            8'd149: song_rom_entry = 4'b1001;
            8'd150: song_rom_entry = 4'b1010;
            8'd151: song_rom_entry = 4'b1011;
            8'd152: song_rom_entry = 4'b0011;
            8'd153: song_rom_entry = 4'b0011;
            8'd154: song_rom_entry = 4'b0011;
            8'd155: song_rom_entry = 4'b1011;
            8'd156: song_rom_entry = 4'b0011;
            8'd157: song_rom_entry = 4'b1011;
            8'd158: song_rom_entry = 4'b0101;
            8'd159: song_rom_entry = 4'b1101;
            8'd160: song_rom_entry = 4'b0110; // --- 第 11 小节 ---
            8'd161: song_rom_entry = 4'b1110;
            8'd162: song_rom_entry = 4'b0001;
            8'd163: song_rom_entry = 4'b1001;
            8'd164: song_rom_entry = 4'b0010;
            8'd165: song_rom_entry = 4'b1010;
            8'd166: song_rom_entry = 4'b0011;
            8'd167: song_rom_entry = 4'b1011;
            8'd168: song_rom_entry = 4'b0010;
            8'd169: song_rom_entry = 4'b1010;
            8'd170: song_rom_entry = 4'b0001;
            8'd171: song_rom_entry = 4'b1001;
            8'd172: song_rom_entry = 4'b0110;
            8'd173: song_rom_entry = 4'b1110;
            8'd174: song_rom_entry = 4'b0110;
            8'd175: song_rom_entry = 4'b1110;
            8'd176: song_rom_entry = 4'b0010; // --- 第 12 小节 ---
            8'd177: song_rom_entry = 4'b1010;
            8'd178: song_rom_entry = 4'b0010;
            8'd179: song_rom_entry = 4'b1010;
            8'd180: song_rom_entry = 4'b0001;
            8'd181: song_rom_entry = 4'b1001;
            8'd182: song_rom_entry = 4'b0011;
            8'd183: song_rom_entry = 4'b1011;
            8'd184: song_rom_entry = 4'b0000;
            8'd185: song_rom_entry = 4'b0000;
            8'd186: song_rom_entry = 4'b0000;
            8'd187: song_rom_entry = 4'b0000;
            8'd188: song_rom_entry = 4'b0101;
            8'd189: song_rom_entry = 4'b1101;
            8'd190: song_rom_entry = 4'b0110;
            8'd191: song_rom_entry = 4'b1110;
            8'd192: song_rom_entry = 4'b0010; // --- 第 13 小节 ---
            8'd193: song_rom_entry = 4'b1010;
            8'd194: song_rom_entry = 4'b0010;
            8'd195: song_rom_entry = 4'b1010;
            8'd196: song_rom_entry = 4'b0001;
            8'd197: song_rom_entry = 4'b1001;
            8'd198: song_rom_entry = 4'b0001;
            8'd199: song_rom_entry = 4'b1001;
            8'd200: song_rom_entry = 4'b0001;
            8'd201: song_rom_entry = 4'b0001;
            8'd202: song_rom_entry = 4'b0001;
            8'd203: song_rom_entry = 4'b0001;
            8'd204: song_rom_entry = 4'b0001;
            8'd205: song_rom_entry = 4'b0001;
            8'd206: song_rom_entry = 4'b0001;
            8'd207: song_rom_entry = 4'b1001;
            8'd208: song_rom_entry = 4'b0001; // --- 第 14 小节 ---
            8'd209: song_rom_entry = 4'b0001;
            8'd210: song_rom_entry = 4'b0001;
            8'd211: song_rom_entry = 4'b0001;
            8'd212: song_rom_entry = 4'b0001;
            8'd213: song_rom_entry = 4'b0001;
            8'd214: song_rom_entry = 4'b0001;
            8'd215: song_rom_entry = 4'b1001;
            8'd216: song_rom_entry = 4'b0000;
            8'd217: song_rom_entry = 4'b0000;
            8'd218: song_rom_entry = 4'b0000;
            8'd219: song_rom_entry = 4'b0000;
            8'd220: song_rom_entry = 4'b0000;
            8'd221: song_rom_entry = 4'b0000;
            8'd222: song_rom_entry = 4'b0000;
            8'd223: song_rom_entry = 4'b0000;
            default: song_rom_entry = 4'b0000;
        endcase
    end

    wire       song_note_end = song_rom_entry[3];
    wire [2:0] song_melody   = song_rom_entry[2:0];

    // 0.1748 秒/拍 (复用 heartbeat_cnt[20:0] == 0，224 步循环总长约 39.2 秒)
    // 吐音释音槽：音符最后一拍的最后 21.8 ms 进行静音释音，保证同音连续弹奏清晰清脆
    wire song_tick   = (heartbeat_cnt[20:0] == 21'd0);
    wire note_gap    = song_note_end && (heartbeat_cnt[20:18] == 3'b111);
    wire [2:0] song_sound = note_gap ? 3'd0 : song_melody;

    reg [2:0] last_song_note;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            song_step      <= 8'd0;
            last_song_note <= 3'd1;
        end else begin
            if (song_melody != 3'd0) begin
                last_song_note <= song_melody;
            end
            if (song_tick) begin
                if (song_step == 8'd223) begin
                    song_step <= 8'd0; // 224 步完整奏毕，循环回起点
                end else begin
                    song_step <= song_step + 8'd1;
                end
            end
        end
    end

    wire [2:0] active_sensor  = (AUTO_PLAY != 0 && song_sound != 3'd0) ? song_sound : manual_sensor;
    wire [2:0] oled_disp_note = (AUTO_PLAY != 0) ? last_song_note : piano_note_debug;

    //-------------------------------------------------------------------------
    // 5. 实例化指尖琴核心系统
    //-------------------------------------------------------------------------
    finger_piano_stage2_top #(
        .PRESSURE_CH0_ZERO (15'd20000),
        .PRESSURE_CH1_ZERO (15'd20000),
        .PRESSURE_CH2_ZERO (15'd20000),
        .PRESSURE_INVERT   (1)
    ) u_piano (
        .clk              (clk),
        .rst_n            (rst_n),
        .sensor_async     (active_sensor),
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
        .adc_ch2_raw      (piano_adc_ch2_raw),
        .pressure_ch0     (piano_pressure_ch0),
        .pressure_ch1     (piano_pressure_ch1),
        .pressure_ch2     (piano_pressure_ch2),
        .pressure_valid   (piano_pressure_valid)
    );

    //-------------------------------------------------------------------------
    // 6. SSD1306 OLED 主控制器与 I2C 发送器
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
        .note_code          (oled_disp_note),
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
    // 7. 调试引脚与防修剪汇聚 (保持外部 UCF 管脚连接完整，防止无用修剪警告)
    //-------------------------------------------------------------------------
    assign uart_tx = 1'b1;

    assign dbg_unused = oled_error ^ (^sensor_async);

endmodule
