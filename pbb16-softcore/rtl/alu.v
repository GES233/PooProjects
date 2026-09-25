`timescale 1ns/1ps
// alu.v — PBB16 v2 组合逻辑 ALU
// 覆盖规格 3.4 全部 R 型运算（XCHG 在控制层用两次写回实现，不进 ALU）
// 及 3.5 立即数移位（b 端口给移位量）；另含内部扩展 PASSB/MOVUI。
// 标志规则：
//   Z = 结果为 0；S = 结果最高位
//   C：加/减 = 进位/无借位（a>=b 无符号）；移位 = 最后移出位；其余 = 0
//   V：加/减 = 有符号溢出；CMPU = 0；其余 = 0
//   DIV 除零 -> 0xFFFF；REM 除零 -> 被除数（RISC-V 规则，规格 7.4）
`include "pbb16_defs.vh"

module alu (
    input  wire [4:0]  op,
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire        cin,   // 当前 C 标志（ADC/SBB 用）
    output reg  [15:0] y,
    output reg         z,
    output reg         s,
    output reg         c,
    output reg         v
);

    wire [3:0]  n     = b[3:0];             // 移位量
    wire [31:0] mul32 = a * b;
    wire [16:0] add17 = {1'b0, a} + {1'b0, b} + ((op == `ALU_ADC) ? cin : 1'b0);
    wire [16:0] sub17 = {1'b0, a} - {1'b0, b} - ((op == `ALU_SBB) ? cin : 1'b0);

    always @(*) begin
        y = 16'h0000;
        c = 1'b0;
        v = 1'b0;
        case (op)
            `ALU_ADD, `ALU_ADC: begin
                y = add17[15:0];
                c = add17[16];
                v = (a[15] == b[15]) && (y[15] != a[15]);
            end
            `ALU_SUB, `ALU_SBB, `ALU_CMP, `ALU_CMPU: begin
                y = sub17[15:0];
                c = ~sub17[16];                     // 无借位
                v = (op == `ALU_CMPU) ? 1'b0
                    : ((a[15] != b[15]) && (y[15] != a[15]));
            end
            `ALU_MUL: y = mul32[15:0];
            `ALU_MLH: y = mul32[31:16];
            `ALU_DIV: y = (b == 16'h0000) ? 16'hFFFF : a / b;
            `ALU_REM: y = (b == 16'h0000) ? a        : a % b;
            `ALU_AND:  y = a & b;
            `ALU_OR:   y = a | b;
            `ALU_XOR:  y = a ^ b;
            `ALU_NAND: y = ~(a & b);
            `ALU_NOR:  y = ~(a | b);
            `ALU_NOT:  y = ~b;                      // R[rd] = ~R[rs]
            `ALU_MOV, `ALU_PASSB: y = b;
            `ALU_MOVUI: y = {b[7:0], 8'h00};
            `ALU_SHL: begin
                y = a << n;
                c = (n == 4'd0) ? 1'b0 : a[16 - n]; // 最后移出位
            end
            `ALU_SHR: begin
                y = a >> n;
                c = (n == 4'd0) ? 1'b0 : a[n - 1];
            end
            `ALU_SAR: begin
                y = $signed(a) >>> n;
                c = (n == 4'd0) ? 1'b0 : a[n - 1];
            end
            `ALU_ROL: begin
                y = (n == 4'd0) ? a : ((a << n) | (a >> (16 - n)));
                c = (n == 4'd0) ? 1'b0 : a[16 - n];
            end
            `ALU_ROR: begin
                y = (n == 4'd0) ? a : ((a >> n) | (a << (16 - n)));
                c = (n == 4'd0) ? 1'b0 : a[n - 1];
            end
            default: y = 16'h0000;
        endcase
        z = (y == 16'h0000);
        s = y[15];
    end

endmodule
