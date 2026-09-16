//=============================================================================
// dac_diag_source.v
// P9 MCP4725 诊断样点源(板级排故专用,不可替代正式音频链)。
//
// compile-time 参数 TEST_MODE(P9 §13,不加 mode pin):
//   0 = 0x800 中点 DC(理论 VOUT ~ VDD/2,实测由用户完成)
//   1 = 0x400 低值 DC
//   2 = 0xC00 高值 DC
//   3 = 1 kHz / 8 kS/s 八点周期波形
//
// 节拍(P9 §16):12 MHz / 1500 = 8 kS/s 单周期 clock-enable,**不产生**
// clk_8k 之类的第二时钟域。
// 1 kHz 波形(P9 §15):8 样点 = 1 kHz;常量按 round(1792*sin(2*pi*k/8))
// 离线复核(1792*0.70710678 = 1267.94 -> 1268):
//   2048, 3316, 3840, 3316, 2048, 780, 256, 780
// (计划 §15 示例中的 3315/781 为近似值,以本复核值为准,TB 独立验证。)
//
// DC 值(0x400/0x800/0xC00)是纯常量驱动,只用于确认 VOUT 单调与 DAC
// 写链路,不代表任何音频或校准结论(P9 §14)。
//=============================================================================

module dac_diag_source #(
    parameter integer SYS_CLK_HZ     = 12000000,
    parameter integer SAMPLE_RATE_HZ = 8000,
    parameter integer TEST_MODE      = 0
) (
    input  wire        clk,
    input  wire        rst_n_sync,
    output reg  [11:0] dac_code,
    output reg         dac_code_valid
);

    localparam integer SAMPLE_DIV = SYS_CLK_HZ / SAMPLE_RATE_HZ;   // 1500 @ 12 MHz

    reg [10:0] sample_cnt;
    reg [2:0]  wave_idx;

    // 1 kHz 八点波形(离线复核值,见文件头)
    function [11:0] wave_sample;
        input [2:0] k;
        begin
            case (k)
                3'd0:    wave_sample = 12'd2048;
                3'd1:    wave_sample = 12'd3316;
                3'd2:    wave_sample = 12'd3840;
                3'd3:    wave_sample = 12'd3316;
                3'd4:    wave_sample = 12'd2048;
                3'd5:    wave_sample = 12'd780;
                3'd6:    wave_sample = 12'd256;
                default: wave_sample = 12'd780;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            sample_cnt     <= 11'd0;
            wave_idx       <= 3'd0;
            dac_code       <= 12'h800;
            dac_code_valid <= 1'b0;
        end else begin
            dac_code_valid <= 1'b0;
            if (sample_cnt == SAMPLE_DIV - 1) begin
                sample_cnt     <= 11'd0;
                dac_code_valid <= 1'b1;
                if (TEST_MODE == 3) begin
                    dac_code <= wave_sample(wave_idx);
                    wave_idx <= wave_idx + 3'd1;
                end else if (TEST_MODE == 1) begin
                    dac_code <= 12'h400;
                end else if (TEST_MODE == 2) begin
                    dac_code <= 12'hC00;
                end else begin
                    dac_code <= 12'h800;
                end
            end else begin
                sample_cnt <= sample_cnt + 11'd1;
            end
        end
    end

endmodule
