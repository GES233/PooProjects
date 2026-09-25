`timescale 1ns/1ps
// fpu.v — PBB16 v3 MMIO 浮点加速器（槽 3，IEEE binary16，规格 9.3）
// 挂总线设备槽 3（基址 0xF030），寄存器按 16 位字寻址：
//   偏移 0x0 OPA    (R/W) 操作数 A（fp16 位型；I2F 时为有符号整数）
//   偏移 0x2 OPB    (R/W) 操作数 B（fp16 位型）
//   偏移 0x4 CMD    (W)   写即触发：0=FADD 1=FSUB 2=FMUL 3=FDIV 4=FCMP 5=I2F 6=F2I
//   偏移 0x6 STATUS (R)   bit0 done（恒 1）、bit1 DZ、bit2 NV、bit3 OF、bit4 UF
//   偏移 0x8 RES    (R)   结果；FCMP：0xFFFF/0x0000/0x0001/0x0002 = 小于/等于/大于/无序
// 写 CMD 同拍完成（瞬时模型）：下一次读 RES/STATUS 即得结果，无中断（irq 恒 0）。
// 特殊值：NaN 一律输出 qNaN 0x7E00 并置 NV；x/±0（x≠0）→ ±Inf 置 DZ；
// 正常数舍入 round-to-nearest-even；次正规输入正常读取，结果下溢 flush 为零置 UF；
// F2I 向零截断，溢出钳位到 ±32767/-32768 并置 OF。
// ⚠ 仿真行为级：内部用 real 计算，不可综合；上 FPGA 需换真 fp16 核（接口不变）。
// 字节访问语义与 uart.v 一致：字节读按小端取高低字节（zext），偶地址字节写写低字节。
module fpu (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sel,
    input  wire [3:0]  addr,     // 设备内字节偏移
    input  wire [15:0] wdata,
    input  wire        we,
    input  wire        re,
    input  wire        size,     // 1 = 字，0 = 字节
    output wire [15:0] rdata,

    output wire        irq       // 恒 0（瞬时完成，无需中断/轮询）
);

    reg  [15:0] opa, opb, res;
    reg  [15:0] status;          // {11'b0, UF, OF, NV, DZ, done}

    wire [2:0] offset = addr[3:1];
    wire       wr     = sel && we && (size || !addr[0]);

    // 寄存器读 mux（字视图）
    reg [15:0] reg_word;
    always @(*) begin
        case (offset)
            3'd0:    reg_word = opa;
            3'd1:    reg_word = opb;
            3'd3:    reg_word = status;
            3'd4:    reg_word = res;
            default: reg_word = 16'h0000;
        endcase
    end

    // 字节读按小端取高低字节（与 RAM/uart 字节语义一致）
    assign rdata = size ? reg_word
                        : (addr[0] ? {8'h00, reg_word[15:8]}
                                   : {8'h00, reg_word[7:0]});

    assign irq = 1'b0;

    // ---- fp16 解码：类别 0=零 1=有限数 2=Inf 3=NaN ----
    function [1:0] fcls(input [15:0] h);
        begin
            if (h[14:10] == 5'h1F) fcls = (h[9:0] != 10'h000) ? 2'd3 : 2'd2;
            else if (h[14:0] == 15'h0000) fcls = 2'd0;
            else fcls = 2'd1;
        end
    endfunction

    // 2 的整数次幂（real）
    function real pow2(input integer n);
        integer i;
        real    r;
        begin
            r = 1.0;
            if (n >= 0) for (i = 0; i < n;  i = i + 1) r = r * 2.0;
            else        for (i = 0; i < -n; i = i + 1) r = r / 2.0;
            pow2 = r;
        end
    endfunction

    // fp16 → real（仅零/次正规/正规；Inf/NaN 由 fcls 分流，不进这里）
    function real f2r(input [15:0] h);
        integer e, m;
        real    v;
        begin
            e = h[14:10];
            m = h[9:0];
            if (e == 0) v = (m / 1024.0) * 6.103515625e-05;   // 次正规：2^-14
            else        v = (1.0 + m / 1024.0) * pow2(e - 15);
            f2r = h[15] ? -v : v;
        end
    endfunction

    // real → fp16，round-to-nearest-even；上溢 → Inf 置 of，下溢 flush 为零置 uf
    task r2f(input real v, output [15:0] h, output of, output uf);
        real    a, r, frac;
        integer e, m, ef;
        reg     s;
        begin
            s = (v < 0.0);
            a = s ? -v : v;
            of = 0; uf = 0;
            if (a == 0.0) begin
                h = {s, 15'h0000};
            end else begin
                e = 0; r = a;
                while (r >= 2.0) begin r = r / 2.0; e = e + 1; end
                while (r <  1.0) begin r = r * 2.0; e = e - 1; end
                // r ∈ [1,2)
                frac = (r - 1.0) * 1024.0;
                m = $rtoi(frac);
                frac = frac - m;
                if (frac > 0.5 || (frac == 0.5 && m[0])) m = m + 1;
                if (m == 1024) begin m = 0; e = e + 1; end
                ef = e + 15;
                if (ef >= 31) begin
                    h = {s, 5'h1F, 10'h000};   // ±Inf
                    of = 1;
                end else if (ef <= 0) begin
                    h = {s, 15'h0000};         // 下溢 flush 为零
                    uf = 1;
                end else begin
                    h[15]    = s;
                    h[14:10] = ef;
                    h[9:0]   = m;
                end
            end
        end
    endtask

    // 主操作：写 CMD 触发，结果与标志写入 res/status
    task do_op(input [2:0] op);
        reg  [15:0] hb;          // FSUB 时符号位翻转后的 B
        reg  [1:0]  ca, cb;
        real    va, vb, vr;
        reg  [15:0] h;
        reg         of, uf, nv, dz;
        reg         s_inf;
        integer     it;
        begin
            hb = (op == 3'd1) ? (opb ^ 16'h8000) : opb;   // FSUB = 加负数
            ca = fcls(opa);
            cb = fcls(hb);
            va = f2r(opa);
            vb = f2r(hb);
            nv = 0; dz = 0; of = 0; uf = 0;
            h  = 16'h0000;
            s_inf = opa[15] ^ hb[15];

            case (op)
                3'd0, 3'd1: begin   // FADD / FSUB
                    if (ca == 2'd3 || cb == 2'd3) begin
                        h = 16'h7E00; nv = 1;
                    end else if (ca == 2'd2 && cb == 2'd2) begin
                        if (opa[15] != hb[15]) begin h = 16'h7E00; nv = 1; end
                        else h = {opa[15], 5'h1F, 10'h000};
                    end else if (ca == 2'd2) begin
                        h = {opa[15], 5'h1F, 10'h000};
                    end else if (cb == 2'd2) begin
                        h = {hb[15], 5'h1F, 10'h000};
                    end else begin
                        r2f(va + vb, h, of, uf);
                    end
                end
                3'd2: begin         // FMUL
                    if (ca == 2'd3 || cb == 2'd3) begin
                        h = 16'h7E00; nv = 1;
                    end else if ((ca == 2'd2 && cb == 2'd0) ||
                                 (ca == 2'd0 && cb == 2'd2)) begin
                        h = 16'h7E00; nv = 1;              // Inf × 0
                    end else if (ca == 2'd2 || cb == 2'd2) begin
                        h = {s_inf, 5'h1F, 10'h000};
                    end else begin
                        r2f(va * vb, h, of, uf);
                    end
                end
                3'd3: begin         // FDIV
                    if (ca == 2'd3 || cb == 2'd3) begin
                        h = 16'h7E00; nv = 1;
                    end else if ((ca == 2'd2 && cb == 2'd2) ||
                                 (ca == 2'd0 && cb == 2'd0)) begin
                        h = 16'h7E00; nv = 1;              // Inf/Inf、0/0
                    end else if (cb == 2'd0) begin
                        h = {s_inf, 5'h1F, 10'h000}; dz = 1;   // x/±0 → ±Inf
                    end else if (ca == 2'd2) begin
                        h = {s_inf, 5'h1F, 10'h000};
                    end else if (ca == 2'd0 || cb == 2'd2) begin
                        h = {s_inf, 15'h0000};             // 0/x、x/Inf → ±0
                    end else begin
                        r2f(va / vb, h, of, uf);
                    end
                end
                3'd4: begin         // FCMP → res：FFFF/0000/0001/0002
                    if (ca == 2'd3 || cb == 2'd3) begin
                        h = 16'h0002; nv = 1;              // 无序
                    end else begin
                        if (ca == 2'd2) va = opa[15] ? -1.0e300 : 1.0e300;
                        if (cb == 2'd2) vb = hb[15]  ? -1.0e300 : 1.0e300;
                        h = (va < vb) ? 16'hFFFF : (va > vb) ? 16'h0001
                                                               : 16'h0000;
                    end
                end
                3'd5: begin         // I2F：OPA 有符号整数 → fp16
                    it = $signed(opa);
                    r2f(it * 1.0, h, of, uf);
                end
                default: begin      // F2I：fp16 → 有符号整数，向零截断
                    if (ca == 2'd3 || ca == 2'd2) begin
                        h = 16'h0000; nv = 1;
                    end else begin
                        it = $rtoi(va);
                        if (it > 32767)  begin it = 32767;  of = 1; end
                        if (it < -32768) begin it = -32768; of = 1; end
                        h = it[15:0];
                    end
                end
            endcase

            res    <= h;
            status <= {11'h000, uf, of, nv, dz, 1'b1};
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            opa    <= 16'h0000;
            opb    <= 16'h0000;
            res    <= 16'h0000;
            status <= 16'h0001;      // done 恒 1
        end else begin
            if (wr && offset == 3'd0) opa <= wdata;
            if (wr && offset == 3'd1) opb <= wdata;
            if (wr && offset == 3'd2) do_op(wdata[2:0]);
        end
    end

endmodule
