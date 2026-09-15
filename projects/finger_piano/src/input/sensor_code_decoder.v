//=============================================================================
// sensor_code_decoder.v
// 3-bit 传感器编码 -> note_code 解码(P2 计划 Commit A)。
//
// 编码冻结(项目设计冻结,真实硬件为 3 个 LM393 比较器输出):
//
//   sensor_code   note_code   唱名
//   000           0           静音
//   001           1           C4
//   010           2           D4
//   011           3           E4
//   100           4           F4
//   101           5           G4
//   110           6           A4
//   111           7           B4
//
// sensor_code[0]/[1]/[2] 权重分别为 1/2/4。数值上 note_code == sensor_code
// (恒等映射),但这里保留显式 case 作为硬件语义边界:
//   - RTL 直接表达课程编码表,TB 逐项核对;
//   - 编码表将来调整只改这一处;
//   - 不把"位线"与"音符编号"两个概念混为一谈。
// XST 即使把它优化成纯连线也没有问题。
//
// 8 个状态全部有定义(000=静音,001~111=音符1~7),因此**不存在**非法
// 编码,本模块不设任何 error/invalid 输出(P2 计划 §28)。
//
// 纯组合逻辑;输入必须来自 sensor_code_filter 的稳定输出。
//=============================================================================

module sensor_code_decoder (
    input  wire [2:0] sensor_code,   // 稳定的 3-bit 传感器编码
    output reg  [2:0] note_code      // 0 = 静音,1~7 = 唱名
);

    always @(*) begin
        case (sensor_code)
            3'b000:  note_code = 3'd0;
            3'b001:  note_code = 3'd1;
            3'b010:  note_code = 3'd2;
            3'b011:  note_code = 3'd3;
            3'b100:  note_code = 3'd4;
            3'b101:  note_code = 3'd5;
            3'b110:  note_code = 3'd6;
            3'b111:  note_code = 3'd7;
            default: note_code = 3'd0;
        endcase
    end

endmodule
