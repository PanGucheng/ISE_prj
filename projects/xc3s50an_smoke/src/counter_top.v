// Toolchain smoke test only. No board-specific pin mapping.
module counter_top (
    input wire clk,
    output reg [7:0] count = 8'h00
);
    always @(posedge clk) begin
        count <= count + 8'd1;
    end
endmodule
