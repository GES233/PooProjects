`timescale 1ns/1ps
// timer.v — PBB16 v3 MMIO 定时器（槽 1，基址 0xF010，规格 9.4）
// 寄存器（16 位字）：
//   偏移 0x0 PERIOD  (R/W) 周期（时钟数），写时计数器清零；0 = 不触发
//   偏移 0x2 CONTROL (R/W) bit0 enable、bit1 ie（中断使能）
//   偏移 0x4 STATUS  (R)   bit0 pending（到期挂起，读后清零，电平型）
// enable=1 时计数器每 clk 自增，到 PERIOD-1 → pending←1、计数器归零
// （自动重载，周期性触发）；enable=0 时计数器保持 0。
// irq = pending & ie（接内核 irq[1]）。到期与读 STATUS 同拍时到期优先。
// 字节访问语义与 uart.v 一致：字节读按小端取高低字节（zext），偶地址字节写写低字节。
module timer (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sel,
    input  wire [3:0]  addr,     // 设备内字节偏移
    input  wire [15:0] wdata,
    input  wire        we,
    input  wire        re,
    input  wire        size,     // 1 = 字，0 = 字节
    output wire [15:0] rdata,

    output wire        irq
);

    reg [15:0] period;
    reg [15:0] cnt;
    reg        enable, ie, pending;

    wire [2:0] offset = addr[3:1];
    wire       wr     = sel && we && (size || !addr[0]);
    wire       rd     = sel && re;                  // 读侧不查 size（同 uart）

    // 到期：enable 且 PERIOD≠0 且计数到底
    wire fire = enable && (period != 16'd0) && (cnt == period - 16'd1);

    // 寄存器读 mux（字视图）
    reg [15:0] reg_word;
    always @(*) begin
        case (offset)
            3'd0:    reg_word = period;                     // PERIOD
            3'd1:    reg_word = {14'h0000, ie, enable};     // CONTROL
            3'd2:    reg_word = {15'h0000, pending};        // STATUS
            default: reg_word = 16'h0000;
        endcase
    end

    // 字节读按小端取高低字节（与 RAM/uart 字节语义一致）
    assign rdata = size ? reg_word
                        : (addr[0] ? {8'h00, reg_word[15:8]}
                                   : {8'h00, reg_word[7:0]});

    assign irq = pending & ie;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            period  <= 16'd0;
            cnt     <= 16'd0;
            enable  <= 1'b0;
            ie      <= 1'b0;
            pending <= 1'b0;
        end else begin
            // 计数与到期（自动重载）
            if (enable && (period != 16'd0)) begin
                if (fire) cnt <= 16'd0;
                else      cnt <= cnt + 16'd1;
            end
            // pending：到期置位优先，其次读 STATUS 清零
            if (fire)                              pending <= 1'b1;
            else if (rd && (offset == 3'd2))       pending <= 1'b0;
            // 寄存器写（优先于本拍计数）
            if (wr && (offset == 3'd0)) begin
                period <= wdata;
                cnt    <= 16'd0;
            end
            if (wr && (offset == 3'd1)) begin
                enable <= wdata[0];
                ie     <= wdata[1];
                if (!wdata[0]) cnt <= 16'd0;   // 禁用时计数器清零
            end
        end
    end

endmodule
