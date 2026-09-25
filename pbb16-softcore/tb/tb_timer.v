// tb_timer.v — PBB16 v3 定时器（槽 1）系统级 testbench
// 结构：内核 pbb16 + 总线 bus + 64KB 行为级 RAM + timer（设备槽 1，irq[1]）。
// 程序由 asm/test_timer.asm 汇编生成（$readmemh 加载），覆盖：
//   a) 轮询：到期置位、读后清零   b) 中断 ×2（excode=1、IP bit5、ERET 返回）
//   c) enable=0 后不再到期
// 自检：程序把通过位置进 R7 bit0..bit2，TB 停机后逐项打印。
// 注意 vvp 工作目录须为 pbb16-softcore/。
`timescale 1ns/1ps

module tb_timer;

    reg clk = 1'b0;
    reg rst_n;
    always #5 clk = ~clk;

    // ---- 内核 <-> 总线 ----
    wire [21:0] mem_addr;
    wire [15:0] mem_wdata, mem_rdata;
    wire        mem_we, mem_re, mem_size, mem_far, mape;
    wire [3:0]  core_irq;
    wire        halted;

    pbb16 core (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_size(mem_size),
        .mem_far(mem_far), .mape_o(mape),
        .mem_rdata(mem_rdata), .irq(core_irq), .halted(halted)
    );

    // ---- 总线 ----
    wire [21:0] ram_addr;
    wire [15:0] ram_wdata, ram_rdata;
    wire        ram_we, ram_re, ram_size;
    wire [7:0]  dev_sel;
    wire [3:0]  dev_addr;
    wire [15:0] dev_wdata, timer_rdata;
    wire        dev_we, dev_re, dev_size;
    wire        timer_irq;

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
        .dev0_rdata(16'h0000), .dev1_rdata(timer_rdata),
        .dev2_rdata(16'h0000), .dev3_rdata(16'h0000),
        .dev4_rdata(16'h0000), .dev5_rdata(16'h0000),
        .dev6_rdata(16'h0000), .dev7_rdata(16'h0000)
    );

    assign core_irq = {2'b00, timer_irq, 1'b0};   // 定时器接 irq[1]

    // ---- 行为级 RAM：64K 字节，小端（直通态，取低 16 位索引） ----
    reg [7:0] mem [0:65535];

    assign ram_rdata = ram_size ? {mem[ram_addr[15:0] + 16'd1], mem[ram_addr[15:0]]}
                                : {8'h00, mem[ram_addr[15:0]]};
    always @(posedge clk) begin
        if (ram_we) begin
            mem[ram_addr[15:0]] <= ram_wdata[7:0];
            if (ram_size) mem[ram_addr[15:0] + 16'd1] <= ram_wdata[15:8];
        end
    end

    // ---- 定时器（槽 1） ----
    timer timer0 (
        .clk(clk), .rst_n(rst_n),
        .sel(dev_sel[1]), .addr(dev_addr),
        .wdata(dev_wdata), .we(dev_we), .re(dev_re), .size(dev_size),
        .rdata(timer_rdata), .irq(timer_irq)
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

    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        $readmemh("asm/test_timer.hex", mem);

        cycles = 0;
        errors = 0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        $display("== tb_timer: start ==");

        while (!halted && cycles < 50000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(posedge clk);

        $display("");
        $display("== tb_timer: finish, cycles=%0d, R7=%h ==", cycles, core.rf.regs[7]);

        check_bit(0, "a) polling: pending set, cleared on read");
        check_bit(1, "b) interrupt x2: excode=1, IP bit5, ERET return");
        check_bit(2, "c) no expiry while disabled");

        if (halted) $display("  [OK] CPU halted");
        else begin $display("  [FAIL] CPU not halted (timeout)"); errors = errors + 1; end

        if (core.rf.regs[6] === 16'hFFFE) $display("  [OK] R6(SP) = %h", core.rf.regs[6]);
        else begin $display("  [FAIL] R6(SP) = %h (expect FFFE)", core.rf.regs[6]); errors = errors + 1; end

        if (errors == 0) $display("== tb_timer: PASS ==");
        else             $display("== tb_timer: FAIL (%0d errors) ==", errors);
        $finish;
    end

endmodule
