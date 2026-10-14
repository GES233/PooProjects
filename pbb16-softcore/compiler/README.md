# PBB16 C 工具链：表达式、位运算、控制流与多函数调用

目标：把 `int main(void) { return 42; }` 交给**真实的 M2-Planet C 前端**，
由新增的 PBB16 后端生成汇编，接上启动代码、现有汇编器，在 CPU 仿真中返回 42。

这是宿主机上的交叉编译链，尚不是完整 C 编译器移植，也不是板端自举。
第二步已加入二元 `+`、`-` 和括号；第三步加入二元 `*`、`/`、`%` 和一元负号；
第四步加入局部 `int` 变量的声明、读取与赋值；第五步加入六个比较运算
（结果物化为 0/1）和 `if`/`else`；第六步加入 `while`、`do`-`while`、`for`
（`for` 的条件与增量表达式必填、初始化可空）以及 `break`/`continue`；第七步加入
多个返回 `int` 的函数、固定 `int` 参数、嵌套调用和直接递归；第八步加入逻辑非
`!` 以及真正短路的 `&&`、`||`，结果统一物化为 0/1；第九步加入按位非、与、异或、或
`~`、`&`、`^`、`|` 和移位 `<<`、`>>`。
程序必须有且仅有一个无参数 `int main(void)`（也接受 `main()`）；被调用函数须在
调用点之前定义。每个函数体为若干语句，
最后一条语句必须确定返回（一个 `return`，或两条分支都返回的 `if`/`else`；
循环即使 `while (1) { return x; }` 也不算——保守约定）。
语句可以是声明（`int x;`、`int x = 表达式;`，每条一句，仅在函数顶层）、
赋值（`x = 表达式;`，右结合、可链式、本身也是表达式）或任意表达式语句。
表达式中的整数常量为 0～32767，接受十进制、八进制和十六进制，以及空白和 C 注释。
一元 `!`、`~` 与一元负号优先级最高；其后依次是乘除模、加减、移位、比较/相等
（注意：上游前端把 `==` `!=`
与 `<` `<=` `>` `>=` 压在同一优先级，比标准 C 平，闸门原样镜像这一行为）；
再依次是按位 `&`、`^`、`|` 和逻辑 `&&`、`||`；各层从左向右结合，赋值右结合。
括号可以嵌套，运算结果可为负数。
除法和取模是 C99 有符号语义（向零取整、余数符号与被除数一致），直接落在硬件的
有符号 DIV/REM 上；常量除零和 `-32768 / -1` 在编译期拒绝，不依赖硬件的除零规则。

右移采用有符号算术右移。已知移位计数必须在 0～15；已知负值左移、左移溢出均按
有符号 C 的未定义行为在编译期拒绝，因此 `1 << 15` 也不作为构造 −32768 的写法。

不支持一元正号（`+1`）、常量后缀、其他类型、数组、函数原型与前向调用、函数指针、
复合赋值、递增/递减、旋转、无符号或逻辑右移、if/else/循环体内的声明、`for` 头的声明、
预处理指令或头文件。这些输入返回非零状态并报错，不会默默跳过。
所有中间结果都必须落在有符号 16 位范围 −32768～32767；例如 `(32767 + 1) - 1`
虽然最终数值在范围内，也会在溢出的那一步报错，不把硬件回绕当作有符号 C 语义。
闸门会跟踪每个局部变量的编译期已知值，所以 `int x = 5; return x * 10000;`
仍在编译期拒绝；控制流会按「所有可能下落路径一致」合并已知值——
`if (c) { x = 2; }` 之后或循环体（可能跑零圈或多圈）之后 x 不再已知，
`return x * 10000;` 放行（有符号溢出在 C 里本是未定义行为）。
注意循环体内的常量检查只覆盖第一圈的取值（不做不动点迭代）。
当前限定括号和表达式内函数调用最多嵌套 64 层、运算（含一元、按位、逻辑与赋值）最多 256 次、
函数最多 32 个、每个函数的参数与局部变量合计最多 32 个、控制流最多嵌套 16 层，
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
python compiler/pbb16cc.py compiler/examples/ifelse.c -o compiler/build/ifelse.hex
python compiler/pbb16cc.py compiler/examples/loops.c -o compiler/build/loops.hex
python compiler/pbb16cc.py compiler/examples/functions.c -o compiler/build/functions.hex
python compiler/pbb16cc.py compiler/examples/logical.c -o compiler/build/logical.hex
python compiler/pbb16cc.py compiler/examples/bitwise.c -o compiler/build/bitwise.hex
python compiler/test_stage9.py
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

## 顺着 if (a > b) 阅读

`examples/ifelse.c` 返回 42。这一步有两件事：比较怎么变成 0/1，控制流怎么变成跳转。

