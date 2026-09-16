//=============================================================================
// ads1115_model.v
// ADS1115 协议级行为模型(仅供仿真,不可综合)—— P1 计划 B 阶段
//
// 只模拟 I2C 协议层,不模拟模拟电路:
//   - 地址字节:仅 ACK 与 DEVICE_ADDR 匹配的地址(除非 nack_addr_en);
//   - 写:地址字节后第一字节 = Address Pointer(P[1:0]:00=Conversion,
//     01=Config,手册 8-1);随后两字节写入 Pointer 指向的寄存器(MSB 在前);
//   - 写 Config 且 OS=1、MODE=1(单次转换):OS 位变 0(转换中),
//     CONV_CYCLES 个 clk 后 OS=1 并按 MUX 装载转换值:
//       MUX=100 -> VAL_AIN0(默认 1234h)、101 -> VAL_AIN1(3456h)、
//       110 -> VAL_AIN2(5678h)、其它 -> 0;
//   - 读:按当前 Pointer 返回两字节(MSB 先):00 -> Conversion,
//     01 -> Config(位 15 为实时 OS 状态,其余为最近写入值);
//   - conv_never_done:转换永不完成(OS 恒 0),用于测试 controller
//     的转换等待超时路径。
//
// TB 注入信号:
//   nack_addr_en    地址字节回 NACK(测 controller 的 ADDR_NACK 映射)
//   nack_data_en    pointer/数据字节回 NACK(测 DATA_NACK 映射)
//   conv_never_done 转换永不完成(测等待超时)
//
// TB 观测寄存器(层次引用):
//   last_addr / last_rw / last_cfg / restart_cnt / stop_cnt /
//   ptr01_cnt / ptr00_cnt
//=============================================================================

