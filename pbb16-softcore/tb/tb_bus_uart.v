// tb_bus_uart.v — PBB16 v2 第三阶段系统级 testbench
// 结构：内核 pbb16 + 总线 bus + 64KB 行为级 RAM + UART（设备槽 0）。
// 程序由 asm/test_bus_uart.asm 汇编生成（$readmemh 加载），覆盖：
//   a) STR.B 写 TXDATA 输出 "PBB16 OK\n"（TB 对 tx_log 逐字节验证）
//   b) RX 轮询读 'A','B'（TB 预载 RX FIFO）
//   c) RX 接收中断（TB 在 0x01C0 等待循环窗口注入 'X'）
//   d) MMIO 空洞读 0/写忽略   e) MMIO 字访问奇地址 → excode=3
// 自检：程序把通过位置进 R7 bit0..bit4，TB 停机后逐项打印。
// 注意 vvp 工作目录须为 pbb16-softcore/。
`timescale 1ns/1ps

module tb_bus_uart;

    reg clk = 1'b0;
    reg rst_n;
    always #5 clk = ~clk;

    // ---- 内核 <-> 总线 ----
    wire [21:0] mem_addr;   // v3：22 位物理地址
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
    wire [15:0] dev_wdata, uart_rdata;
    wire        dev_we, dev_re, dev_size;
    wire        uart_irq;

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

    assign core_irq = {3'b000, uart_irq};   // UART 接 irq[0]

    // ---- 行为级 RAM：64K 字节，小端（两段地址在内部统一） ----
    // v3：bus 输出 22 位物理地址，本 TB 直通态运行，取低 16 位索引
    reg [7:0] mem [0:65535];

    assign ram_rdata = ram_size ? {mem[ram_addr[15:0] + 16'd1], mem[ram_addr[15:0]]}
                                : {8'h00, mem[ram_addr[15:0]]};
    always @(posedge clk) begin
        if (ram_we) begin
            mem[ram_addr[15:0]] <= ram_wdata[7:0];
            if (ram_size) mem[ram_addr[15:0] + 16'd1] <= ram_wdata[15:8];
        end
    end

    // ---- UART（槽 0） ----
    uart uart0 (
        .clk(clk), .rst_n(rst_n),
        .sel(dev_sel[0]), .addr(dev_addr),
        .wdata(dev_wdata), .we(dev_we), .re(dev_re), .size(dev_size),
        .rdata(uart_rdata), .irq(uart_irq)
    );

    integer i;
    integer cycles;
    integer errors;
    integer tx_err;
    reg     injected;

    // ---- RX 注入：PC 进入 0x01C0 等待循环时注入一个字节 'X' ----
    always @(posedge clk) begin
        if (!rst_n)
            injected <= 1'b0;
        else if (!injected && core.pc >= 16'h01C0 && core.pc <= 16'h01C2) begin
            uart0.rx_fifo[uart0.rx_wr[3:0]] <= 8'h58;   // 'X'
            uart0.rx_wr <= uart0.rx_wr + 5'd1;
            injected <= 1'b1;
            $display("  [TB] injected RX byte 'X' at pc=%h", core.pc);
        end
    end

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

    // 期望的 TX 输出："PBB16 OK\n"（9 字节）
    reg [7:0] exp_tx [0:8];
    initial begin
        exp_tx[0]=8'h50; exp_tx[1]=8'h42; exp_tx[2]=8'h42;
        exp_tx[3]=8'h31; exp_tx[4]=8'h36; exp_tx[5]=8'h20;
        exp_tx[6]=8'h4F; exp_tx[7]=8'h4B; exp_tx[8]=8'h0A;
    end

    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        $readmemh("asm/test_bus_uart.hex", mem);

        cycles = 0;
        errors = 0;

        // RX FIFO 预载 "AB"（程序轮询段读取）
        uart0.rx_wr = 5'd0;
        uart0.rx_fifo[0] = 8'h41;   // 'A'
        uart0.rx_fifo[1] = 8'h42;   // 'B'
        uart0.rx_wr = 5'd2;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        $display("== tb_bus_uart: start ==");

        while (!halted && cycles < 200000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(posedge clk);

        $display("");
        $display("== tb_bus_uart: finish, cycles=%0d, R7=%h ==", cycles, core.rf.regs[7]);

        check_bit(0, "a) TX string via STR.B to TXDATA");
        check_bit(1, "b) RX polling read 'A','B' + rx_ready clear");
        check_bit(2, "c) RX interrupt -> excode=1, ERET return");
        check_bit(3, "d) MMIO hole read 0 / write ignored");
        check_bit(4, "e) MMIO misaligned word access -> excode=3");

        // 直接检查 1：TX 内容逐字节比对
        if (uart0.tx_count == 9) begin
            tx_err = 0;
            for (i = 0; i < 9; i = i + 1) begin
                if (uart0.tx_log[i] !== exp_tx[i]) begin
                    $display("  [FAIL] tx_log[%0d]=%h (expect %h)", i, uart0.tx_log[i], exp_tx[i]);
                    tx_err = tx_err + 1;
                end
            end
            if (tx_err == 0) $display("  [OK] TX log matches \"PBB16 OK\\n\" (9 bytes)");
            else             errors = errors + tx_err;
        end else begin
            $display("  [FAIL] tx_count=%0d (expect 9)", uart0.tx_count);
            errors = errors + 1;
        end

        // 直接检查 2：停机
        if (halted) $display("  [OK] CPU halted");
        else begin $display("  [FAIL] CPU not halted (timeout)"); errors = errors + 1; end

        // 直接检查 3：R6(SP) 归位
        if (core.rf.regs[6] === 16'hFFFE) $display("  [OK] R6(SP) = %h", core.rf.regs[6]);
        else begin $display("  [FAIL] R6(SP) = %h (expect FFFE)", core.rf.regs[6]); errors = errors + 1; end

        if (errors == 0) $display("== tb_bus_uart: PASS ==");
        else             $display("== tb_bus_uart: FAIL (%0d errors) ==", errors);
        $finish;
    end

endmodule
