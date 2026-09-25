`timescale 1ns/1ps
// bus.v — PBB16 v3 地址译码总线（规格第 9 节，纯组合、可综合）
//
// 内核输出 22 位物理地址（banking 翻译在核内完成，规格第 8 节）：
//   MAPE=0 直通：phys = {6'h00, 逻辑地址}，地址映射与 v2 相同：
//     0x0000-0xEFFF  RAM（56KB）
//     0xF000-0xFEFF  MMIO 外设区（4KB，每设备 16 字节，槽 i 基址 0xF000+i*0x10）
//     0xFF00-0xFFFF  RAM 保留页（256B，异常向量 0xFF00 在 RAM）
//   MAPE=1 映射：整个 64KB 逻辑空间（含 MMIO 窗口）都已被核内重映射到 4MB
//     物理 RAM，本模块见到的是重映射后的物理地址 —— MMIO 因此天然不可达
//     （mape 输入门控译码，防 bank 号 = 0 时物理地址巧合落进 0xF000 窗口）。
//   mem_far=1（远访存）：直达物理 RAM，绕过 MMIO 译码与 banking。
// MMIO 空洞（0xF080-0xFEFF，槽 8 起未接设备）：读返回 0、写忽略，不异常。
// 对齐规则与 RAM 一致：字访问奇地址的未对齐异常由内核判定，本模块不重复。
module bus (
    // 内核侧（22 位物理地址）
    input  wire [21:0] mem_addr,
    input  wire [15:0] mem_wdata,
    input  wire        mem_we,
    input  wire        mem_re,
    input  wire        mem_size,   // 1 = 字，0 = 字节
    input  wire        mem_far,    // 1 = 远访存（绕过 MMIO）
    input  wire        mape,       // Status.MAPE（1 = 映射态，MMIO 不可达）
    output wire [15:0] mem_rdata,

    // RAM 侧（4MB 物理空间）
    output wire [21:0] ram_addr,
    output wire [15:0] ram_wdata,
    output wire        ram_we,
    output wire        ram_re,
    output wire        ram_size,
    input  wire [15:0] ram_rdata,

    // 设备槽（共享信号 + 每槽选择线；槽 0 = UART，1-7 预留）
    output wire [7:0]  dev_sel,
    output wire [3:0]  dev_addr,   // 设备内字节偏移
    output wire [15:0] dev_wdata,
    output wire        dev_we,
    output wire        dev_re,
    output wire        dev_size,
    input  wire [15:0] dev0_rdata,
    input  wire [15:0] dev1_rdata,
    input  wire [15:0] dev2_rdata,
    input  wire [15:0] dev3_rdata,
    input  wire [15:0] dev4_rdata,
    input  wire [15:0] dev5_rdata,
    input  wire [15:0] dev6_rdata,
    input  wire [15:0] dev7_rdata
);

    // 0xF000-0xFEFF：高 4 位全 1 且 bit11:8 不全 1（0xFF00 起归 RAM）；
    // 仅直通态（mape=0）的近访问才可能是 MMIO
    wire is_mmio = !mem_far && !mape
                && (mem_addr[15:12] == 4'hF) && (mem_addr[11:8] != 4'hF);
    wire is_hole = is_mmio && mem_addr[7];          // 0xF080-0xFEFF
    wire [2:0] slot  = mem_addr[6:4];               // 16 字节一个槽

    assign dev_sel   = (is_mmio && !is_hole) ? (8'h01 << slot) : 8'h00;
    assign dev_addr  = mem_addr[3:0];
    assign dev_wdata = mem_wdata;
    assign dev_we    = mem_we;
    assign dev_re    = mem_re;
    assign dev_size  = mem_size;

    assign ram_addr  = mem_addr;
    assign ram_wdata = mem_wdata;
    assign ram_we    = mem_we && !is_mmio;
    assign ram_re    = mem_re && !is_mmio;
    assign ram_size  = mem_size;

    reg [15:0] dev_rdata;
    always @(*) begin
        case (slot)
            3'd0:    dev_rdata = dev0_rdata;
            3'd1:    dev_rdata = dev1_rdata;
            3'd2:    dev_rdata = dev2_rdata;
            3'd3:    dev_rdata = dev3_rdata;
            3'd4:    dev_rdata = dev4_rdata;
            3'd5:    dev_rdata = dev5_rdata;
            3'd6:    dev_rdata = dev6_rdata;
            default: dev_rdata = dev7_rdata;
        endcase
    end

    assign mem_rdata = is_mmio ? (is_hole ? 16'h0000 : dev_rdata)
                               : ram_rdata;

endmodule
