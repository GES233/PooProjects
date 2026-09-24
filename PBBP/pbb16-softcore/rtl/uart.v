`timescale 1ns/1ps
// uart.v — PBB16 v2 MMIO UART（简化 16550 风格，规格 9.2）
// 挂总线设备槽 0（基址 0xF000），寄存器按 16 位字寻址：
//   偏移 0x0 RXDATA  (R)  低 8 位接收字节，读后清 rx_ready（弹出）
//   偏移 0x2 TXDATA  (W)  低 8 位写入即发送
//   偏移 0x4 STATUS  (R)  bit0 rx_ready、bit1 tx_ready（恒 1）
//   偏移 0x6 CONTROL (R/W) bit0 接收中断使能 ie
// 中断：irq = rx_ready & ie（接内核 irq[0]）。
// 字节访问：字节读按小端取对应字节（zext）；字节写偶地址等效写低字节。
// 仿真行为（ifndef SYNTHESIS 隔离）：写 TXDATA 用 $write 输出并记录 tx_log；
// RX FIFO（rx_fifo/rx_wr）由 testbench 预载/注入，本模块只弹出（rx_rd）。
module uart (
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

    reg        ie;
    reg [7:0]  rx_fifo [0:15];
    reg [4:0]  rx_wr;            // 写指针：仅 testbench 驱动（仿真接收注入）
    reg [4:0]  rx_rd;            // 读指针：本模块维护

    wire rx_ready = (rx_wr != rx_rd);
    wire [2:0] offset = addr[3:1];
    wire [7:0] rx_head = rx_fifo[rx_rd[3:0]];   // 连续赋值读数组，避免 @* 对数组敏感

    // 寄存器读 mux（字视图）
    reg [15:0] reg_word;
    always @(*) begin
        case (offset)
            3'd0:    reg_word = {8'h00, rx_ready ? rx_head : 8'h00}; // RXDATA
            3'd1:    reg_word = 16'h0000;                     // TXDATA（只写，读 0）
            3'd2:    reg_word = {14'h0000, 1'b1, rx_ready};   // STATUS
            3'd3:    reg_word = {15'h0000, ie};               // CONTROL
            default: reg_word = 16'h0000;
        endcase
    end

    // 字节读按小端取高低字节（与 RAM 字节语义一致，MMIO 友好）
    assign rdata = size ? reg_word
                        : (addr[0] ? {8'h00, reg_word[15:8]}
                                   : {8'h00, reg_word[7:0]});

    assign irq = rx_ready & ie;

    wire rx_pop  = sel && re && (offset == 3'd0);
    wire tx_push = sel && we && (offset == 3'd1) && (size || !addr[0]);
    wire ctrl_wr = sel && we && (offset == 3'd3) && (size || !addr[0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ie    <= 1'b0;
            rx_rd <= 5'd0;
        end else begin
            if (rx_pop && rx_ready) rx_rd <= rx_rd + 5'd1;
            if (ctrl_wr)            ie    <= wdata[0];
        end
    end

`ifndef SYNTHESIS
    // ---- 仿真行为：发送记录 + 终端回显 ----
    reg [7:0] tx_log [0:255];
    integer   tx_count;
    initial tx_count = 0;
    always @(posedge clk) begin
        if (tx_push) begin
            $write("%c", wdata[7:0]);
            tx_log[tx_count] = wdata[7:0];
            tx_count = tx_count + 1;
        end
    end
`endif

endmodule
