//=============================================================================
// key_sync.v
// 7 路外部数字输入的两级触发器同步器。
//
// 外部压力传感器调理/电平判决电路的输出相对 clk 是异步信号，直接进入
// 后续逻辑会引入亚稳态。本模块用两级触发器把输入同步到 clk 域，第一级
// 可能进入亚稳态，第二级给出稳定值。
//
// 注意：本模块只做同步，不做去抖；去抖（数字稳定滤波）由 key_filter 完成。
// 本模块不依赖时钟频率，因此不需要 SYS_CLK_HZ 参数。
//=============================================================================

module key_sync #(
    parameter integer WIDTH = 7
) (
    input  wire             clk,
    input  wire             rst_n_sync,   // 内部同步复位（低有效，来自 reset_sync）
    input  wire [WIDTH-1:0] async_in,     // 异步输入（已完成极性归一化）
    (* ASYNC_REG = "TRUE" *)              // 与第一级同属性，保持同步链相邻
    output reg  [WIDTH-1:0] sync_out      // 同步后的输出
);

    // ASYNC_REG 提示 XST/PAR 把这条同步链的两级触发器放在相邻位置，
    // 缩短亚稳态传播窗口。（纯属性，不改变逻辑与端口。）
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] meta;   // 第一级：可能亚稳

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            meta     <= {WIDTH{1'b0}};
            sync_out <= {WIDTH{1'b0}};
        end else begin
            meta     <= async_in;
            sync_out <= meta;
        end
    end

endmodule
