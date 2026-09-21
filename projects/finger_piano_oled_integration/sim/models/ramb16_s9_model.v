`timescale 1ns / 1ps

module RAMB16_S9 #(
    parameter [255:0] INIT_00 = 256'h0,
    parameter [255:0] INIT_01 = 256'h0,
    parameter [255:0] INIT_02 = 256'h0,
    parameter [255:0] INIT_03 = 256'h0,
    parameter [255:0] INIT_04 = 256'h0,
    parameter [255:0] INIT_05 = 256'h0,
    parameter [255:0] INIT_06 = 256'h0,
    parameter [255:0] INIT_07 = 256'h0,
    parameter [255:0] INIT_08 = 256'h0,
    parameter [255:0] INIT_09 = 256'h0,
    parameter [255:0] INIT_0A = 256'h0,
    parameter [255:0] INIT_0B = 256'h0,
    parameter [255:0] INIT_0C = 256'h0,
    parameter [255:0] INIT_0D = 256'h0,
    parameter [255:0] INIT_0E = 256'h0,
    parameter [255:0] INIT_0F = 256'h0,
    parameter [255:0] INIT_10 = 256'h0,
    parameter [255:0] INIT_11 = 256'h0,
    parameter [255:0] INIT_12 = 256'h0,
    parameter [255:0] INIT_13 = 256'h0,
    parameter [255:0] INIT_14 = 256'h0,
    parameter [255:0] INIT_15 = 256'h0,
    parameter [255:0] INIT_16 = 256'h0,
    parameter [255:0] INIT_17 = 256'h0,
    parameter [255:0] INIT_18 = 256'h0,
    parameter [255:0] INIT_19 = 256'h0,
    parameter [255:0] INIT_1A = 256'h0,
    parameter [255:0] INIT_1B = 256'h0,
    parameter [255:0] INIT_1C = 256'h0,
    parameter [255:0] INIT_1D = 256'h0,
    parameter [255:0] INIT_1E = 256'h0,
    parameter [255:0] INIT_1F = 256'h0,
    parameter [255:0] INIT_20 = 256'h0,
    parameter [255:0] INIT_21 = 256'h0,
    parameter [255:0] INIT_22 = 256'h0,
    parameter [255:0] INIT_23 = 256'h0,
    parameter [255:0] INIT_24 = 256'h0,
    parameter [255:0] INIT_25 = 256'h0,
    parameter [255:0] INIT_26 = 256'h0,
    parameter [255:0] INIT_27 = 256'h0,
    parameter [255:0] INIT_28 = 256'h0,
    parameter [255:0] INIT_29 = 256'h0,
    parameter [255:0] INIT_2A = 256'h0,
    parameter [255:0] INIT_2B = 256'h0,
    parameter [255:0] INIT_2C = 256'h0,
    parameter [255:0] INIT_2D = 256'h0,
    parameter [255:0] INIT_2E = 256'h0,
    parameter [255:0] INIT_2F = 256'h0,
    parameter [255:0] INIT_30 = 256'h0,
    parameter [255:0] INIT_31 = 256'h0,
    parameter [255:0] INIT_32 = 256'h0,
    parameter [255:0] INIT_33 = 256'h0,
    parameter [255:0] INIT_34 = 256'h0,
    parameter [255:0] INIT_35 = 256'h0,
    parameter [255:0] INIT_36 = 256'h0,
    parameter [255:0] INIT_37 = 256'h0,
    parameter [255:0] INIT_38 = 256'h0,
    parameter [255:0] INIT_39 = 256'h0,
    parameter [255:0] INIT_3A = 256'h0,
    parameter [255:0] INIT_3B = 256'h0,
    parameter [255:0] INIT_3C = 256'h0,
    parameter [255:0] INIT_3D = 256'h0,
    parameter [255:0] INIT_3E = 256'h0,
    parameter [255:0] INIT_3F = 256'h0
    ,
    parameter [8:0] SRVAL = 9'h0,
    parameter [8:0] INIT_A = 9'h0,
    parameter WRITE_MODE = "WRITE_FIRST"
) (
    output reg  [7:0]  DO,
    output wire [0:0]  DOP,
    input  wire [10:0] ADDR,
    input  wire        CLK,
    input  wire [7:0]  DI,
    input  wire [0:0]  DIP,
    input  wire        EN,
    input  wire        SSR,
    input  wire        WE
);

    assign DOP = 1'b0;
    reg [7:0] mem [0:2047];

    integer b;
    initial begin
        DO = 8'h00;
        for (b = 0; b < 32; b = b + 1) mem[0*32 + b] = INIT_00[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[1*32 + b] = INIT_01[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[2*32 + b] = INIT_02[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[3*32 + b] = INIT_03[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[4*32 + b] = INIT_04[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[5*32 + b] = INIT_05[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[6*32 + b] = INIT_06[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[7*32 + b] = INIT_07[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[8*32 + b] = INIT_08[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[9*32 + b] = INIT_09[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[10*32 + b] = INIT_0A[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[11*32 + b] = INIT_0B[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[12*32 + b] = INIT_0C[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[13*32 + b] = INIT_0D[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[14*32 + b] = INIT_0E[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[15*32 + b] = INIT_0F[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[16*32 + b] = INIT_10[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[17*32 + b] = INIT_11[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[18*32 + b] = INIT_12[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[19*32 + b] = INIT_13[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[20*32 + b] = INIT_14[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[21*32 + b] = INIT_15[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[22*32 + b] = INIT_16[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[23*32 + b] = INIT_17[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[24*32 + b] = INIT_18[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[25*32 + b] = INIT_19[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[26*32 + b] = INIT_1A[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[27*32 + b] = INIT_1B[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[28*32 + b] = INIT_1C[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[29*32 + b] = INIT_1D[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[30*32 + b] = INIT_1E[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[31*32 + b] = INIT_1F[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[32*32 + b] = INIT_20[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[33*32 + b] = INIT_21[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[34*32 + b] = INIT_22[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[35*32 + b] = INIT_23[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[36*32 + b] = INIT_24[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[37*32 + b] = INIT_25[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[38*32 + b] = INIT_26[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[39*32 + b] = INIT_27[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[40*32 + b] = INIT_28[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[41*32 + b] = INIT_29[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[42*32 + b] = INIT_2A[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[43*32 + b] = INIT_2B[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[44*32 + b] = INIT_2C[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[45*32 + b] = INIT_2D[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[46*32 + b] = INIT_2E[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[47*32 + b] = INIT_2F[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[48*32 + b] = INIT_30[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[49*32 + b] = INIT_31[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[50*32 + b] = INIT_32[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[51*32 + b] = INIT_33[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[52*32 + b] = INIT_34[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[53*32 + b] = INIT_35[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[54*32 + b] = INIT_36[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[55*32 + b] = INIT_37[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[56*32 + b] = INIT_38[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[57*32 + b] = INIT_39[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[58*32 + b] = INIT_3A[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[59*32 + b] = INIT_3B[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[60*32 + b] = INIT_3C[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[61*32 + b] = INIT_3D[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[62*32 + b] = INIT_3E[b*8 +: 8];
        for (b = 0; b < 32; b = b + 1) mem[63*32 + b] = INIT_3F[b*8 +: 8];
    end

    always @(posedge CLK) begin
        if (EN) begin
            if (SSR) begin
                DO <= SRVAL[7:0];
            end else begin
                if (WE)
                    mem[ADDR] <= DI;
                DO <= mem[ADDR];
            end
        end
    end

endmodule
