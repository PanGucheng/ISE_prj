//=============================================================================
// ads1115_ctrl.v
// ADS1115 三通道轮询采集控制器(standalone,不进顶层)—— P1 计划 B 阶段
//
// 协议依据:doc/ads1115.pdf(TI ZHCS311E / SBAS444),不采用网络示例:
//   - 器件地址:ADDR=GND -> 1001000b = 7'h48(表 7-2),参数化可改;
//   - Pointer 寄存器 P[1:0]:00b = Conversion,01b = Config(8-1);
//   - Config 寄存器(图 8-5):OS[15] MUX[14:12] PGA[11:9] MODE[8] DR[7:5]
//     COMP_MODE[4] COMP_POL[3] COMP_LAT[2] COMP_QUE[1:0];
//   - OS:写 1 启动单次转换;读 0 = 转换进行中,读 1 = 就绪(8-1.3);
//   - 单端 MUX:100b = AIN0-GND,101b = AIN1-GND,110b = AIN2-GND;
//   - PGA = 001 -> FSR = +-4.096 V;DR = 111 -> 860 SPS(容差 +-10%);
//   - 比较器关闭:COMP_QUE = 11b,其余 COMP 位 = 0;
//   - 读写均 MSB 字节在前;读最后一字节由主机 NACK(7.5.2);
//   - 转换完成用轮询 Config.OS 判断 + 超时兜底(860 SPS 标称约 1.163 ms,
//     DR 容差 +-10% -> 超时取 >= 2 ms 当量,禁止只硬等固定周期)。
//
// 默认配置字由位域拼接(不是抄任务书十六进制,可按宏重算):
//   {OS=1, MUX, PGA=001, MODE=1, DR=111, 0,0,0, COMP_QUE=11}
//   CH0(MUX=100) = 16'hC3E3,CH1(101) = 16'hD3E3,CH2(110) = 16'hE3E3
//
// FSM(每帧 = 三通道各一次"写配置 -> 等转换 -> 读结果"):
//   IDLE -> C(写 Config) -> W(轮询 OS) -> R(读 Conversion)
//        -> [通道 0/1 循环] -> S_VALID(adc_sample_valid 脉冲) -> 下一帧
//
// 错误码(error_code,粘滞到下一次帧成功结束的 S_VALID 清零):
//   0 = 无错误;1 = 地址字节 NACK;2 = pointer/数据字节 NACK;
//   3 = I2C master 超时;4 = 其它(转换等待超时 / 协议异常)
// NACK 或超时发生时:master 已自动补 STOP / 释放总线,controller 再补发
// 一次 STOP 保证事务关闭,然后 pulse adc_error 并重新开始扫描帧。
//
// ENABLE = 0:整块逻辑不生成(FSM 停在复位态),不发任何 I2C,
//   adc_sample_valid = 0,SCL/SDA 无驱动(保持 Z,上拉为高)。
//
// 时序参数:LOW/HIGH/BUF/timeout 由本模块算好后传给 i2c_master,
//   分层规则(P1 计划冻结):默认路径 SYS_CLK_HZ == 12_000_000 且
//   I2C_HZ == 333_333 -> 固定 18+18 = 36 拍(actual 333333.333 Hz);
//   其它任何 I2C_HZ 走强制公式(先除后取整,避免 32 位溢出):
//     LOW    = ceil(tLOW_MIN * SYS_CLK)   经 Q = 1e9/1300
//     PERIOD = ceil(SYS_CLK / I2C_HZ)
//     HIGH   = max( ceil(tHIGH_MIN*SYS_CLK), PERIOD-LOW )
//   ADS1115 Fast-mode 手册值:tLOW >= 1300 ns,tHIGH >= 600 ns,
//   tBUF/tHDSTA/tSUSTA/tSUSTO >= 600 ns。
//=============================================================================

