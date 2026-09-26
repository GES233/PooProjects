# PBB16 C 工具链：常量返回、算术表达式与局部变量

目标：把 `int main(void) { return 42; }` 交给**真实的 M2-Planet C 前端**，
由新增的 PBB16 后端生成汇编，接上启动代码、现有汇编器，在 CPU 仿真中返回 42。

这是宿主机上的交叉编译链，尚不是完整 C 编译器移植，也不是板端自举。
第二步已加入二元 `+`、`-` 和括号；第三步加入二元 `*`、`/`、`%` 和一元负号；
第四步加入局部 `int` 变量的声明、读取与赋值。
当前支持一个无参数 `int main(void)`（也接受 `main()`），函数体为若干语句加最后的
`return 表达式;`。语句可以是声明（`int x;`、`int x = 表达式;`，每条一句）、
赋值（`x = 表达式;`，右结合、可链式、本身也是表达式）或任意表达式语句。
表达式中的整数常量为 0～32767，接受十进制、八进制和十六进制，以及空白和 C 注释。
`*` `/` `%` 同级且高于 `+` `-`，同级从左向右结合；括号可以嵌套；运算结果可为负数。
除法和取模是 C99 有符号语义（向零取整、余数符号与被除数一致），直接落在硬件的
有符号 DIV/REM 上；常量除零和 `-32768 / -1` 在编译期拒绝，不依赖硬件的除零规则。

不支持一元正号（`+1`）、常量后缀、其他类型、数组、参数、其他函数、嵌套块、
控制流、预处理指令或头文件。这些输入返回非零状态并报错，不会默默跳过。
所有中间结果都必须落在有符号 16 位范围 −32768～32767；例如 `(32767 + 1) - 1`
虽然最终数值在范围内，也会在溢出的那一步报错，不把硬件回绕当作有符号 C 语义。
闸门会跟踪每个局部变量的编译期已知值，所以 `int x = 5; return x * 10000;`
仍在编译期拒绝；变量参与而值未知的表达式则放行（有符号溢出在 C 里本是未定义行为）。
当前限定括号最多嵌套 64 层、运算（含一元负号与赋值）最多 256 次、局部变量最多 32 个，
以限制宿主解析递归和目标程序资源使用。

## 运行

在 `pbb16-softcore/` 下运行，需要 Python 3、宿主 GCC、iverilog 和 vvp 在 PATH 中。
源码已随仓库固定，无需联网下载依赖。

```text
python compiler/build.py
python compiler/pbb16cc.py compiler/examples/return42.c -o compiler/build/return42.hex
python compiler/pbb16cc.py compiler/examples/arithmetic.c -o compiler/build/arithmetic.hex
python compiler/pbb16cc.py compiler/examples/muldiv.c -o compiler/build/muldiv.hex
python compiler/pbb16cc.py compiler/examples/locals.c -o compiler/build/locals.hex
python compiler/test_stage4.py
```

`build.py --cc 路径` 可指定宿主 C 编译器；`pbb16cc.py` 检测到源码更新或编译器缺失时
会使用 PATH 中的 `gcc` 自动重建。`build/` 是忽略的生成物目录。

编译命令产生三份可以逐一对照的文件：

| 文件 | 内容 |
|---|---|
| `return42.function.asm` | C 前端和 PBB16 后端生成的函数体 |
| `return42.asm` | 启动代码 + 函数体，标签由现有汇编器统一解析 |
| `return42.hex` | 供 `$readmemh` 使用的小端字节映像 |

若要单独查看后端输出，Windows 可运行：

```text
compiler/build/m2-pbb16.exe -A pbb16 -f compiler/examples/return42.c
```

其他宿主上的可执行文件名为 `m2-pbb16`。
直接调用上游 CLI 的 `-o` 会提前打开输出文件；日常构建请使用 `pbb16cc.py`，
它在编译及汇编成功后才写出文件，语法或生成错误不会覆盖已有成功产物。

## 顺着 return 42 阅读

1. `examples/return42.c`：我们要运行的 C 程序。
2. `pbb16_target.c`：已实现子集的能力检查与立即数发射。
3. `vendor/M2-Planet/cc_core.c` 中的 `primary_expr_number`、`return_result`：
   上游前端识别常量与 return，调用发射接口。