PBB16 的 JCC 一条指令只能测一个标志（J8 格式，flg+cm），而有符号小于要看
`S ⊕ V`（ISA 3.4），所以 `>` 展开成一条短跳链（`common_recursion` 照旧把左值弹进 R1）：

```asm
    ...左值 a 进 R0... PUSH R0 ...右值 b 进 R0... POP R1
    CMP R1, R0            ; 左 - 右：Z=相等，S⊕V=有符号小于
    MOVI R0, 0            ; 默认假；MOVI 不动标志，CMP 的结果还在
    JZ  CMP_main_0.d      ; 相等 → 不可能 >
    JV  CMP_main_0.v      ; 减溢出走另一半
    JNS CMP_main_0.t      ; V=0：S=0 即 S==V → 真
    J   CMP_main_0.d
CMP_main_0.v:
    JS  CMP_main_0.t      ; V=1：S=1 即 S==V → 真
    J   CMP_main_0.d
CMP_main_0.t:
    MOVI R0, 1
CMP_main_0.d:
```

标签用与 process_if 相同的全局计数器编号（`CMP_main_N` 的 `.v`/`.t`/`.d`），
跳链内部最远十几字节，远在 JCC 的 ±128 字节之内。`<`/`<=` 把两个 JS/JNS 对调
（`<=` 再加一条 `JZ .t`），`==`/`!=` 只看 Z，四条指令就够。
因为标签要逐实例唯一，这里不能用 general_recursion 的静态字符串，
改写了自己的递归（`pbb16_relational_recursion`）。
比较是普通表达式：结果在 R0 里是 0/1，可以赋值、参与算术、直接 return。

if 本身沿用上游 `process_if` 的三段式（ELSE/_END_IF_ 标签），PBB16 发射为：

```asm
    CMPI R0, 0            ; 条件为 0？（CMPI 零扩展，正好测 0/1）
    JNZ ELSE_main_1.t     ; 非零 → 跳过下面的长跳；两条之内，恒在 ±128 内
    J   ELSE_main_1       ; 条件不成立 → else；J 可达 ±1024
ELSE_main_1.t:
    ...then 体...
    J   _END_IF_main_1
ELSE_main_1:
    ...else 体...
_END_IF_main_1:
```

反条件短跳 + 无条件长跳的跳板是为了绕开 JCC ±128 字节的限制：then 体再长
也只要求 J 够得着；连 ±1024 都超出的程序由汇编器报越界错误。
`if`/`else` 体可以是单条语句或 `{ }` 块，块内 `return` 直接发射 epilogue
（有局部变量时 `MOV R6, R7` + RET，否则只有 RET），函数可以多个出口；
闸门的额外规矩是 return 必须是所在块的最后一条语句，main 的最后一条语句
必须确定返回（`if (c) return 1; else return 2;` 也算）。

闸门的常量跟踪跨分支合并：逐槽取「所有可能下落路径一致已知」的交集；
两条分支都 return 时后续代码不可达，环境整体降为未知。死代码仍完整校验——
`if (0) { return 200 * 200; }` 照样在编译期报溢出。

建议继续看：

- `cc_core.c / pbb16_relational_expr_stub、pbb16_emit_compare`：六个运算的跳链发射。
- `cc_emit.c / emit_jump_if_zero、emit_unconditional_jump`：跳板与 `;` 注释的早退分支。
- `pbb16_target.c / validate_relational、validate_if`：比较层求值与跨分支环境合并。

## 顺着 while 循环阅读

`examples/loops.c` 返回 42。循环在上游就是纯标签+跳转，`while` 是顶测试：

```asm
WHILE_main_0:                 ; continue 的目标
    ...条件表达式 → R0...
    CMPI R0, 0
    JNZ END_WHILE_main_0.t    ; 跳板：为真 → 跳过长跳
    J   END_WHILE_main_0      ; 为假 → 出循环（同 if 的 ELSE 跳板）
END_WHILE_main_0.t:
    ...循环体...
    J WHILE_main_0            ; 回跳（J，±1024）
END_WHILE_main_0:             ; break 的目标
```

`for` 的布局是「旋转」过的：初始化只跑一次，条件顶测试，`continue` 落在增量上：

```asm
    ...初始化...
FOR_main_1:
    ...条件 → R0... 跳板 → FOR_END_main_1
    J FOR_THEN_main_1         ; 条件为真 → 越过增量代码进循环体
FOR_ITER_main_1:              ; continue 的目标
    ...增量...
    J FOR_main_1
FOR_THEN_main_1:
    ...循环体...
    J FOR_ITER_main_1
FOR_END_main_1:               ; break 的目标
```

