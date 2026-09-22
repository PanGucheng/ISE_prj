//=============================================================================
// uart_tx.v
// 简单 Verilog-2001 UART 发送器 (8N1, TX only, 纯单一时钟域)
//
// 参数:
//   CLK_HZ   : 系统时钟频率 (默认 12000000 Hz)
//   BAUD_RATE: 目标波特率 (默认 115200 baud)
//
// 12 MHz / 115200:
//   每 bit 周期数 = 12000000 / 115200 = 104 拍 (104.167 拍, 误差仅 +0.16%)
//   每帧: 1 起始位 (0) + 8 数据位 (LSB first) + 1 停止位 (1)
//=============================================================================

module uart_tx #(
    parameter integer CLK_HZ    = 12000000,
    parameter integer BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [7:0] tx_byte,
    input  wire       tx_valid,
    output reg        tx_ready,
    output reg        tx_pin
);

    localparam integer BIT_PERIOD = CLK_HZ / BAUD_RATE;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg [1:0] state;
    reg [7:0] baud_cnt;
    reg [2:0] bit_idx;
    reg [7:0] tx_shift;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            state    <= S_IDLE;
            baud_cnt <= 8'd0;
            bit_idx  <= 3'd0;
            tx_shift <= 8'h00;
            tx_ready <= 1'b1;
            tx_pin   <= 1'b1;
        end else begin
            case (state)
                S_IDLE: begin
                    baud_cnt <= 8'd0;
                    bit_idx  <= 3'd0;
                    tx_pin   <= 1'b1;
                    if (tx_valid && tx_ready) begin
                        tx_shift <= tx_byte;
                        tx_ready <= 1'b0;
                        tx_pin   <= 1'b0; // Start bit
                        state    <= S_START;
                    end else begin
                        tx_ready <= 1'b1;
                    end
                end

                S_START: begin
                    tx_pin <= 1'b0;
                    if (baud_cnt == BIT_PERIOD - 1) begin
                        baud_cnt <= 8'd0;
                        tx_pin   <= tx_shift[0]; // LSB
                        tx_shift <= {1'b0, tx_shift[7:1]};
                        bit_idx  <= 3'd0;
                        state    <= S_DATA;
                    end else begin
                        baud_cnt <= baud_cnt + 8'd1;
                    end
                end

                S_DATA: begin
                    if (baud_cnt == BIT_PERIOD - 1) begin
                        baud_cnt <= 8'd0;
                        if (bit_idx == 3'd7) begin
                            tx_pin <= 1'b1; // Stop bit
                            state  <= S_STOP;
                        end else begin
                            tx_pin   <= tx_shift[0];
                            tx_shift <= {1'b0, tx_shift[7:1]};
                            bit_idx  <= bit_idx + 3'd1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 8'd1;
                    end
                end

                S_STOP: begin
                    tx_pin <= 1'b1;
                    if (baud_cnt == BIT_PERIOD - 1) begin
                        baud_cnt <= 8'd0;
                        tx_ready <= 1'b1;
                        state    <= S_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt + 8'd1;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