4. `runtime/crt0.asm`：初始化 R6、调用 `FUNCTION_main`、停机。
5. `../asm/pbb16asm.py`：解析标签、编码机器指令。
6. `../tb/tb_c_return.v`：真实 RTL 上核对返回值、返回地址和栈。

编译器输出应为：

```asm
FUNCTION_main:
    MOVI R0, 42
    RET
```

当 N=256 时，单条 MOVI 放不下，后端输出：

```asm
    MOVUI R0, 1
    ORI   R0, 0
    RET
```

必须先装高字节，再 OR 低字节：PBB16 的 MOVUI 会替换整个寄存器，
并不是只改高半部。带非零低字节的 257、0x1234 也纳入仿真。

## 顺着 20 - (3 + 5) 阅读

`examples/arithmetic.c` 返回 12。这一步可以分成三件事：

1. Lexer 把 `20`、`-`、`(`、`3`、`+`、`5`、`)` 识别成 token。
2. Parser 根据括号和结合规则确定运算结构；括号的作用在这一层实现。
3. 后端把运算结构变成 PBB16 指令，并保存计算过程中暂时不用的值。

前两层继续使用 M2-Planet 现有实现，没有为 PBB16 另写一套代码生成解析器。
这个前端边解析边生成代码，不要求先构造一棵完整的 AST。
`pbb16_validate_program` 在它之前检查允许的子集，并计算中间值以检查溢出；
这不是常量折叠，真正输出仍包含每一次加减，最后由 CPU 执行。

编译命令生成的函数体如下（这里加了说明注释）：

```asm
FUNCTION_main:
    MOVI R0, 20
    PUSH R0          ; 保存外层左值 20
    MOVI R0, 3
    PUSH R0          ; 保存内层左值 3
    MOVI R0, 5
    POP R1           ; R1 = 3，R0 = 5
    ADD R0, R1       ; R0 = 8
    POP R1           ; R1 = 20，R0 = 8
    SUB R1, R0       ; R1 = 20 - 8
    MOV R0, R1       ; 结果统一放回 R0
    RET
```

每个二元运算都遵守同一个步骤：计算左边 → 压栈 → 计算右边 → 弹出左边到 R1 → 运算。
不能只把外层的 20 暂存在 R1，因为计算括号内的加法也需要 R1；栈让嵌套表达式可以复用
同一套寄存器。此例中 CALL 的返回地址保存在 EFFC，20 和 3 分别压在 EFFA、EFF8，
两次 POP 后 SP 回到 EFFC，RET 再将它恢复到 EFFE。

无括号的 `20 - 3 - 5` 按 `(20 - 3) - 5` 得到 12，临时栈深度为 1；
`20 - (3 - 5)` 得到 22，临时栈深度为 2。括号本身不产生指令，改变的是求值过程。
目前不做 ADDI 等立即数优化，所有加减统一走寄存器指令，便于逐条对照；PBB16 也没有 SUBI。

建议继续看这三个位置：

- `cc_core.c / primary_expr`：遇到括号时递归解析表达式。
- `cc_core.c / additive_expr_stub_b`：加减运算的 PBB16 指令序列；
  `common_recursion` 保存左值、处理右值、恢复左值。
- `cc_emit.c / emit_push、emit_pop`：把前端的临时值保存请求发射成 `PUSH R0` 和 `POP R1`。

## 顺着 3 * (2 - 7) % 5 阅读

`examples/muldiv.c` 返回 0。表达式文法在这一步分出了优先级层：
`*` `/` `%` 一级（高），`+` `-` 一级（低），一元负号再高一级。C 标准就是这样规定的，
所以 `(3 * (2 - 7)) % 5` 不需要把前三项括起来。上游前端把 `* / %` 放在名叫
`additive_expr_stub_a` 的层里（命名有历史原因，别被迷惑），PBB16 分支如下：

```asm
FUNCTION_main:
    MOVI R0, 3
    PUSH R0          ; 保存 * 的左值 3
    MOVI R0, 2
    PUSH R0          ; 保存 - 的左值 2
    MOVI R0, 7
    POP R1
    SUB R1, R0       ; R1 = -5
    MOV R0, R1
    POP R1           ; R1 = 3，R0 = -5
    MUL R0, R1       ; R0 = -15（乘法可交换，方向无所谓）
    PUSH R0
    MOVI R0, 5
    POP R1           ; R1 = -15，R0 = 5
    REM R1, R0       ; 取模不可交换：和减法一样先算进 R1 再搬回
    MOV R0, R1       ; R0 = 0
    RET
```