`do`-`while` 是底测试：体先跑一遍，条件为真经 `JZ`/`J` 镜像跳板
（`emit_jump_if_not_zero`）跳回 `DO_main_N`。`break`/`continue` 的目标由上游的
全局「目标栈」（`break_target_head`/`continue_target_head` 等四个变量，每个循环
入口保存旧值、出口恢复）拼成标签名，嵌套循环天然成立。

闸门侧的三条新规矩：循环永远不算「确定返回」（`while (1) { return 1; }` 后面
仍要兜底 return）；循环体可能跑零圈或多圈，所以出循环时已知值环境按
「进入前 ∧ 体尾一致」合并（与无 else 的 if 同一个 `merge_env`）；体内的常量检查
只覆盖第一圈取值。`break`/`continue` 与 `return` 一样必须是块内最后一条语句。

建议继续看：

- `cc_core.c / process_while、process_for、process_do`：上游的标签布局与目标栈。
- `cc_emit.c / emit_jump_if_not_zero`：`JZ`/`J` 镜像跳板。
- `pbb16_target.c / validate_loop_body、validate_while、validate_do、validate_for`：
  循环的环境合并；`for` 头按 token 顺序（初始化、条件、增量）验证。

## 顺着函数调用阅读

`examples/functions.c` 通过 `add`、`twice` 和嵌套实参返回 42。参数从左到右求值并
压栈，R5 指向参数区上沿：首参在 R5−2，第二个参数在 R5−4。调用序列保存调用者的
R2/R5/R7，CALL 由硬件继续压入返回地址；返回后调用者用 `MOV R6, R5` 一次清理参数，
再恢复三个寄存器。直接递归使用同一协议，不需要单独的返回地址寄存器。

完整且规范性的寄存器、栈帧和兼容边界见 [`../docs/PBB16_C_ABI.md`](../docs/PBB16_C_ABI.md)。
当前直接 CALL 仍受 ±1024 字节范围限制，越界由汇编器明确报错；R4 已在 ABI 中预留
给后续远调用序列。

## 顺着 a && f() 阅读

`examples/logical.c` 同时覆盖 `!`、`&&`、`||` 的值上下文与条件上下文。PBB16 不走
上游把逻辑运算降成按位 AND/OR 的路径，而是使用独立的 `关系运算 → && → || → 赋值`
优先级层。左操作数求值后，`&&` 在零值时跳过右侧，`||` 在非零时跳过右侧；两条路径
最终汇合为 R0 中的 0 或 1。条件跳仍使用短 JCC 跨过长 `J` 的跳板，因此较长的右操作数
不受 ±128 字节 JCC 范围限制。

闸门会按右侧“执行/跳过”两条路径合并局部变量已知值，例如参数 `a` 未知时，
`a && (x = 7)` 之后不能断言 x 等于 7；若左侧是常量 0，则保留 x 原值。右操作数即使
运行时必定跳过，源码仍须通过语法、名称和 16 位常量安全检查，和不可达 if 分支一致。

建议继续看：

- `cc_core.c / pbb16_logical_and_expr、pbb16_logical_or_expr`：跳转式求值与 0/1 汇合。
- `pbb16_target.c / validate_logical_and、validate_logical_or`：常量结果与副作用环境合并。
- `cc_reader.c / get_token`：保持 `!=` 为一个 token，同时把常见 `!!x` 拆成两个 `!`。

## 顺着位运算阅读

`examples/bitwise.c` 把 `~`、`&`、`^`、`|`、`<<` 和 `>>` 全部走过，并通过函数调用
返回 42。生成器直接使用 ISA 已有的 `NOT`、`AND`、`XOR`、`OR`、`SHL`、`SAR`；
由于当前只有有符号 `int`，C 的右移固定映射到 `SAR`，不使用逻辑右移 `SHR`。

PBB16 专用表达式管线是
`加减 → 移位 → 关系/相等 → & → ^ → | → && → || → 赋值`。
这修正了上游将五种按位/逻辑二元运算压在同一层的行为，同时继续保留上游
“关系与相等同层”的已知限制。闸门对已知移位做 16 位有符号检查；操作数或计数来自
未知参数时只生成目标指令，不伪装成静态可证明。

建议继续看：

- `cc_core.c / additive_expr_stub_c`：`SHL` 与算术 `SAR` 的 PBB16 发射。
- `cc_core.c / pbb16_bitwise_*_expr`：三层按位优先级与 `AND`/`XOR`/`OR` 发射。
- `pbb16_target.c / validate_shift`：移位计数、负值左移及有符号溢出检查。

## 本阶段的 ABI 与启动约定

