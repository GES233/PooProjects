// tb_phase2.v — PBB16 v2 第二阶段系统级 testbench
// 程序由 asm/test_phase2.asm 汇编生成（$readmemh 加载），覆盖：
//   a) 字访存往返+小端  b) 字节访存(奇地址)  c) 未对齐异常(excode=3)
//   d) PUSH/POP  e) CALL/RET 嵌套  f) JR  g) MFC/MTC  h) TRAP  i) 外部中断
//   j) 非法指令(excode=4)
// 自检协议：程序把通过位置进 R7 bit0..bit9，本 TB 在停机后逐项解码打印，
// 并直接检查 R6(SP)、数据内存单元与停机状态。
//
// TB 与程序的中断协同：程序在 0x0180 窗口（IE=1、IM 屏蔽 irq0）和
// 0x01C0 等待循环（放行 irq0）运行；TB 按 dut.pc 驱动 irq0。
// 注意 vvp 工作目录须为 pbb16-softcore/。
`timescale 1ns/1ps

module tb_phase2;

    reg clk = 1'b0;
    reg rst_n;
    always #5 clk = ~clk;

    // ---- 行为级内存：64K 字节，小端 ----
    reg [7:0] mem [0:65535];

    wire [21:0] mem_addr;   // v3：22 位物理地址（直通态低 16 位 == 逻辑地址）
    wire [15:0] mem_wdata, mem_rdata;
    wire        mem_we, mem_re, mem_size, halted;
    reg  [3:0]  irq;

    assign mem_rdata = mem_size ? {mem[mem_addr[15:0] + 16'd1], mem[mem_addr[15:0]]}
                                : {8'h00, mem[mem_addr[15:0]]};

    always @(posedge clk) begin
        if (mem_we) begin
            mem[mem_addr[15:0]] <= mem_wdata[7:0];
            if (mem_size) mem[mem_addr[15:0] + 16'd1] <= mem_wdata[15:8];
        end
    end

    pbb16 dut (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_size(mem_size),
        .mem_far(), .mape_o(),
        .mem_rdata(mem_rdata), .irq(irq), .halted(halted)
    );

    integer i;
    integer cycles;
    integer errors;

    // ---- 中断驱动：按 PC 窗口拉 irq0 ----
    // 屏蔽窗口 [0x0180,0x0190)：程序 IE=1 但 IM 屏蔽 irq0，不应触发；
    // 等待循环 [0x01C0,0x01C2]：放行 irq0，保持到异常进入（excode 变 1）。
    always @(posedge clk) begin
        if (!rst_n)
            irq <= 4'b0000;
        else if (dut.pc >= 16'h0180 && dut.pc < 16'h0190)
            irq <= 4'b0001;
        else if (dut.pc >= 16'h01C0 && dut.pc <= 16'h01C2 &&
                 dut.cr_excode != 3'd1)
            irq <= 4'b0001;
        else
            irq <= 4'b0000;
    end

    // 每项子测试 [OK]/[FAIL] 打印（基于 R7 通过位）
    task check_bit(input integer bitno, input [8*56-1:0] name);
        begin
            if (dut.rf.regs[7][bitno])
                $display("  [OK] %0s", name);
            else begin
                $display("  [FAIL] %0s (R7 bit%0d = 0)", name, bitno);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        $readmemh("asm/test_phase2.hex", mem);

        cycles = 0;
        errors = 0;
        irq    = 4'b0000;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        $display("== tb_phase2: start ==");

        while (!halted && cycles < 200000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(posedge clk);

        $display("== tb_phase2: finish, cycles=%0d, R7=%h ==", cycles, dut.rf.regs[7]);

        check_bit(0, "a) STR.W/LOD.W roundtrip + little-endian");
        check_bit(1, "b) STR.B/LOD.B odd address");
        check_bit(2, "c) misaligned word access -> excode=3, EPC, ERET retry");
        check_bit(3, "d) PUSH/POP sequence");
        check_bit(4, "e) CALL/RET two-level nesting");
        check_bit(5, "f) JR register jump");
        check_bit(6, "g) MFC PRID + MTC/MFC Status roundtrip");
        check_bit(7, "h) TRAP -> excode=2, ERET return");
        check_bit(8, "i) external irq (masked + unmasked)");
        check_bit(9, "j) illegal instruction -> excode=4");

        // 直接检查 1：进入停机状态
        if (halted) $display("  [OK] CPU halted");
        else begin $display("  [FAIL] CPU not halted (timeout)"); errors = errors + 1; end

        // 直接检查 2：R6(SP) 归位 0xFFFE（PUSH/POP、CALL/RET 均平衡）
        if (dut.rf.regs[6] === 16'hFFFE) $display("  [OK] R6(SP) = %h", dut.rf.regs[6]);
        else begin $display("  [FAIL] R6(SP) = %h (expect FFFE)", dut.rf.regs[6]); errors = errors + 1; end

        // 直接检查 3：数据内存单元（字存取小端持久化 + 字节写）
        if (mem[16'h0300] === 8'h34 && mem[16'h0301] === 8'h12)
            $display("  [OK] MEM16[0x0300] = 1234 (little-endian)");
        else begin
            $display("  [FAIL] MEM[0x0300]=%h MEM[0x0301]=%h (expect 34/12)",
                     mem[16'h0300], mem[16'h0301]);
            errors = errors + 1;
        end
        if (mem[16'h0303] === 8'hAB) $display("  [OK] MEM8[0x0303] = AB");
        else begin
            $display("  [FAIL] MEM[0x0303]=%h (expect AB)", mem[16'h0303]);
            errors = errors + 1;
        end

        // 直接检查 4：停机后 EXL 已被异常路径正确清理（h_ill 手动清 0）
        if (dut.cr_exl === 1'b0) $display("  [OK] EXL = 0 at halt");
        else begin $display("  [FAIL] EXL = 1 at halt"); errors = errors + 1; end

        if (errors == 0) $display("== tb_phase2: PASS ==");
        else             $display("== tb_phase2: FAIL (%0d errors) ==", errors);
        $finish;
    end

endmodule
