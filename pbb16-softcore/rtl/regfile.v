`timescale 1ns/1ps
// regfile.v — PBB16 v2 通用寄存器组 R0–R7
// 三个异步读端口 + 一个同步写端口（第三读口供 v3 远访存地址对高位用）
// 复位：R6(SP) = 0xFFFE（规格 7.1），其余 = 0
module regfile (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  raddr1,
    input  wire [2:0]  raddr2,
    output wire [15:0] rdata1,
    output wire [15:0] rdata2,
    input  wire        we,
    input  wire [2:0]  waddr,
    input  wire [15:0] wdata,

    // 第三读口（v3：远访存地址寄存器对的高位寄存器，纯组合读）
    input  wire [2:0]  raddr3,
    output wire [15:0] rdata3
);

    reg [15:0] regs [0:7];
    integer i;

    assign rdata1 = regs[raddr1];
    assign rdata2 = regs[raddr2];
    assign rdata3 = regs[raddr3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 8; i = i + 1)
                regs[i] <= 16'h0000;
            regs[6] <= 16'hFFFE;    // SP 复位到 64K 空间栈顶
        end else if (we) begin
            regs[waddr] <= wdata;
        end
    end

endmodule