| 项目 | 约定 |
|---|---|
| 程序入口 | CPU 复位从 0x0000 进入 `_start`；不是直接进入 main |
| 工作模式 | 复位后的直通态 MAPE=0、IE=0；本阶段不启用中断 |
| 栈 | R6，向下增长、2 字节对齐；启动代码设 SP=0xEFFE |
| 程序区 | 当前映像限制在 0x0000～0xDFFF |
| 栈预留区 | 0xE000～0xEFFF；仅为本阶段布局，不是硬件保护 |
| 调用 | 参数从左到右压栈、调用者清理；CALL 隐含压入 PC+2，RET 弹出它 |
| 返回值 | 16 位有符号 int 的结果放 R0，范围 −32768～32767；负数为补码，例如 −2 对应 FFFE |
| 寄存器 | R0 返回；R0–R4/R7 易失；R5=参数基址且被调用者保持；R6=SP |
| 参数 | 第 k 个 `int` 在 R5−2(k+1)；生成的调用序列保存并恢复调用者 R2/R5/R7 |
| 栈帧 | 有局部变量时建立 `MOV R7, R6; ADDI R6, -N`；第 k 个局部 `int` 在 R7−2(k+1)；返回前 `MOV R6, R7` |
| 标志 | 函数调用约定不保证 Z/S/C/V 保留；不要与中断恢复规则混淆 |
| 程序结束 | main 返回 `_exit`（地址 0x0006），HLT 保留 R0 供 testbench 检查 |

暂不承诺函数原型/前向调用、函数指针、变参、long/long long、结构体、普通 C 指针
或动态存储分配的完整 ABI。`register_size=2` 是此次后端设置，
不等于上游所有类型都已经适配；能力检查会阻止访问这些未验证路径。
无全局数据，故启动代码尚无 `.data` 搬运、`.bss` 清零或 libc 初始化。
这不会改变 ISA 里对一般汇编程序的约定，也不开放 banking 或内核栈。

CALL 位于 0x0004、main 位于 0x0008：调用时 SP 从 EFFE 变为 EFFC，
MEM16[EFFC]=0006；RET 后 PC=0006、SP=EFFE，结果仍在 R0。

## 验证与下一步

`test_stage9.py` 会先运行完整 `test_stage8.py` 回归（逐层套到 `test_stage1.py`，
也可单独运行）。第六阶段验证 21 组带循环的程序仿真：
while/do-while/for 三个形式、首圈即假与只跑一圈的边界、单语句体、空初始化、
条件里的赋值、break/continue（含 for 里 continue 落在增量上的旋转布局）、
嵌套循环、循环内提前 return、循环合并后的已知值放行，
其中两组的循环体超过 128 字节（while 出口跳板与 do-while 回跳跳板都被真实命中），
外加 `examples/loops.c` 的端到端检查。测试用独立的 Python 求值器真实执行循环
（同一批 token 每圈重新解析，带迭代上限防死循环），break 会跳过 for 的增量——
这个细节错一位就会被 testbench 的 PUSH 计数抓住。
拒绝用例覆盖循环外 break/continue、循环不兜底 return、break/continue 后的废话、
for 头声明与缺条件/缺增量、do-while 缺分号/缺 while、循环体内声明和 17 层嵌套。
阶段一到五的行为保持不变。第七阶段另用 `tb_c_calls.v` 在真实 RTL 上验证无参/多参、
参数顺序、嵌套调用、调用者与被调用者局部变量、参数赋值、循环内参数使用、8 参数和
直接递归；同时检查生成汇编的 ABI 序列、15 组拒绝输入和 CALL ±1024 字节越界诊断。
第八阶段在同一真实 RTL 上增加 22 组逻辑仿真：真假规范化、标准 `&&`/`||` 优先级、
表达式/条件/实参上下文、赋值副作用、未知参数下的环境合并，以及用无限递归右操作数
证明短路路径确实不执行；另检查长右操作数跳板和 9 组拒绝输入。
第九阶段增加 23 组位运算/移位仿真，覆盖正负补码、算术右移、标准相对优先级、
局部变量、条件、实参和未知参数计数；同时核对六条目标指令，并验证 21 组非法计数、
有符号左移未定义行为、残缺表达式、复合赋值、旋转写法和运算数上限。

仿真设周期上限，错误以 `$fatal` 退出，不仅打印 FAIL。
上游完整前端仍在，但 `pbb16_validate_program` 在预处理前拒绝超出本阶段的输入。
它是功能边界检查，验证后的 token 仍交给原来的 M2 解析器；并未用正则匹配替代 C 编译。

下一步是全局数据。远调用、函数原型与
前向调用也需要在程序规模继续增长前补上。
xv6 源码兼容、目标机运行编译器及自举仍未实现。来源、许可证及本地差异见 `vendor/README.md`。
