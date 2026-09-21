`timescale 1ns / 1ps

//=============================================================================
// ssd1306_model.v
// SSD1306 OLED I2C 从机行为仿真模型（仅用于仿真，非综合）
//
// 功能：
//   - 监听 7-bit 地址 0x3C（线上 8-bit 地址 0x78），匹配时提供 ACK（SDA 拉低）；
//   - 接收控制字节（0x00 命令流 / 0x40 数据流）；
//   - 维护 8 页 * 128 列的虚拟显存 gram[7:0][127:0]；
//   - 统计命令总数与数据总数，供 Testbench 断言校验。
//=============================================================================

module ssd1306_model #(
    parameter [6:0] DEVICE_ADDR = 7'h3C
) (
    input  wire clk,
    input  wire rst,
    inout  wire scl,
    inout  wire sda
);

    reg sda_drive;
    assign sda = sda_drive ? 1'b0 : 1'bz;

    // 同步边沿检测
    reg scl_q, sda_q;
    always @(posedge clk) begin
        scl_q <= scl;
        sda_q <= sda;
    end

    wire scl_rise = (scl === 1'b1) && (scl_q !== 1'b1);
    wire scl_fall = (scl !== 1'b1) && (scl_q === 1'b1);
    wire start_c  = (sda === 1'b0) && (sda_q === 1'b1) && (scl === 1'b1);
    wire stop_c   = (sda === 1'b1) && (sda_q === 1'b0) && (scl === 1'b1);

    // 状态与寄存器
    reg        byte_active;
    reg [3:0]  bit_cnt;
    reg [7:0]  shift_reg;
    reg        addr_matched;
    reg        is_control_byte;
    reg        is_data_stream; // 0 = 命令, 1 = 数据
    reg [2:0]  curr_page;
    reg [6:0]  curr_col;

    // 观测统计
    integer    cmd_count;
    integer    data_count;
    reg [7:0]  last_cmd;
    reg [7:0]  gram [0:7][0:127];

    integer p, c;
    initial begin
        for (p = 0; p < 8; p = p + 1)
            for (c = 0; c < 128; c = c + 1)
                gram[p][c] = 8'h00;
    end

    always @(posedge clk) begin
        if (rst) begin
            byte_active     = 1'b0;
            bit_cnt         = 4'd0;
            shift_reg       = 8'h00;
            sda_drive       = 1'b0;
            addr_matched    = 1'b0;
            is_control_byte = 1'b1;
            is_data_stream  = 1'b0;
            curr_page       = 3'd0;
            curr_col        = 7'd0;
            cmd_count       = 0;
            data_count      = 0;
            last_cmd        = 8'h00;
        end else begin
            //-----------------------------------------------------------------
            // START / STOP 检测
            //-----------------------------------------------------------------
            if (start_c) begin
                byte_active     = 1'b1;
                bit_cnt         = 4'd0;
                shift_reg       = 8'h00;
                sda_drive       = 1'b0;
                addr_matched    = 1'b0;
                is_control_byte = 1'b1;
            end
            if (stop_c) begin
                byte_active     = 1'b0;
                sda_drive       = 1'b0;
                addr_matched    = 1'b0;
                is_control_byte = 1'b1;
            end

            //-----------------------------------------------------------------
            // SCL 上升沿：移位采样
            //-----------------------------------------------------------------
            if (scl_rise && byte_active) begin
                if (bit_cnt < 8) begin
                    shift_reg = {shift_reg[6:0], sda};
                    bit_cnt   = bit_cnt + 4'd1;
                end else begin
                    bit_cnt = 4'd9; // ACK 槽
                end
            end

            //-----------------------------------------------------------------
            // SCL 下降沿：驱动 ACK 或处理字节
            //-----------------------------------------------------------------
            if (scl_fall && byte_active) begin
                if (bit_cnt == 4'd8) begin
                    // 8 位接收完毕：若地址匹配或正在接收首个地址字节
                    if (!addr_matched) begin
                        if (shift_reg[7:1] == DEVICE_ADDR && shift_reg[0] == 1'b0) begin
                            addr_matched = 1'b1;
                            sda_drive    = 1'b1; // 发送 ACK (拉低 SDA)
                        end else begin
                            sda_drive = 1'b0; // NACK
                        end
                    end else begin
                        sda_drive = 1'b1; // 数据或控制字节一律 ACK
                    end
                end else if (bit_cnt == 4'd9) begin
                    // ACK 周期结束：释放 SDA
                    sda_drive = 1'b0;
                    bit_cnt   = 4'd0;

                    if (addr_matched) begin
                        if (is_control_byte) begin
                            // 区分 0x00 (命令流) 与 0x40 (数据流)
                            if (shift_reg == 8'h00) begin
                                is_data_stream  = 1'b0;
                                is_control_byte = 1'b0;
                            end else if (shift_reg == 8'h40) begin
                                is_data_stream  = 1'b1;
                                is_control_byte = 1'b0;
                            end
                        end else begin
                            // 正常内容字节
                            if (is_data_stream) begin
                                // 写入当前页面的列显存
                                gram[curr_page][curr_col] = shift_reg;
                                data_count = data_count + 1;
                                if (curr_col < 7'd127)
                                    curr_col = curr_col + 1'b1;
                            end else begin
                                // 命令解析
                                cmd_count = cmd_count + 1;
                                last_cmd  = shift_reg;
                                if ((shift_reg & 8'hF8) == 8'hB0) begin
                                    curr_page = shift_reg[2:0]; // 设置当前页
                                end else if ((shift_reg & 8'hF0) == 8'h00) begin
                                    curr_col[3:0] = shift_reg[3:0];
                                end else if ((shift_reg & 8'hF0) == 8'h10) begin
                                    curr_col[6:4] = shift_reg[2:0];
                                end
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