`include "finger_piano_cfg.vh"

module ads1115_ctrl #(
    parameter integer ENABLE     = `CFG_ENABLE_ADS1115,
    parameter integer I2C_ADDR   = `CFG_ADS1115_ADDR,   // 7 位器件地址
    parameter integer PGA        = `CFG_ADS1115_PGA,    // 3 位:001 = +-4.096 V
    parameter integer DR         = `CFG_ADS1115_DR,     // 3 位:111 = 860 SPS
    parameter integer SYS_CLK_HZ = `SYS_CLK_HZ,
    parameter integer I2C_HZ     = `CFG_ADC_I2C_SPEED
) (
    input  wire        clk,
    input  wire        rst_n_sync,
    inout  wire        adc_i2c_scl,
    inout  wire        adc_i2c_sda,
    output wire [15:0] adc_ch0_raw,      // 原样输出的 16-bit two's-complement
    output wire [15:0] adc_ch1_raw,
    output wire [15:0] adc_ch2_raw,
    output wire        adc_sample_valid, // 三通道一轮完成,单周期脉冲
    output wire        adc_busy,
    output wire        adc_error,        // 帧失败,单周期脉冲
    output wire [2:0]  error_code        // 粘滞,见文件头
);

    //-------------------------------------------------------------------------
    // I2C 时序参数(强制公式 + 默认 18+18 分层规则)
    //-------------------------------------------------------------------------
    localparam integer Q_LOW   = 1000000000 / 1300;    // 拟合 1e9/1300ns
    localparam integer Q_HIGH  = 1000000000 / 600;     // 拟合 1e9/600ns
    localparam integer LOW_F   = (SYS_CLK_HZ + Q_LOW  - 1) / Q_LOW;    // >= tLOW
    localparam integer PERIOD_F= (SYS_CLK_HZ + I2C_HZ - 1) / I2C_HZ;   // 目标周期
    localparam integer HIGH_MIN= (SYS_CLK_HZ + Q_HIGH - 1) / Q_HIGH;   // >= tHIGH
    localparam integer HIGH_DIFF = PERIOD_F - LOW_F;
    localparam integer HIGH_F  = (HIGH_MIN > HIGH_DIFF) ? HIGH_MIN : HIGH_DIFF;
    localparam integer T600    = (SYS_CLK_HZ + Q_HIGH - 1) / Q_HIGH;   // 600ns 档
    localparam integer BUF_F   = T600;                 // ADS1115 tBUF = 600 ns

    localparam integer SCL_LOW_CYC =
        ((SYS_CLK_HZ == 12000000) && (I2C_HZ == 333333)) ? 18 : LOW_F;
    localparam integer SCL_HIGH_CYC =
        ((SYS_CLK_HZ == 12000000) && (I2C_HZ == 333333)) ? 18 : HIGH_F;
    // 单条 master 命令最长 9*(LOW+HIGH) 拍,超时给 36 个位周期 + 余量
    localparam integer MASTER_TIMEOUT = 36 * (SCL_LOW_CYC + SCL_HIGH_CYC) + 1024;
    // 转换等待超时:860SPS 标称 1.163ms、容差 +-10%,取 >= 2ms 当量
    localparam integer OS_WAIT_CYCLES =
        ((SYS_CLK_HZ / 500) < 1000) ? 1000 : (SYS_CLK_HZ / 500);

    // 计算表示非负整数所需的最小位宽(纯 Verilog-2001 常量函数)
    function integer calc_bits;
        input integer v;
        integer bits;
        begin
            bits = 0;
            while (v > 0) begin
                bits = bits + 1;
                v = v >> 1;
            end
            calc_bits = (bits < 1) ? 1 : bits;
        end
    endfunction

    localparam integer WAIT_BITS = calc_bits(OS_WAIT_CYCLES) + 1;

    //-------------------------------------------------------------------------
    // 配置字(手册位域拼接;PGA/DR 参数取低 3 位,避免对 integer 参数做位选择)
    //-------------------------------------------------------------------------
    localparam [2:0]  PGA_B  = PGA % 8;
    localparam [2:0]  DR_B   = DR  % 8;
    localparam [6:0]  ADDR_B = I2C_ADDR % 128;

    // {OS=1, MUX, PGA, MODE=1, DR, COMP_MODE=0, COMP_POL=0, COMP_LAT=0, COMP_QUE=11}
    localparam [15:0] CFG_CH0 = {1'b1, 3'b100, PGA_B, 1'b1, DR_B, 2'b00, 1'b0, 2'b11};
    localparam [15:0] CFG_CH1 = {1'b1, 3'b101, PGA_B, 1'b1, DR_B, 2'b00, 1'b0, 2'b11};
    localparam [15:0] CFG_CH2 = {1'b1, 3'b110, PGA_B, 1'b1, DR_B, 2'b00, 1'b0, 2'b11};

    //-------------------------------------------------------------------------
    // i2c_master 命令编码(与 i2c_master.v 保持一致)
    //-------------------------------------------------------------------------
    localparam [2:0] M_START   = 3'd0,
                     M_RESTART = 3'd1,
                     M_WRITE   = 3'd2,
                     M_READ    = 3'd3,
                     M_STOP    = 3'd4;

    //-------------------------------------------------------------------------
    // 主 FSM 状态
    //-------------------------------------------------------------------------
    localparam [4:0] S_IDLE     = 5'd0,
                     S_C_START  = 5'd1,   // 写 Config:START
                     S_C_AW     = 5'd2,   //   地址字节 (addr+W)
                     S_C_PTR    = 5'd3,   //   pointer 01
                     S_C_HI     = 5'd4,   //   Config[15:8]
                     S_C_LO     = 5'd5,   //   Config[7:0],启动转换计时
                     S_C_STOP   = 5'd6,   //   STOP
                     S_W_START  = 5'd7,   // 轮询 Config:START
                     S_W_AW     = 5'd8,   //   地址字节 (addr+W)
                     S_W_PTR    = 5'd9,   //   pointer 01
                     S_W_RST    = 5'd10,  //   RESTART
                     S_W_RW     = 5'd11,  //   地址字节 (addr+R)
                     S_W_MSB    = 5'd12,  //   读 Config 高字节
                     S_W_LSB    = 5'd13,  //   读 Config 低字节(主机 NACK)
                     S_W_CHK    = 5'd14,  //   判 OS:1=就绪 0=继续轮询/超时
                     S_W_STOP   = 5'd15,  //   STOP 收尾本轮轮询事务
                     S_R_START  = 5'd16,  // 读 Conversion:START
                     S_R_AW     = 5'd17,  //   地址字节 (addr+W)
                     S_R_PTR    = 5'd18,  //   pointer 00
                     S_R_RST    = 5'd19,  //   RESTART
                     S_R_RW     = 5'd20,  //   地址字节 (addr+R)
                     S_R_MSB    = 5'd21,  //   读转换值高字节
                     S_R_LSB    = 5'd22,  //   读转换值低字节(主机 NACK)
                     S_R_STOP   = 5'd23,  //   STOP,存结果,切通道
                     S_VALID    = 5'd24,  // 一帧完成,adc_sample_valid 脉冲
                     S_ERR_STOP = 5'd25,  // 错误收尾:补发 STOP 关闭事务
                     S_ERR      = 5'd26;  // adc_error 脉冲并回 IDLE

    // ENABLE = 0:纯直连关闭分支,零 I2C 活动,总线无驱动(保持 Z)
    generate
        if (ENABLE == 0) begin : GEN_OFF

            assign adc_ch0_raw      = 16'h0000;
            assign adc_ch1_raw      = 16'h0000;
            assign adc_ch2_raw      = 16'h0000;
            assign adc_sample_valid = 1'b0;
            assign adc_busy         = 1'b0;
            assign adc_error        = 1'b0;
            assign error_code       = 3'd0;

        end else begin : GEN_ADC

    //-------------------------------------------------------------------------
    // 状态寄存器与中间量(先声明后使用)
    //-------------------------------------------------------------------------
    reg [4:0]  state;
    reg        issued;          // 已向 master 发出当前步命令
    reg [1:0]  iss_cnt;         // 已发出后的 clk 计数(检测"即时完成")
    reg        saw_busy;        // 已观察到 master 离开 ready(防误判完成)
    reg [1:0]  ch;              // 当前通道 0..2
    reg [15:0] ch0_q;           // 通道结果寄存
    reg [15:0] ch1_q;
    reg [15:0] ch2_q;
    reg [7:0]  poll_hi;         // 轮询读到的 Config 高字节
    reg [7:0]  poll_lo;
    reg [7:0]  raw_hi;          // 转换值高/低字节
    reg [7:0]  raw_lo;
    reg        os_ready_flag;   // S_W_CHK 的判定结果,供 S_W_STOP 使用
    reg        wait_active;     // 转换等待计时中
    reg [WAIT_BITS-1:0] wait_cnt;
    wire       wait_timeout = (wait_cnt >= OS_WAIT_CYCLES[WAIT_BITS-1:0]);
    reg [2:0]  err_code_q;      // 粘滞错误码

    reg        r_sample_valid;
    reg        r_busy;
    reg        r_error;
    reg [2:0]  r_errcode;

    // master 命令接口
    reg        m_valid;
    reg  [2:0] m_cmd;
    reg  [7:0] m_wdata;
    reg        m_nack;
    wire       m_ready;
    wire [7:0] m_rdata;
    wire [1:0] m_ecode;

    i2c_master #(
        .SYS_CLK_HZ        (SYS_CLK_HZ),
        .SCL_LOW_CYCLES    (SCL_LOW_CYC),
        .SCL_HIGH_CYCLES   (SCL_HIGH_CYC),
        .T_HDSTA_CYCLES    (T600),
        .T_SUSTA_CYCLES    (T600),
        .T_SUSTO_CYCLES    (T600),
        .T_BUF_CYCLES      (BUF_F),
        .TIMEOUT_CYCLES    (MASTER_TIMEOUT)
    ) u_i2c (
        .clk        (clk),
        .rst_n_sync (rst_n_sync),
        .cmd        (m_cmd),
        .cmd_valid  (m_valid),
        .wr_data    (m_wdata),
        .nack_after (m_nack),
        .cmd_ready  (m_ready),
        .rd_data    (m_rdata),
        .error      (),
        .error_code (m_ecode),
        .scl        (adc_i2c_scl),
        .sda        (adc_i2c_sda)
    );

    //-------------------------------------------------------------------------
    // 每个命令步的字段(组合)
    //-------------------------------------------------------------------------
    reg [15:0] cfg_word;
    reg [2:0]  st_cmd;
    reg [7:0]  st_wdata;
    reg        st_nack;
    reg [4:0]  st_next;
    reg [2:0]  st_errcls;

    always @(*) begin
        case (ch)
            2'd0:    cfg_word = CFG_CH0;
            2'd1:    cfg_word = CFG_CH1;
            default: cfg_word = CFG_CH2;
        endcase
    end

    always @(*) begin
        st_cmd   = M_START;
        st_wdata = 8'h00;
        st_nack  = 1'b0;
        st_next  = S_IDLE;
        case (state)
            S_C_START:  begin st_cmd = M_START;                                                   st_next = S_C_AW;    end
            S_C_AW:     begin st_cmd = M_WRITE;  st_wdata = {ADDR_B, 1'b0};  st_next = S_C_PTR;   end
            S_C_PTR:    begin st_cmd = M_WRITE;  st_wdata = 8'h01;           st_next = S_C_HI;    end
            S_C_HI:     begin st_cmd = M_WRITE;  st_wdata = cfg_word[15:8];  st_next = S_C_LO;    end
            S_C_LO:     begin st_cmd = M_WRITE;  st_wdata = cfg_word[7:0];   st_next = S_C_STOP;  end
            S_C_STOP:   begin st_cmd = M_STOP;                                                    st_next = S_W_START; end
            S_W_START:  begin st_cmd = M_START;                                                   st_next = S_W_AW;    end
            S_W_AW:     begin st_cmd = M_WRITE;  st_wdata = {ADDR_B, 1'b0};  st_next = S_W_PTR;   end
            S_W_PTR:    begin st_cmd = M_WRITE;  st_wdata = 8'h01;           st_next = S_W_RST;   end
            S_W_RST:    begin st_cmd = M_RESTART;                                                  st_next = S_W_RW;    end
            S_W_RW:     begin st_cmd = M_WRITE;  st_wdata = {ADDR_B, 1'b1};  st_next = S_W_MSB;   end
            S_W_MSB:    begin st_cmd = M_READ;                                                    st_next = S_W_LSB;   end
            S_W_LSB:    begin st_cmd = M_READ;   st_nack = 1'b1;             st_next = S_W_CHK;   end
            S_W_STOP:   begin st_cmd = M_STOP;                                                     end // 下一态运行时决定
            S_R_START:  begin st_cmd = M_START;                                                   st_next = S_R_AW;    end
            S_R_AW:     begin st_cmd = M_WRITE;  st_wdata = {ADDR_B, 1'b0};  st_next = S_R_PTR;   end
            S_R_PTR:    begin st_cmd = M_WRITE;  st_wdata = 8'h00;           st_next = S_R_RST;   end
            S_R_RST:    begin st_cmd = M_RESTART;                                                  st_next = S_R_RW;    end
            S_R_RW:     begin st_cmd = M_WRITE;  st_wdata = {ADDR_B, 1'b1};  st_next = S_R_MSB;   end
            S_R_MSB:    begin st_cmd = M_READ;                                                    st_next = S_R_LSB;   end
            S_R_LSB:    begin st_cmd = M_READ;   st_nack = 1'b1;             st_next = S_R_STOP;  end
            S_R_STOP:   begin st_cmd = M_STOP;                                                     end // 下一态运行时决定
            S_ERR_STOP: begin st_cmd = M_STOP;                                                     end // 完成后无视结果
            default:    ;
        endcase
    end

    // 错误分类:地址字节 NACK -> 1;数据/pointer 字节 NACK -> 2;master 超时 -> 3;其它 -> 4
    always @(*) begin
        case (state)
            S_C_AW, S_W_AW, S_W_RW, S_R_AW, S_R_RW:
                st_errcls = (m_ecode == 2'd1) ? 3'd1 :
                            ((m_ecode == 2'd2) ? 3'd3 : 3'd4);
            S_C_PTR, S_C_HI, S_C_LO, S_W_PTR:
                st_errcls = (m_ecode == 2'd1) ? 3'd2 :
                            ((m_ecode == 2'd2) ? 3'd3 : 3'd4);
            default:
                st_errcls = (m_ecode == 2'd2) ? 3'd3 : 3'd4;
        endcase
    end

    //-------------------------------------------------------------------------
    // 主时序
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            state         <= S_IDLE;
            issued        <= 1'b0;
            iss_cnt       <= 2'd0;
            saw_busy      <= 1'b0;
            m_valid       <= 1'b0;
            m_cmd         <= 3'd0;
            m_wdata       <= 8'h00;
            m_nack        <= 1'b0;
            ch            <= 2'd0;
            ch0_q         <= 16'h0000;
            ch1_q         <= 16'h0000;
            ch2_q         <= 16'h0000;
            poll_hi       <= 8'h00;
            poll_lo       <= 8'h00;
            raw_hi        <= 8'h00;
            raw_lo        <= 8'h00;
            os_ready_flag <= 1'b0;
            wait_active   <= 1'b0;
            wait_cnt      <= {WAIT_BITS{1'b0}};
            err_code_q    <= 3'd0;
            r_sample_valid<= 1'b0;
            r_busy        <= 1'b0;
            r_error       <= 1'b0;
            r_errcode     <= 3'd0;
        end else begin
            r_sample_valid <= 1'b0;       // 单周期脉冲
            r_error        <= 1'b0;       // 单周期脉冲

            if (wait_active) begin
                if (!wait_timeout) begin
                    wait_cnt <= wait_cnt + 1'b1;
                end
            end

            case (state)

            //-------------------------------------------------------------
            // 非命令状态
            //-------------------------------------------------------------
            S_IDLE: begin
                // 粘滞错误码保留,直到下一次帧成功(S_VALID)才清零
                ch      <= 2'd0;
                r_busy  <= 1'b1;
                state   <= S_C_START;
            end

            S_W_CHK: begin
                wait_active   <= (poll_hi[7] != 1'b1);  // 未就绪:计时跨 poll 连续累计
                // OS 位 = Config 高字节的 bit7(MSB),不是 [15]!
                os_ready_flag <= (poll_hi[7] == 1'b1);
                if (poll_hi[7] == 1'b1) begin
                    state <= S_W_STOP;              // 转换完成:收尾轮询事务
                end else if (wait_timeout) begin
                    err_code_q <= 3'd4;             // 转换等待超时
                    state      <= S_ERR_STOP;
                end else begin
                    // 未就绪:也必须先 STOP 关闭本轮轮询事务(xact=1 时
                    // master 拒绝新的 START),再由 S_W_STOP 决定重新轮询
                    state <= S_W_STOP;
                end
            end

            S_VALID: begin
                r_sample_valid <= 1'b1;
                r_errcode      <= 3'd0;             // 本帧全绿:清粘滞错误码
                ch             <= 2'd0;
                state          <= S_C_START;        // 连续扫描下一帧
            end

            S_ERR: begin
                r_error   <= 1'b1;
                r_errcode <= err_code_q;
                r_busy    <= 1'b0;
                state     <= S_IDLE;
            end

            //-------------------------------------------------------------
            // 命令状态:发命令 -> 等 master 完成 -> 检查结果。
            // 完成判定有两条路:
            //   a) 观察到 ready 拉低后(saw_busy)再回到 1 —— 正常长命令;
            //   b) 发出 >=2 拍后 ready 一直保持 1 —— 即时完成(master 在
            //      IDLE 拒绝协议错误命令时 cmd_ready 从不拉低,错误码当拍
            //      已更新,晚一拍采样保证读到的是本次命令的结果)。
            //-------------------------------------------------------------
            default: begin
                if (!issued) begin
                    if (m_ready) begin
                        m_valid <= 1'b1;
                        m_cmd   <= st_cmd;
                        m_wdata <= st_wdata;
                        m_nack  <= st_nack;
                        issued  <= 1'b1;
                        iss_cnt <= 2'd0;
                    end
                end else begin
                    m_valid <= 1'b0;
                    iss_cnt <= iss_cnt + 2'd1;
                    if (!m_ready) begin
                        saw_busy <= 1'b1;
                    end else if (saw_busy || (iss_cnt >= 2'd2)) begin
                        issued   <= 1'b0;
                        saw_busy <= 1'b0;
                        if (state == S_ERR_STOP) begin
                            // 收尾 STOP:master 可能回协议错误(xact 已关),无视
                            state <= S_ERR;
                        end else if (m_ecode != 2'd0) begin
                            wait_active <= 1'b0;
                            err_code_q  <= st_errcls;
                            state       <= S_ERR_STOP;
                        end else begin
                            case (state)
                                S_C_LO: begin       // 配置写入完成:开始等转换
                                    wait_cnt    <= {WAIT_BITS{1'b0}};
                                    wait_active <= 1'b1;
                                end
                                S_W_MSB: poll_hi <= m_rdata;
                                S_W_LSB: poll_lo <= m_rdata;
                                S_R_MSB: raw_hi  <= m_rdata;
                                S_R_LSB: raw_lo  <= m_rdata;
                                default: ;
                            endcase

                            if (state == S_W_STOP) begin
                                state <= os_ready_flag ? S_R_START : S_W_START;
                            end else if (state == S_R_STOP) begin
                                case (ch)
                                    2'd0:    ch0_q <= {raw_hi, raw_lo};
                                    2'd1:    ch1_q <= {raw_hi, raw_lo};
                                    default: ch2_q <= {raw_hi, raw_lo};
                                endcase
                                if (ch == 2'd2) begin
                                    state <= S_VALID;
                                end else begin
                                    ch    <= ch + 2'd1;
                                    state <= S_C_START;
                                end
                            end else begin
                                state <= st_next;
                            end
                        end
                    end
                end
            end

            endcase
        end
    end

    // 输出连线
    assign adc_ch0_raw      = ch0_q;
    assign adc_ch1_raw      = ch1_q;
    assign adc_ch2_raw      = ch2_q;
    assign adc_sample_valid = r_sample_valid;
    assign adc_busy         = r_busy;
    assign adc_error        = r_error;
    assign error_code       = r_errcode;

        end
    endgenerate

endmodule