`/`、`%` 和 `-` 一样不可交换，所以和减法共用"在 R1 里算、MOV 回 R0"的两拍模式；
`*` 可交换，一条 `MUL R0, R1` 就够。一元负号上游实现为 `0 - x`
（`cc_core.c / primary_expr` 的 `-` 分支），PBB16 复用同一段减法序列。

这一步还抓到并修掉一个硬件 bug：RTL 的 DIV/REM 原本是无符号除法
（`-15 % 5` 按无符号算出 1），与 C 语义和规格里"RISC-V 规则"的措辞都不符；
`rtl/alu.v` 已改为有符号（向零取整），ISA 规格 3.4 节同步写明，`tb_alu.v`
增加负数与 `-32768 / -1` 用例。注意 Verilog 的有符号除法必须经 `signed` 线网
单独求值，直接在三元表达式里写 `$signed(a) / $signed(b)` 会被上下文拉回无符号。

建议继续看：

- `cc_core.c / additive_expr_stub_a`：乘除模三行的 PBB16 分支。
- `pbb16_target.c / validate_term、validate_unary`：闸门里的优先级分层，
  以及不做 32 位中间量的乘法溢出检查 `mul_exceeds_int16`。

## 顺着局部变量阅读

`examples/locals.c` 返回 42。这一步函数第一次有了**栈帧**：

```asm
FUNCTION_main:
    MOV R7, R6       ; R7 = LOCALS，帧基址
    ADDI R6, -4      ; 为两个 int 局部变量腾出 4 字节
    ; ...
    MOV R6, R7       ; 返回前把 SP 还回帧基址
    RET
```

局部变量没有固定地址，编译器只记"相对 R7 的偏移"：第一个 `int` 在 R7−2，
第二个在 R7−4。读写一个变量因此是两条指令——先 `MOV Rd, R7; ADDI Rd, -偏移`
算出地址，再用 `LOD.W`/`STR.W` 偏移 0 访问。LOD/STR 自带的 ±16 字节偏移
看似可以直接 fused 成一条，但上游把"算地址"和"访存"分成两个独立原语
（`emit_load_relative_to_register` 与 `load_value`/`store_value`），
保持这个边界可以让赋值（只算地址、不读）和读取（算地址再读）共用同一段代码，
代价是每次访问多一条 MOV/ADDI。

函数入口的 `MOV R7, R6` + `ADDI R6, -N` 是**回填**出来的：上游
`declare_function` 先在输出流里放两个空字符串占位，等函数体解析完、
`locals_depth` 确定了，再把指令文本写回占位符。返回前的 `MOV R6, R7`
同理，从 `return_result` 和函数结尾两处引用同一份文本。

`x = x * y;` 的生成代码展示了赋值的完整协议：

```asm
    MOV R0, R7 / ADDI R0, -2   ; R0 = x 的地址（赋值目标的左侧只求地址）
    PUSH R0                    ; 暂存地址
    ... 右侧表达式，结果在 R0 ...
    POP R1                     ; R1 = 地址
    STR.W R0, 0(R1)            ; MEM[地址] = 结果；R0 保留赋值表达式的值
```

赋值是表达式、值留在 R0，所以 `a = b = 1` 右结合链式成立，`return (x = 5) + x;`
也是合法的。闸门的常量跟踪按语句顺序更新每个变量的已知值，因此
`int x = 5; return x * 10000;` 仍能在编译期报溢出。

配套改动还有两处值得一提：

- `tb/tb_c_return.v` 原来强制 0xE000 以上只允许栈引擎（PUSH/POP/CALL/RET）
  访问；现在按 `+localbytes=N` 开出帧窗口 `[0xEFFC−N, 0xEFFA]`，
  允许其中的字对齐 LOD/STR，并相应调整 LIFO 基址与 RET/R7 检查。
- 修了一个上游 bug：预处理器的 `maybe_expand` 要求每个 token 都有后继，
  没有换行结尾的源文件会在最后一个 `}` 上崩溃；现在只对真正需要展开的
  宏要求后继。这不是 PBB16 特有，任何架构都能复现。

