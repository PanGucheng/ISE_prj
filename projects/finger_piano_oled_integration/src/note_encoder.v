//=============================================================================
// note_encoder.v
// 7 路按键 → 音符编码 note_code[2:0] 的优先级编码器（纯组合逻辑）。
//
//   note_code = 0      无音符（静音）
//   note_code = 1..7   唱名 1..7，对应第四八度 C4..B4
//
// 单音电子琴：多键同时按下时使用固定优先级 1 > 2 > 3 > 4 > 5 > 6 > 7，
// 即 key_stable[0]（唱名 1）优先级最高，key_stable[6]（唱名 7）最低。
//
// 纯组合逻辑，无时钟、无复位，不需要任何时钟频率参数。
// 所有分支都给出赋值，不存在锁存器。
//=============================================================================

module note_encoder (
    input  wire [6:0] key_stable,   // 稳定后的按键输入
    output reg  [2:0] note_code     // 音符编码
);

    always @(*) begin
        if (key_stable[0]) begin
            note_code = 3'd1;       // 唱名 1 = C4，最高优先级
        end else if (key_stable[1]) begin
            note_code = 3'd2;       // 唱名 2 = D4
        end else if (key_stable[2]) begin
            note_code = 3'd3;       // 唱名 3 = E4
        end else if (key_stable[3]) begin
            note_code = 3'd4;       // 唱名 4 = F4
        end else if (key_stable[4]) begin
            note_code = 3'd5;       // 唱名 5 = G4
        end else if (key_stable[5]) begin
            note_code = 3'd6;       // 唱名 6 = A4
        end else if (key_stable[6]) begin
            note_code = 3'd7;       // 唱名 7 = B4，最低优先级
        end else begin
            note_code = 3'd0;       // 无按键
        end
    end

endmodule
