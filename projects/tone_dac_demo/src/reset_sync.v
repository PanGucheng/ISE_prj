//=============================================================================
// reset_sync.v
// 复位同步器：外部 rst_n 异步拉低、同步释放。
//
// 外部复位若来自 RC + 上拉，其释放沿相对 clk 是异步的；直接把 rst_n 送到
// 各触发器会在释放瞬间造成不同触发器在不同时钟沿退出复位。本模块用两级
// 触发器把释放沿同步到 clk，异步拉低保证复位立即生效。
//
// 内部所有模块统一使用本模块输出的 rst_n_sync（低有效）。
//=============================================================================

module reset_sync (
    input  wire clk,          // 唯一系统时钟
    input  wire rst_n,        // 外部异步低有效复位
    output wire rst_n_sync    // 内部低有效复位（同步释放）
);

    // ASYNC_REG 提示 XST/PAR 把这条同步链的两级触发器放在相邻位置，
    // 缩短亚稳态传播窗口。（纯属性，不改变逻辑与端口。）
    (* ASYNC_REG = "TRUE" *) reg rst_meta;      // 第一级：异步拉低
    (* ASYNC_REG = "TRUE" *) reg rst_sync_q;    // 第二级：同步释放

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_meta   <= 1'b0;
            rst_sync_q <= 1'b0;
        end else begin
            rst_meta   <= 1'b1;
            rst_sync_q <= rst_meta;
        end
    end

    assign rst_n_sync = rst_sync_q;

endmodule
