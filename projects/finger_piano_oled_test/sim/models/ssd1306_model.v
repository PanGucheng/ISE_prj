`timescale 1ns / 1ps

//=============================================================================
// ssd1306_model.v
// SSD1306 OLED I2C 从机高保真行为仿真模型
//
// 验证特性：
//   1. 监听 7-bit 地址 0x3C（线上 8-bit 地址 0x78），正常时在第 9 拍返回 ACK；
//   2. 支持 inject_nack 故障注入：置 1 时故意返回 NACK，验证控制器的停机与报错机制；
//   3. 严格核对前 27 字节初始化命令序列与 STM32 参考驱动完全一致；
//   4. 实时跟踪并断言 memory_addressing_mode == 2'b10（Page Addressing Mode）；
//   5. 校验 Page / Column 寻址协议（0xB0~0xB7, 0x00~0x0F, 0x10~0x1F）；
//   6. 维护完整 8 页 x 128 列显存 gram[7:0][127:0] 供 Testbench 校验点阵。
//=============================================================================

module ssd1306_model #(
    parameter [6:0] DEVICE_ADDR = 7'h3C
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       inject_nack, // 故障注入：1 时不响应 ACK (保持高阻 NACK)
    inout  wire       scl,
    inout  wire       sda,

    // 观测与校验状态
    output reg        init_seq_error,
    output reg        mode_error,
    output reg        protocol_error,
    output reg [1:0]  memory_addressing_mode,
    output reg [7:0]  last_cmd,
    output integer    cmd_count,
    output integer    data_count
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
    reg        addr_received;
    reg        is_control_byte;
    reg        is_data_stream; // 0 = 命令, 1 = 数据
    reg [2:0]  curr_page;
    reg [6:0]  curr_col;

    // 期望的 27 字节 STM32 初始化序列
    reg [7:0] expected_init_cmd [0:26];
    initial begin
        expected_init_cmd[0]  = 8'hAE; // Display OFF
        expected_init_cmd[1]  = 8'h20; // Set Memory Addressing Mode
        expected_init_cmd[2]  = 8'h10; // Page Addressing Mode (0x10)
        expected_init_cmd[3]  = 8'hB0; // Page Start Address 0
        expected_init_cmd[4]  = 8'hC8; // COM Output Scan Direction Remapped
        expected_init_cmd[5]  = 8'h00; // Column Start Low 0
        expected_init_cmd[6]  = 8'h10; // Column Start High 0
        expected_init_cmd[7]  = 8'h40; // Display Start Line 0
        expected_init_cmd[8]  = 8'h81; // Contrast Control
        expected_init_cmd[9]  = 8'hDF; // Contrast Value
        expected_init_cmd[10] = 8'hA1; // Segment Re-map A1
        expected_init_cmd[11] = 8'hA6; // Normal Display
        expected_init_cmd[12] = 8'hA8; // Multiplex Ratio
        expected_init_cmd[13] = 8'h3F; // 64 MUX
        expected_init_cmd[14] = 8'hA4; // Entire Display ON resume
        expected_init_cmd[15] = 8'hD3; // Display Offset
        expected_init_cmd[16] = 8'h00; // Offset 0
        expected_init_cmd[17] = 8'hD5; // Display Clock Divide / Osc Freq
        expected_init_cmd[18] = 8'hF0; // Max Freq
        expected_init_cmd[19] = 8'hD9; // Pre-charge Period
        expected_init_cmd[20] = 8'h22; // Phase 1 = 2, Phase 2 = 2
        expected_init_cmd[21] = 8'hDA; // COM Pins Config
        expected_init_cmd[22] = 8'h12; // Alternative COM pins
        expected_init_cmd[23] = 8'hDB; // VCOMH Deselect Level
        expected_init_cmd[24] = 8'h20; // 0.77 x VCC
        expected_init_cmd[25] = 8'h8D; // Charge Pump Setting
        expected_init_cmd[26] = 8'h14; // Enable Charge Pump
    end

    // 显存 8 页 x 128 列
    reg [7:0] gram [0:7][0:127];

    integer p, c;
    initial begin
        for (p = 0; p < 8; p = p + 1)
            for (c = 0; c < 128; c = c + 1)
                gram[p][c] = 8'h00;
    end

    // 跟踪两字节命令状态
    reg [7:0] pending_cmd;
    reg       has_cmd_arg;

    always @(posedge clk) begin
        if (rst) begin
            byte_active            <= 1'b0;
            bit_cnt                <= 4'd0;
            shift_reg              <= 8'h00;
            sda_drive              <= 1'b0;
            addr_matched           <= 1'b0;
            addr_received          <= 1'b0;
            is_control_byte        <= 1'b1;
            is_data_stream         <= 1'b0;
            curr_page              <= 3'd0;
            curr_col               <= 7'd0;
            cmd_count              <= 0;
            data_count             <= 0;
            last_cmd               <= 8'h00;
            init_seq_error         <= 1'b0;
            mode_error             <= 1'b0;
            protocol_error         <= 1'b0;
            memory_addressing_mode <= 2'b00;
            pending_cmd            <= 8'h00;
            has_cmd_arg            <= 1'b0;
        end else begin
            // START 检测
            if (start_c) begin
                byte_active     <= 1'b1;
                bit_cnt         <= 4'd0;
                shift_reg       <= 8'h00;
                sda_drive       <= 1'b0;
                addr_matched    <= 1'b0;
                addr_received   <= 1'b0;
                is_control_byte <= 1'b1;
            end

            // STOP 检测
            if (stop_c) begin
                byte_active     <= 1'b0;
                sda_drive       <= 1'b0;
                addr_matched    <= 1'b0;
                addr_received   <= 1'b0;
                is_control_byte <= 1'b1;
            end

            // SCL 上升沿：移位采样
            if (scl_rise && byte_active) begin
                if (bit_cnt < 8) begin
                    shift_reg <= {shift_reg[6:0], sda};
                    bit_cnt   <= bit_cnt + 4'd1;
                end else begin
                    bit_cnt <= 4'd9; // ACK 槽
                end
            end

            // SCL 下降沿：驱动 ACK 或处理字节
            if (scl_fall && byte_active) begin
                if (bit_cnt == 4'd8) begin
                    // 8 位接收完毕：若接收的是首个从机地址字节
                    if (!addr_received) begin
                        if (shift_reg[7:1] == DEVICE_ADDR && shift_reg[0] == 1'b0) begin
                            addr_matched <= 1'b1;
                            sda_drive    <= inject_nack ? 1'b0 : 1'b1;
                        end else begin
                            addr_matched <= 1'b0;
                            sda_drive    <= 1'b0; // 地址不匹配，NACK
                        end
                    end else begin
                        // 正常数据/控制字节：若地址已匹配且未注入故障，则提供 ACK
                        if (addr_matched && !inject_nack) begin
                            sda_drive <= 1'b1; // ACK (拉低 SDA)
                        end else begin
                            sda_drive <= 1'b0; // NACK
                        end
                    end
                end else if (bit_cnt == 4'd9) begin
                    // ACK 周期结束：释放 SDA
                    sda_drive <= 1'b0;
                    bit_cnt   <= 4'd0;

                    if (!addr_received) begin
                        // 此时仅仅完成了地址字节的握手，记录地址已接收，不作控制/数据解析
                        addr_received <= 1'b1;
                    end else if (addr_matched && !inject_nack) begin
                        // 这是地址之后的数据或控制字节
                        if (is_control_byte) begin
                            // 控制字节：0x00 (连续命令流) 或 0x40 (连续数据流)
                            if (shift_reg == 8'h00) begin
                                is_data_stream  <= 1'b0;
                                is_control_byte <= 1'b0;
                            end else if (shift_reg == 8'h40) begin
                                is_data_stream  <= 1'b1;
                                is_control_byte <= 1'b0;
                            end else begin
                                $display("[%t] [SSD1306_MODEL] WARNING: Unrecognized control byte: 0x%02X", $time, shift_reg);
                                protocol_error <= 1'b1;
                            end
                        end else begin
                            // 实际数据或命令字节
                            if (is_data_stream) begin
                                // 写入当前页面的列显存
                                gram[curr_page][curr_col] <= shift_reg;
                                data_count                <= data_count + 1;
                                if (curr_col < 7'd127)
                                    curr_col <= curr_col + 1'b1;
                                else
                                    curr_col <= 7'd0; // 页面内回绕
                            end else begin
                                // 命令解析与严格校验
                                last_cmd <= shift_reg;

                                // 1. 初始化 27 字节严格比对
                                if (cmd_count < 27) begin
                                    if (shift_reg !== expected_init_cmd[cmd_count]) begin
                                        $display("[%t] [SSD1306_MODEL] ERROR: Init command mismatch at idx %0d! Expected 0x%02X, got 0x%02X",
                                                 $time, cmd_count, expected_init_cmd[cmd_count], shift_reg);
                                        init_seq_error <= 1'b1;
                                    end
                                end

                                // 2. 寻址模式与双字节命令解析
                                if (has_cmd_arg) begin
                                    if (pending_cmd == 8'h20) begin
                                        if (shift_reg == 8'h10 || shift_reg == 8'h02) begin
                                            memory_addressing_mode <= 2'b10;
                                        end else begin
                                            memory_addressing_mode <= shift_reg[1:0];
                                            $display("[%t] [SSD1306_MODEL] ERROR: Memory addressing mode not 0x10 (Page Mode)! Got 0x%02X",
                                                     $time, shift_reg);
                                            mode_error <= 1'b1;
                                        end
                                    end
                                    has_cmd_arg <= 1'b0;
                                end else begin
                                    if (shift_reg == 8'h20 || shift_reg == 8'h81 || shift_reg == 8'hA8 ||
                                        shift_reg == 8'hD3 || shift_reg == 8'hD5 || shift_reg == 8'hD9 ||
                                        shift_reg == 8'hDA || shift_reg == 8'hDB || shift_reg == 8'h8D) begin
                                        pending_cmd <= shift_reg;
                                        has_cmd_arg <= 1'b1;
                                    end

                                    // 页寻址单字节命令解析
                                    if ((shift_reg & 8'hF8) == 8'hB0) begin
                                        curr_page <= shift_reg[2:0]; // 设置页 0..7
                                    end else if ((shift_reg & 8'hF0) == 8'h00) begin
                                        curr_col[3:0] <= shift_reg[3:0]; // 设置列低4位
                                    end else if ((shift_reg & 8'hF0) == 8'h10) begin
                                        curr_col[6:4] <= shift_reg[2:0]; // 设置列高3位 (0..127)
                                    end
                                end

                                cmd_count <= cmd_count + 1;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