`timescale 1ns/1ps

module ads1115_model #(
    parameter [6:0]   DEVICE_ADDR  = 7'h48,
    parameter integer CONV_CYCLES   = 2000,     // 转换耗时(clk 数)
    parameter [15:0]  VAL_AIN0      = 16'h1234,
    parameter [15:0]  VAL_AIN1      = 16'h3456,
    parameter [15:0]  VAL_AIN2      = 16'h5678
) (
    input  wire clk,
    input  wire rst,
    input  wire nack_addr_en,
    input  wire nack_data_en,
    input  wire conv_never_done,
    inout  wire scl,
    inout  wire sda
);

    // 写数据字节角色
    localparam [1:0] ROLE_ADDR  = 2'd0,   // 期望:地址字节
                     ROLE_PTR   = 2'd1,   // 期望:pointer 字节
                     ROLE_CFGHI = 2'd2,   // 期望:寄存器数据高字节
                     ROLE_CFGLO = 2'd3;   // 期望:寄存器数据低字节

    // 总线驱动(开漏,只输出 0 或 Z)
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
    // 内部状态(模型专用,允许 blocking 赋值)
    //-------------------------------------------------------------------------
    reg        in_txn;        // 事务中(START 之后 STOP 之前)
    reg        byte_active;   // 正在收发一个 9 拍字节
    reg [3:0]  bidx;          // 已完成的 SCL 上升沿数(0..9)
    reg [7:0]  shift;         // 移位寄存器(写:收数据;读:装载字节)
    reg [1:0]  wr_role;       // 当前写数据字节角色
    reg        read_mode;     // 读数据阶段(地址 rw=1 之后)
    reg        rd_byte_hi;    // 读阶段:0 = 正在送 MSB 字节,1 = LSB 字节
    reg        ack_bit;       // 读字节第 9 拍采到的主机 ACK(0)/NACK(1)

    reg [7:0]  pointer_reg;   // Address Pointer 寄存器
    reg [7:0]  cfg_hi_q;      // Config 高字节暂存
    reg [15:0] cfg_reg;       // 最近写入的 Config(原始,含写入的 OS 位)
    reg [15:0] cfg_mux100;    // 最近一次 MUX=100(AIN0-GND)的 Config(TB 观测)
    reg [15:0] cfg_mux101;    // 最近一次 MUX=101(AIN1-GND)的 Config(TB 观测)
    reg [15:0] cfg_mux110;    // 最近一次 MUX=110(AIN2-GND)的 Config(TB 观测)
    reg        os_busy;       // 1 = 转换进行中(OS 读 0)
    reg [31:0] conv_cnt;
    reg [2:0]  mux_q;         // 转换中的 MUX
    reg [15:0] conv_val;      // 最近一次完成的转换值

    // TB 观测
    reg [6:0]  last_addr;
    reg        last_rw;
    reg [15:0] last_cfg;
    integer    restart_cnt;
    integer    stop_cnt;
    integer    ptr01_cnt;
    integer    ptr00_cnt;

    // 读返回值:pointer=01 -> Config(位 15 为实时 OS);pointer=00 -> Conversion
    reg [15:0] rd_val;
    reg [7:0]  rd_byte;
    always @(*) begin
        if (pointer_reg == 8'h01) begin
            rd_val = {~os_busy, cfg_reg[14:0]};
        end else begin
            rd_val = conv_val;
        end
        rd_byte = rd_byte_hi ? rd_val[7:0] : rd_val[15:8];
    end

    //-------------------------------------------------------------------------
    // 主模型进程(模型专用 blocking 风格,无综合意图)
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            in_txn        = 1'b0;
            byte_active   = 1'b0;
            bidx          = 4'd0;
            shift         = 8'h00;
            wr_role       = ROLE_ADDR;
            read_mode     = 1'b0;
            rd_byte_hi    = 1'b0;
            ack_bit       = 1'b0;
            pointer_reg   = 8'h00;
            cfg_hi_q      = 8'h00;
            cfg_reg       = 16'h8583;   // 手册复位值
            cfg_mux100    = 16'h0000;
            cfg_mux101    = 16'h0000;
            cfg_mux110    = 16'h0000;
            os_busy       = 1'b0;
            conv_cnt      = 32'd0;
            mux_q         = 3'b000;
            conv_val      = 16'h0000;
            sda_d         = 1'b0;
            last_addr     = 7'h00;
            last_rw       = 1'b0;
            last_cfg      = 16'h0000;
            restart_cnt   = 0;
            stop_cnt      = 0;
            ptr01_cnt     = 0;
            ptr00_cnt     = 0;
        end else begin
            //-----------------------------------------------------------------
            // START / RESTART / STOP
            //-----------------------------------------------------------------
            if (start_c) begin
                if (in_txn) begin
                    restart_cnt = restart_cnt + 1;   // RESTART(中间无 STOP)
                end
                in_txn      = 1'b1;
                byte_active = 1'b1;
                bidx        = 4'd0;
                shift       = 8'h00;
                wr_role     = ROLE_ADDR;
                read_mode   = 1'b0;
                rd_byte_hi  = 1'b0;
                ack_bit     = 1'b0;
                sda_d       = 1'b0;
            end

            if (stop_c) begin
                in_txn      = 1'b0;
                byte_active = 1'b0;
                read_mode   = 1'b0;
                sda_d       = 1'b0;
                stop_cnt    = stop_cnt + 1;
            end

            //-----------------------------------------------------------------
            // SCL 上升沿:采样主机写来的位
            //-----------------------------------------------------------------
            if (scl_rise && byte_active) begin
                if (bidx < 8) begin
                    shift = {shift[6:0], sda};
                    bidx  = bidx + 4'd1;
                end else begin
                    ack_bit = sda;               // 读阶段:主机的 ACK/NACK
                    bidx    = 4'd9;
                end
            end

            //-----------------------------------------------------------------
            // SCL 下降沿:驱动 ACK / 读数据位;字节边界处理
            //-----------------------------------------------------------------
            if (scl_fall && byte_active) begin
                if (bidx == 4'd9) begin
                    //---------------------------------------------------------
                    // 字节边界:处理刚完成的字节
                    //---------------------------------------------------------
                    if (!read_mode) begin
                        case (wr_role)
                            ROLE_ADDR: begin
                                last_addr = shift[7:1];
                                last_rw   = shift[0];
                                if (shift[0]) begin
                                    read_mode  = 1'b1;
                                    rd_byte_hi = 1'b0;
                                    sda_d      = ~rd_val[15]; // 读 MSB 字节 bit7(拉低=0)
                                end else begin
                                    wr_role     = ROLE_PTR;
                                    sda_d       = 1'b0;
                                end
                            end
                            ROLE_PTR: begin
                                pointer_reg = shift;
                                if (shift == 8'h01) begin
                                    ptr01_cnt = ptr01_cnt + 1;
                                    wr_role   = ROLE_CFGHI;  // Config 写:后跟两字节
                                end else begin
                                    if (shift == 8'h00) begin
                                        ptr00_cnt = ptr00_cnt + 1;
                                    end
                                    wr_role = ROLE_ADDR;     // Conversion 只读
                                end
                                sda_d = 1'b0;
                            end
                            ROLE_CFGHI: begin
                                cfg_hi_q = shift;
                                wr_role  = ROLE_CFGLO;
                                sda_d    = 1'b0;
                            end
                            ROLE_CFGLO: begin
                                cfg_reg  = {cfg_hi_q, shift};
                                last_cfg = {cfg_hi_q, shift};
                                // 按 MUX 分通道记录(TB 逐通道核对配置字)
                                case (cfg_hi_q[6:4])
                                    3'b100:  cfg_mux100 = {cfg_hi_q, shift};
                                    3'b101:  cfg_mux101 = {cfg_hi_q, shift};
                                    3'b110:  cfg_mux110 = {cfg_hi_q, shift};
                                    default: ;
                                endcase
                                // OS=1 且 MODE=1 -> 启动一次转换(单次模式)
                                if (cfg_hi_q[7] && shift[0]) begin
                                    os_busy  = 1'b1;
                                    conv_cnt = 32'd0;
                                    mux_q    = cfg_hi_q[6:4];
                                end
                                wr_role = ROLE_ADDR;
                                sda_d   = 1'b0;
                            end
                            default: begin
                                wr_role = ROLE_ADDR;
                                sda_d   = 1'b0;
                            end
                        endcase
                    end else begin
                        //-----------------------------------------------------
                        // 读字节边界:主机 ACK=继续,主机 NACK=读结束
                        //-----------------------------------------------------
                        if (ack_bit == 1'b0) begin
                            rd_byte_hi = 1'b1;           // MSB 完成,继续 LSB
                            sda_d      = ~rd_val[7];     // LSB 字节 bit7(拉低=0)
                        end else begin
                            read_mode = 1'b0;            // 主机 NACK:读结束
                            sda_d     = 1'b0;
                        end
                    end
                    bidx = 4'd0;
                end else if (!read_mode) begin
                    //---------------------------------------------------------
                    // 写模式:数据位期间释放;第 8 拍之后驱动 ACK 槽
                    //---------------------------------------------------------
                    if (bidx == 4'd8) begin
                        if (wr_role == ROLE_ADDR) begin
                            sda_d = ((shift[7:1] == DEVICE_ADDR) && !nack_addr_en);
                        end else begin
                            sda_d = !nack_data_en;
                        end
                    end else begin
                        sda_d = 1'b0;
                    end
                end else begin
                    //---------------------------------------------------------
                    // 读模式:bidx<8 驱动当前数据位;ACK 槽释放(主机驱动)
                    //---------------------------------------------------------
                    if (bidx < 8) begin
                        sda_d = ~rd_byte[7 - bidx[2:0]];  // 拉低=数据 0
                    end else begin
                        sda_d = 1'b0;
                    end
                end
            end

            //-----------------------------------------------------------------
            // 转换计时:CONV_CYCLES 后 OS 就绪并按 MUX 装载转换值
            //-----------------------------------------------------------------
            if (os_busy) begin
                if (!conv_never_done) begin
                    conv_cnt = conv_cnt + 32'd1;
                    if (conv_cnt >= CONV_CYCLES) begin
                        os_busy = 1'b0;
                        case (mux_q)
                            3'b100:  conv_val = VAL_AIN0;
                            3'b101:  conv_val = VAL_AIN1;
                            3'b110:  conv_val = VAL_AIN2;
                            default: conv_val = 16'h0000;
                        endcase
                    end
                end
            end
        end
    end

endmodule
