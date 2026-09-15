//=============================================================================
// sensor_code_filter.v
// 3-bit 码字整体原子稳定滤波(P2 计划 Commit B,本计划最关键新模块)。
//
// 为什么不用逐 bit 滤波:key_in 时代的 key_filter 对每个 bit 独立计数、
// 独立更新,对七个互相独立的按键是合理的。但真实硬件的 3 个 LM393 输出
// 共同组成**一个二进制码字**:手指按压不同步、比较器翻转时刻不同、同步
// 延迟与模拟噪声,会使多 bit 变化(如 001 -> 111)短暂经过 011/101 等
// 中间码。逐 bit 独立滤波可能把中间码提交为稳定结果,错误播放 E4/G4。
//
// 因此本模块采用 whole-vector atomic filtering:整个 3-bit 向量连续保持
// 相同值达到门限后,三个 bit **一次性**更新:
//
//   code_sync == stable_q            -> 计数清零,candidate 回同步到 stable
//   code_sync != stable_q:
//     code_sync != candidate_q       -> 记录新 candidate,计数重新开始
//     code_sync == candidate_q       -> 继续累计;
//                                       连续观察到同一向量 STABLE_CYCLES 次
//                                       后,stable_q <= candidate(一次更新)
//
// 精确语义(与 key_filter 的去抖时间定义一致,off-by-one 由 TB 锁死):
//   第 1 次观察到候选向量时 count 置 1,此后每连续观察一拍 +1;
//   在第 N 次连续观察的沿上(count 读数 = N-1 >= STABLE_CYCLES-1)
//   执行更新 —— 即 STABLE_CYCLES-1 拍不更新,第 STABLE_CYCLES 拍更新。
//
//   STABLE_CYCLES = max(1, (SYS_CLK_HZ/1000) * STABLE_MS)
//   与 key_filter 完全相同的去抖时间定义(12 MHz、10 ms -> 120000,
//   FP_FILTER_CNT_WIDTH=24 足够)。
//
// ENABLE = 0:bypass,code_stable = code_sync,综合为纯直通,不产生任何
// 计数器(generate else 分支,与 key_filter 同风格)。
//
// 复位后 stable_q = 000(静音)。纯 Verilog-2001,唯一时钟 clk。
//=============================================================================

`include "finger_piano_cfg.vh"

module sensor_code_filter #(
    parameter integer SYS_CLK_HZ = `SYS_CLK_HZ,
    parameter integer STABLE_MS  = `KEY_STABLE_MS,
    parameter integer ENABLE     = `KEY_FILTER_ENABLE,
    parameter integer CNT_WIDTH  = `FP_FILTER_CNT_WIDTH
) (
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire [2:0] code_sync,     // 已同步(key_sync 之后)的 3-bit 编码
    output wire [2:0] code_stable    // 稳定的 3-bit 编码
);

    // 与 key_filter 相同的容量条件:(SYS_CLK_HZ/1000)*STABLE_MS <= 2**CNT_WIDTH
    localparam integer STABLE_CYCLES_RAW = (SYS_CLK_HZ / 1000) * STABLE_MS;
    localparam integer STABLE_CYCLES     =
        (STABLE_CYCLES_RAW < 1) ? 1 : STABLE_CYCLES_RAW;

    generate
        if (ENABLE != 0) begin : GEN_FILTER

            reg [2:0]            stable_q;     // 当前稳定码字
            reg [2:0]            candidate_q;  // 候选码字(整个向量)
            reg [CNT_WIDTH-1:0]  stable_count; // 候选连续被观察到的次数-1

            always @(posedge clk or negedge rst_n_sync) begin
                if (!rst_n_sync) begin
                    stable_q     <= 3'b000;               // 复位 = 静音
                    candidate_q  <= 3'b000;
                    stable_count <= {CNT_WIDTH{1'b0}};
                end else if (code_sync == stable_q) begin
                    // 与稳定值一致:计数清零,candidate 同步回 stable
                    stable_count <= {CNT_WIDTH{1'b0}};
                    candidate_q  <= stable_q;
                end else if (code_sync != candidate_q) begin
                    // 新候选:记录整个向量,计数重新开始(首次观察记 1)
                    candidate_q  <= code_sync;
                    stable_count <= {{(CNT_WIDTH-1){1'b0}}, 1'b1};
                end else begin
                    // 连续观察同一候选:累计,达到门限一次性更新
                    if (stable_count >= STABLE_CYCLES - 1) begin
                        stable_q     <= candidate_q;      // 三个 bit 一次更新
                        stable_count <= {CNT_WIDTH{1'b0}};
                    end else begin
                        stable_count <= stable_count + 1'b1;
                    end
                end
            end

            assign code_stable = stable_q;

        end else begin : GEN_BYPASS

            // 关闭滤波:纯直通,零计数器
            assign code_stable = code_sync;

        end
    endgenerate

endmodule
