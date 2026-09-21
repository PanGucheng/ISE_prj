//=============================================================================
// mcp4725_model.v
// MCP4725 协议级行为模型(仅供仿真,不可综合)—— P1 计划 C 阶段
//
// 只模拟 I2C 协议层(只收不发的写器件):
//   - 地址字节:1100+A2A1A0(默认 7'h60),匹配则 ACK(除非 nack_addr_en);
//   - 数据字节 1:C2 C1 C0 PD1 PD0 D11..D8。**EEPROM 命令违规检测**:
//     任何帧首数据字节 [7:5](即 C2C1C0)不等于 000 时置 eeprom_viol
//     (Fast Write 要求 C2C1=00;011 等 EEPROM 写命令一律算违规);
//   - 数据字节 2:D7..D0;
//   - 第三字节的 ACK 边沿更新 VOUT(图 6-1 注 2)-> 模型在字节 2 边界把
//     {D[11:8], D[7:0]} 锁存到 dac_out(协议级近似,不含模拟建立时间);
//   - pd_bits:最近一次帧的 PD1PD0(TB 检查正常模式 00);
//   - nack_data_en:数据字节回 NACK(测 controller DATA_NACK 映射)。
//
// TB 观测寄存器(层次引用):last_addr / last_b1 / last_b2 / dac_out /
//   pd_bits / frame_cnt / eeprom_viol
//=============================================================================

`timescale 1ns/1ps

module mcp4725_model #(
    parameter [6:0] DEVICE_ADDR = 7'h60
) (
    input  wire clk,
    input  wire rst,
    input  wire nack_addr_en,
    input  wire nack_data_en,
    inout  wire scl,
    inout  wire sda
);

    // 写数据字节角色
    localparam [1:0] ROLE_ADDR = 2'd0,   // 期望:地址字节
                     ROLE_B1   = 2'd1,   // 期望:数据字节 1
                     ROLE_B2   = 2'd2;   // 期望:数据字节 2

    // 总线驱动(开漏,只输出 0 或 Z;本器件只 ACK,不发送数据)
    reg sda_d;
    assign sda = sda_d ? 1'b0 : 1'bz;

    //-------------------------------------------------------------------------
    // 边沿与条件检测(同步采样)
    //-------------------------------------------------------------------------
    reg scl_q, sda_q;
    always @(posedge clk) begin
        scl_q <= scl;
        sda_q <= sda;
    end
    wire scl_rise = (scl === 1'b1) && (scl_q !== 1'b1);
    wire scl_fall = (scl !== 1'b1) && (scl_q === 1'b1);
    wire start_c  = (sda === 1'b0) && (sda_q === 1'b1) && (scl === 1'b1);
    wire stop_c   = (sda === 1'b1) && (sda_q === 1'b0) && (scl === 1'b1);

    //-------------------------------------------------------------------------
    // 内部状态(模型专用 blocking 赋值)
    //-------------------------------------------------------------------------
    reg        byte_active;
    reg [3:0]  bidx;          // 已完成的 SCL 上升沿数(0..9)
    reg [7:0]  shift;
    reg [1:0]  wr_role;

    reg [6:0]  last_addr;
    reg [7:0]  last_b1;
    reg [7:0]  last_b2;
    reg [11:0] dac_out;       // VOUT 对应的 12 bit 码(第三字节 ACK 沿更新)
    reg [1:0]  pd_bits;       // 最近帧的 PD1PD0
    integer    frame_cnt;
    reg        eeprom_viol;   // 检测到非 Fast Write 命令码(C2C1C0 != 000)

    //-------------------------------------------------------------------------
    // 主模型进程
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            byte_active  = 1'b0;
            bidx         = 4'd0;
            shift        = 8'h00;
            wr_role      = ROLE_ADDR;
            sda_d        = 1'b0;
            last_addr    = 7'h00;
            last_b1      = 8'h00;
            last_b2      = 8'h00;
            dac_out      = 12'h000;
            pd_bits      = 2'b00;
            frame_cnt    = 0;
            eeprom_viol  = 1'b0;
        end else begin
            //-----------------------------------------------------------------
            // START / STOP
            //-----------------------------------------------------------------
            if (start_c) begin
                byte_active = 1'b1;
                bidx        = 4'd0;
                shift       = 8'h00;
                wr_role     = ROLE_ADDR;
                sda_d       = 1'b0;
            end
            if (stop_c) begin
                byte_active = 1'b0;
                sda_d       = 1'b0;
            end

            //-----------------------------------------------------------------
            // SCL 上升沿:采样主机写来的位
            //-----------------------------------------------------------------
            if (scl_rise && byte_active) begin
                if (bidx < 8) begin
                    shift = {shift[6:0], sda};
                    bidx  = bidx + 4'd1;
                end else begin
                    bidx = 4'd9;                 // ACK 槽上升沿
                end
            end

            //-----------------------------------------------------------------
            // SCL 下降沿:驱动 ACK;字节边界处理
            //-----------------------------------------------------------------
            if (scl_fall && byte_active) begin
                if (bidx == 4'd9) begin
                    //---------------------------------------------------------
                    // 字节边界
                    //---------------------------------------------------------
                    case (wr_role)
                        ROLE_ADDR: begin
                            last_addr = shift[7:1];
                            wr_role   = ROLE_B1;
                        end
                        ROLE_B1: begin
                            last_b1 = shift;
                            if (shift[7:5] != 3'b000) begin
                                eeprom_viol = 1'b1;   // 非 Fast Write 命令码
                            end
                            pd_bits  = shift[5:4];
                            wr_role  = ROLE_B2;
                        end
                        ROLE_B2: begin
                            last_b2  = shift;
                            dac_out  = {last_b1[3:0], shift};   // VOUT 更新沿
                            frame_cnt = frame_cnt + 1;
                            wr_role  = ROLE_ADDR;   // 多余字节忽略,等 STOP
                        end
                        default: begin
                            wr_role = ROLE_ADDR;
                        end
                    endcase
                    sda_d = 1'b0;                    // ACK 槽结束释放
                    bidx  = 4'd0;
                end else if (bidx == 4'd8) begin
                    //---------------------------------------------------------
                    // ACK 槽前的下落沿:驱动 ACK
                    //---------------------------------------------------------
                    if (wr_role == ROLE_ADDR) begin
                        sda_d = ((shift[7:1] == DEVICE_ADDR) && !nack_addr_en);
                    end else begin
                        sda_d = !nack_data_en;
                    end
                end else begin
                    sda_d = 1'b0;                    // 数据位期间释放
                end
            end
        end
    end

endmodule
