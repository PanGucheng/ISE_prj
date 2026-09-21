//=============================================================================
// reset_sync.v
// 复位同步器：外部 rst_n 异步拉低、同步释放。
//=============================================================================

module reset_sync (
    input  wire clk,          // 唯一系统时钟
    input  wire rst_n,        // 外部异步低有效复位
    output wire rst_n_sync    // 内部低有效复位（同步释放）
);

    (* ASYNC_REG = "TRUE" *) reg rst_meta;
    (* ASYNC_REG = "TRUE" *) reg rst_sync_q;

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
