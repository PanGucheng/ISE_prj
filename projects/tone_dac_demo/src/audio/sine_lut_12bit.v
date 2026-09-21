//=============================================================================
// sine_lut_12bit.v
// DDS 正弦查找表 —— quarter-wave 65 点 x 11 bit 幅度(P3 计划 Commit B)。
//
// 幅度表:M[k] = round(1792 * sin(k*pi/128)),k = 0..64(0°~90°),
// 数值由脚本离线生成后固化为常量 case;综合 RTL 不含 real/$sin/运行时生成。
//
// 输入 8 bit 相位地址 = phase_acc[23:16]:
//   [7:6] = 象限  [5:0] = 象限内索引
//   00:0°~<90°    01:90°~<180°   10:180°~<270°   11:270°~<360°
//
// 输出无符号偏置正弦(P3 计划 §13/§14):
//   DAC = 2048 + 1792*sin(theta)
//   范围 256..3840(12'h100..12'hF00,两端留余量),中心 12'h800;
//   phase 0 -> 2048,64 -> 3840,128 -> 2048,192 -> 256(TB 精确校验)。
//
// 实现说明:65 点用两级组合 case(7 bit 序号 0..64 -> 11 bit 幅度;
// 象限 -> 加/减)。case 全列举 + default,无锁存;不强求 BRAM 推断
// (约 3 kbit 数据,稳定优先,XST 0 warning 优先,见 P3 计划 §46)。
// 纯组合逻辑,无时钟。
//=============================================================================

module sine_lut_12bit (
    input  wire [7:0]  phase_addr,   // phase_acc[23:16]
    output reg  [11:0] sine_code     // 无符号偏置正弦样点
);

    wire [1:0] quad  = phase_addr[7:6];
    wire [5:0] index = phase_addr[5:0];

    // 象限 -> 1/4 波表序号(0..64)
    reg [6:0]  k;
    always @(*) begin
        case (quad)
            2'b00:   k = {1'b0, index};             // M[index]
            2'b01:   k = 7'd64 - {1'b0, index};     // M[64-index]
            2'b10:   k = {1'b0, index};             // M[index]
            default: k = 7'd64 - {1'b0, index};     // M[64-index]
        endcase
    end

    // 1/4 波幅度表:M[k] = round(1792*sin(k*pi/128)),k = 0..64
    reg [10:0] mag;
    always @(*) begin
        case (k)
        7'd0  : mag = 11'd   0;
        7'd1  : mag = 11'd  44;
        7'd2  : mag = 11'd  88;
        7'd3  : mag = 11'd 132;
        7'd4  : mag = 11'd 176;
        7'd5  : mag = 11'd 219;
        7'd6  : mag = 11'd 263;
        7'd7  : mag = 11'd 306;
        7'd8  : mag = 11'd 350;
        7'd9  : mag = 11'd 393;
        7'd10 : mag = 11'd 435;
        7'd11 : mag = 11'd 478;
        7'd12 : mag = 11'd 520;
        7'd13 : mag = 11'd 562;
        7'd14 : mag = 11'd 604;
        7'd15 : mag = 11'd 645;
        7'd16 : mag = 11'd 686;
        7'd17 : mag = 11'd 726;
        7'd18 : mag = 11'd 766;
        7'd19 : mag = 11'd 806;
        7'd20 : mag = 11'd 845;
        7'd21 : mag = 11'd 883;
        7'd22 : mag = 11'd 921;
        7'd23 : mag = 11'd 959;
        7'd24 : mag = 11'd 996;
        7'd25 : mag = 11'd1032;
        7'd26 : mag = 11'd1067;
        7'd27 : mag = 11'd1102;
        7'd28 : mag = 11'd1137;
        7'd29 : mag = 11'd1170;
        7'd30 : mag = 11'd1203;
        7'd31 : mag = 11'd1236;
        7'd32 : mag = 11'd1267;
        7'd33 : mag = 11'd1298;
        7'd34 : mag = 11'd1328;
        7'd35 : mag = 11'd1357;
        7'd36 : mag = 11'd1385;
        7'd37 : mag = 11'd1413;
        7'd38 : mag = 11'd1439;
        7'd39 : mag = 11'd1465;
        7'd40 : mag = 11'd1490;
        7'd41 : mag = 11'd1514;
        7'd42 : mag = 11'd1537;
        7'd43 : mag = 11'd1559;
        7'd44 : mag = 11'd1580;
        7'd45 : mag = 11'd1601;
        7'd46 : mag = 11'd1620;
        7'd47 : mag = 11'd1638;
        7'd48 : mag = 11'd1656;
        7'd49 : mag = 11'd1672;
        7'd50 : mag = 11'd1687;
        7'd51 : mag = 11'd1702;
        7'd52 : mag = 11'd1715;
        7'd53 : mag = 11'd1727;
        7'd54 : mag = 11'd1738;
        7'd55 : mag = 11'd1748;
        7'd56 : mag = 11'd1758;
        7'd57 : mag = 11'd1766;
        7'd58 : mag = 11'd1773;
        7'd59 : mag = 11'd1779;
        7'd60 : mag = 11'd1783;
        7'd61 : mag = 11'd1787;
        7'd62 : mag = 11'd1790;
        7'd63 : mag = 11'd1791;
        7'd64 : mag = 11'd1792;

        default: mag = 11'd0;
        endcase
    end

    // 加/减象限合成 12 bit 偏置正弦
    always @(*) begin
        case (quad)
            2'b00,
            2'b01:   sine_code = 12'h800 + {1'b0, mag};   // 2048 + M
            default: sine_code = 12'h800 - {1'b0, mag};   // 2048 - M
        endcase
    end

endmodule