建议继续看：

- `cc_core.c / collect_local`：局部变量的声明、偏移分配（`depth`）与初始化发射。
- `cc_core.c / load_address_of_variable_into_register`：名字到"基址+偏移"的查找。
- `cc_emit.c / emit_load_relative_to_register、write_move、write_sub_immediate`：
  prologue/epilogue 与地址计算的 PBB16 分支。
- `pbb16_target.c / validate_declaration、validate_expression`：
  闸门的符号表与环境式常量跟踪。

## 本阶段的 ABI 与启动约定

| 项目 | 约定 |
|---|---|
| 程序入口 | CPU 复位从 0x0000 进入 `_start`；不是直接进入 main |
| 工作模式 | 复位后的直通态 MAPE=0、IE=0；本阶段不启用中断 |
| 栈 | R6，向下增长、2 字节对齐；启动代码设 SP=0xEFFE |
| 程序区 | 当前映像限制在 0x0000～0xDFFF |
| 栈预留区 | 0xE000～0xEFFF；仅为本阶段布局，不是硬件保护 |
| 调用 | CALL 隐含先将 SP 减 2，再保存 PC+2；RET 弹出它 |
| 返回值 | 16 位有符号 int 的结果放 R0，范围 −32768～32767；负数为补码，例如 −2 对应 FFFE |
| 寄存器 | R0 放当前结果，R1 为临时左操作数/地址；R6=SP（CALL/RET/PUSH/POP 改变且返回后平衡）；R7=LOCALS 帧基址；R2～R5 不动 |
| 栈帧 | 仅当函数有局部变量时建立：`MOV R7, R6; ADDI R6, -N`；局部第 k 个 int 在 R7−2(k+1)；返回前 `MOV R6, R7` |
| 标志 | 函数调用约定不保证 Z/S/C/V 保留；不要与中断恢复规则混淆 |
| 程序结束 | main 返回 `_exit`（地址 0x0006），HLT 保留 R0 供 testbench 检查 |

暂不承诺参数传递、多函数调用、通用 caller/callee-saved 分组、long/long long、
结构体、普通 C 指针或动态存储分配的完整 ABI。`register_size=2` 是此次后端设置，
不等于上游所有类型都已经适配；能力检查会阻止访问这些未验证路径。
无全局数据，故启动代码尚无 `.data` 搬运、`.bss` 清零或 libc 初始化。
这不会改变 ISA 里对一般汇编程序的约定，也不开放 banking 或内核栈。

CALL 位于 0x0004、main 位于 0x0008：调用时 SP 从 EFFE 变为 EFFC，
MEM16[EFFC]=0006；RET 后 PC=0006、SP=EFFE，结果仍在 R0。

## 验证与下一步

`test_stage4.py` 会先运行完整 `test_stage3.py` 回归（逐层套到 `test_stage1.py`，
也可单独运行），重建宿主编译器并验证 13 组带局部变量的程序仿真：
声明/赋值/读取、链式赋值与赋值表达式、负数经由变量、8 个局部变量的帧，
外加 `examples/locals.c` 的端到端检查。测试用独立的 Python 递归下降求值器
按 C 语义计算期望结果、PUSH 次数、最大临时栈深度和帧字节数（`+localbytes`）。
拒绝用例覆盖未声明/重复声明/初始化里引用自身、每句多声明符、数组、其他类型、
保留字命名、嵌套块、已知值常量传播后的溢出与除零、非变量左值、复合赋值、
控制流、缺分号、return 后的废话和 33 个局部变量。
阶段一到三的行为保持不变（`+localbytes` 缺省为 0 时 testbench 检查与原样等价）。

仿真设周期上限，错误以 `$fatal` 退出，不仅打印 FAIL。
上游完整前端仍在，但 `pbb16_validate_program` 在预处理前拒绝超出本阶段的输入。
它是功能边界检查，验证后的 token 仍交给原来的 M2 解析器；并未用正则匹配替代 C 编译。

下一步是控制流（`if`/`else` 与比较运算）：需要把比较物化为 0/1（CMP + 条件跳链），
并处理 JCC ±128 字节、J ±1KB 的跳转范围限制。xv6 源码兼容、目标机运行编译器
及自举仍未实现。来源、许可证及本地差异见 `vendor/README.md`。
