// tb_memmap.v — PBB16 v3 内存映射系统级 testbench（banking + 远访存）
// 结构：内核 pbb16 + 总线 bus + 4MB 行为级 RAM + UART（设备槽 0）。
// 程序由 asm/test_memmap.asm 汇编生成（$readmemh 加载），覆盖：
//   a) CR4-7 复位值        b) banking 重映射       c) 远字往返（>64KB）
//   d) 远字节 + 别名一致   e) MAPE=1 时 MMIO 不可达 f) TRAP 的 MAPE 影子联动
//   g) 远字访存奇地址 → excode=3
// 自检：程序把通过位置进 R7 bit0..bit6，TB 停机后逐项打印；
// 另直接检查物理内存单元（0x4000/0x8000/0x100000）与 UART 未发字节。
// 注意 vvp 工作目录须为 pbb16-softcore/。
`timescale 1ns/1ps

module tb_memmap;

    reg clk = 1'b0;
    reg rst_n;
    always #5 clk = ~clk;

    // ---- 内核 <-> 总线 ----
    wire [21:0] mem_addr;
    wire [15:0] mem_wdata, mem_rdata;
    wire        mem_we, mem_re, mem_size, mem_far, mape;
    wire        halted;

    pbb16 core (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_size(mem_size),
        .mem_far(mem_far), .mape_o(mape),
        .mem_rdata(mem_rdata), .irq(4'b0000), .halted(halted)
    );

    // ---- 总线 ----
    wire [21:0] ram_addr;
    wire [15:0] ram_wdata, ram_rdata;
    wire        ram_we, ram_re, ram_size;
    wire [7:0]  dev_sel;
    wire [3:0]  dev_addr;
    wire [15:0] dev_wdata, uart_rdata;
    wire        dev_we, dev_re, dev_size;

    bus bus_i (
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_size(mem_size),
        .mem_far(mem_far), .mape(mape),
        .mem_rdata(mem_rdata),
        .ram_addr(ram_addr), .ram_wdata(ram_wdata),
        .ram_we(ram_we), .ram_re(ram_re), .ram_size(ram_size),
        .ram_rdata(ram_rdata),
        .dev_sel(dev_sel), .dev_addr(dev_addr),
        .dev_wdata(dev_wdata), .dev_we(dev_we), .dev_re(dev_re),
        .dev_size(dev_size),
        .dev0_rdata(uart_rdata),
        .dev1_rdata(16'h0000), .dev2_rdata(16'h0000),
        .dev3_rdata(16'h0000), .dev4_rdata(16'h0000),
        .dev5_rdata(16'h0000), .dev6_rdata(16'h0000),
        .dev7_rdata(16'h0000)
    );

    // ---- 行为级 RAM：4MB 物理空间（22 位字节地址，小端） ----
    reg [7:0] mem [0:4194303];

    assign ram_rdata = ram_size ? {mem[ram_addr + 22'd1], mem[ram_addr]}
                                : {8'h00, mem[ram_addr]};
    always @(posedge clk) begin
        if (ram_we) begin
            mem[ram_addr] <= ram_wdata[7:0];
            if (ram_size) mem[ram_addr + 22'd1] <= ram_wdata[15:8];
        end
    end

    // ---- UART（槽 0，仅用于验证映射态下 MMIO 不可达） ----
    uart uart0 (
        .clk(clk), .rst_n(rst_n),
        .sel(dev_sel[0]), .addr(dev_addr),
        .wdata(dev_wdata), .we(dev_we), .re(dev_re), .size(dev_size),
        .rdata(uart_rdata), .irq()
    );

    integer i;
    integer cycles;
    integer errors;

    task check_bit(input integer bitno, input [8*56-1:0] name);
        begin
            if (core.rf.regs[7][bitno])
                $display("  [OK] %0s", name);
            else begin
                $display("  [FAIL] %0s (R7 bit%0d = 0)", name, bitno);
                errors = errors + 1;
            end
        end
    endtask

    task check_word(input [21:0] a, input [15:0] exp, input [8*56-1:0] name);
        begin
            if ({mem[a + 22'd1], mem[a]} === exp)
                $display("  [OK] %0s (@%h = %h)", name, a, exp);
            else begin
                $display("  [FAIL] %0s (@%h = %h, expect %h)",
                         name, a, {mem[a + 22'd1], mem[a]}, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;  // 低 64KB 清零
        $readmemh("asm/test_memmap.hex", mem);

        cycles = 0;
        errors = 0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        $display("== tb_memmap: start ==");

        while (!halted && cycles < 50000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(posedge clk);

        $display("");
        $display("== tb_memmap: finish, cycles=%0d, R7=%h ==", cycles, core.rf.regs[7]);

        check_bit(0, "a) CR4-7 reset values 0/1/2/3");
        check_bit(1, "b) banking: BANK1=2, logical 0x4000 -> phys 0x8000");
        check_bit(2, "c) FSTR.W/FLOD.W roundtrip at phys 0x100000");
        check_bit(3, "d) FSTR.B + banked LOD.B alias consistency");
        check_bit(4, "e) MMIO unreachable under MAPE=1 (RAM alias)");
        check_bit(5, "f) TRAP: MAPS<-MAPE, MAPE<-0; ERET restores MAPE");
        check_bit(6, "g) FLOD.W odd phys addr -> excode=3");

        // 直接检查：物理内存单元（与逻辑视角一一对应）
        check_word(22'h004000, 16'h1111, "phys 0x004000 (pass-through copy)");
        check_word(22'h008000, 16'h2222, "phys 0x008000 (bank2 window1 copy)");
        check_word(22'h100000, 16'h6666, "phys 0x100000 (far/banked alias)");

        // 直接检查：映射态下写 UART 槽未产生任何 TX
        if (uart0.tx_count == 0) $display("  [OK] UART tx_count = 0 (no TX under MAPE=1)");
        else begin
            $display("  [FAIL] UART tx_count = %0d (expect 0)", uart0.tx_count);
            errors = errors + 1;
        end

        if (halted) $display("  [OK] CPU halted");
        else begin $display("  [FAIL] CPU not halted (timeout)"); errors = errors + 1; end

        if (core.rf.regs[6] === 16'hFFFE) $display("  [OK] R6(SP) = %h", core.rf.regs[6]);
        else begin $display("  [FAIL] R6(SP) = %h (expect FFFE)", core.rf.regs[6]); errors = errors + 1; end

        if (errors == 0) $display("== tb_memmap: PASS ==");
        else             $display("== tb_memmap: FAIL (%0d errors) ==", errors);
        $finish;
    end

endmodule
