//=============================================================================
// key_filter.v
// 参数化数字稳定滤波（去抖）：输入电平必须持续 STABLE_MS 毫秒不变，
// 才更新一次输出；任何短于该时间的毛刺都被完全忽略。
//
// 参数：
//   SYS_CLK_HZ  系统时钟频率（Hz），默认取 finger_piano_cfg.vh 的宏
//   STABLE_MS   稳定时间（ms），默认 10 ms
//   ENABLE      1 = 开启滤波；0 = 关闭（纯直通，不产生任何计数器）
//   WIDTH       按键路数（本工程固定 7，由顶层显式传入）
//
// 实现要点：
//   - 每一路按键各自一个计数器，彼此独立；
//   - 只有唯一的时钟 clk，计数器在 posedge clk 上递增，没有门控时钟；
//   - 使用标准 Verilog-2001 写法：先独立声明 genvar，再用 generate/for；
//   - ENABLE = 0 时用 generate 的 else 分支直接 assign，综合结果为直通路径。
//=============================================================================

`include "finger_piano_cfg.vh"

module key_filter #(
    parameter integer SYS_CLK_HZ = `SYS_CLK_HZ,
    parameter integer STABLE_MS  = `KEY_STABLE_MS,
    parameter integer ENABLE     = `KEY_FILTER_ENABLE,
    parameter integer WIDTH      = 7
) (
    input  wire             clk,
    input  wire             rst_n_sync,     // 内部同步复位（低有效，来自 reset_sync）
    input  wire [WIDTH-1:0] key_sync_in,    // 已同步的按键输入
    output wire [WIDTH-1:0] key_stable      // 稳定后的按键输出
);

    // 需要的稳定周期数。SYS_CLK_HZ/1000 先取整到 kHz 再乘 ms，
    // 误差小于 1 us，对本用途无影响；至少为 1，避免退化为 0 周期。
    localparam integer STABLE_CYCLES_RAW = (SYS_CLK_HZ / 1000) * STABLE_MS;
    localparam integer STABLE_CYCLES     = (STABLE_CYCLES_RAW < 1) ? 1 : STABLE_CYCLES_RAW;

    genvar i;

    generate
        if (ENABLE != 0) begin : GEN_FILTER

            for (i = 0; i < WIDTH; i = i + 1) begin : GEN_KEY_FILTER

                reg [`FP_FILTER_CNT_WIDTH-1:0] cnt;       // 偏离当前稳定值的持续时间
                reg                           stable_q;  // 当前稳定电平

                always @(posedge clk or negedge rst_n_sync) begin
                    if (!rst_n_sync) begin
                        cnt      <= {`FP_FILTER_CNT_WIDTH{1'b0}};
                        stable_q <= 1'b0;
                    end else if (key_sync_in[i] != stable_q) begin
                        if (cnt >= (STABLE_CYCLES - 1)) begin
                            // 输入持续偏离达到稳定时间：接受新电平
                            cnt      <= {`FP_FILTER_CNT_WIDTH{1'b0}};
                            stable_q <= key_sync_in[i];
                        end else begin
                            cnt <= cnt + 1'b1;
                        end
                    end else begin
                        // 输入与稳定值一致：计数器清零（毛刺不会累积）
                        cnt <= {`FP_FILTER_CNT_WIDTH{1'b0}};
                    end
                end

                assign key_stable[i] = stable_q;

            end

        end else begin : GEN_BYPASS

            // 关闭滤波：直通，零计数器资源
            assign key_stable = key_sync_in;

        end
    endgenerate

endmodule
