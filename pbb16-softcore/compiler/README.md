# PBB16 C 工具链：第一步

目标：把 `int main(void) { return 42; }` 交给**真实的 M2-Planet C 前端**，
由新增的 PBB16 后端生成汇编，接上启动代码、现有汇编器，在 CPU 仿真中返回 42。

这是宿主机上的交叉编译链，尚不是完整 C 编译器移植，也不是板端自举。
当前支持范围刻意很小：一个无参数 `int main(void)`（也接受 `main()`），
函数体只有 `return N;`；N 是 0～32767 的十进制、八进制或十六进制整数常量。
支持空白和 C 注释。不支持负数、后缀、表达式、变量、参数、其他函数、预处理指令或头文件。
这些输入返回非零状态并报错，不会默默跳过。

## 运行

在 `pbb16-softcore/` 下运行，需要 Python 3、宿主 GCC、iverilog 和 vvp 在 PATH 中。
源码已随仓库固定，无需联网下载依赖。

```text
python compiler/build.py
python compiler/pbb16cc.py compiler/examples/return42.c -o compiler/build/return42.hex
python compiler/test_stage1.py
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
2. `pbb16_target.c`：第一阶段能力检查与立即数发射。
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

## 本阶段的 ABI 与启动约定

| 项目 | 约定 |
|---|---|
| 程序入口 | CPU 复位从 0x0000 进入 `_start`；不是直接进入 main |
| 工作模式 | 复位后的直通态 MAPE=0、IE=0；本阶段不启用中断 |
| 栈 | R6，向下增长、2 字节对齐；启动代码设 SP=0xEFFE |
| 程序区 | 第一阶段映像限制在 0x0000～0xDFFF |
| 栈预留区 | 0xE000～0xEFFF；仅为本阶段布局，不是硬件保护 |
| 调用 | CALL 隐含先将 SP 减 2，再保存 PC+2；RET 弹出它 |
| 返回值 | 16 位 int 的结果放 R0，本阶段仅支持 0～32767 |
| 寄存器 | 当前生成代码仅写 R0，R6 由 CALL/RET 改变且返回后平衡；R1～R5/R7 不动 |
| 标志 | 函数调用约定不保证 Z/S/C/V 保留；不要与中断恢复规则混淆 |
| 程序结束 | main 返回 `_exit`（地址 0x0006），HLT 保留 R0 供 testbench 检查 |

暂不承诺参数传递、局部变量、通用 caller/callee-saved 分组、long/long long、
结构体、普通 C 指针或动态存储分配的完整 ABI。`register_size=2` 是此次后端设置，
不等于上游所有类型都已经适配；能力检查会阻止访问这些未验证路径。
无全局数据，故启动代码尚无 `.data` 搬运、`.bss` 清零或 libc 初始化。
这不会改变 ISA 里对一般汇编程序的约定，也不开放 banking 或内核栈。

CALL 位于 0x0004、main 位于 0x0008：调用时 SP 从 EFFE 变为 EFFC，
MEM16[EFFC]=0006；RET 后 PC=0006、SP=EFFE，结果仍在 R0。

## 验证与下一步

`test_stage1.py` 会重建宿主编译器并运行：

- 手写参考汇编（独立检查启动及调用约定）；
- 编译 example，经 CLI 生成的机器码必须与参考完全一致；
- 13 组常量/记法组合，检查 R0、SP、PC、返回地址小端存放，且没有意外内存写；
- 20 组不支持或错误输入，包括数值溢出、变量、运算、参数、其他函数和宏；
- 失败编译不覆盖上一次成功产物。

仿真设周期上限，错误以 `$fatal` 退出，不仅打印 FAIL。
上游完整前端仍在，但 `pbb16_validate_program` 在预处理前拒绝超出本阶段的输入。
它是功能边界检查，验证后的 token 仍交给原来的 M2 解析器；并未用正则匹配替代 C 编译。

下一步应选择一小组运算或函数调用，补全相应后端、放宽能力检查，再加入
语义测试。xv6 源码兼容、目标机运行编译器及自举仍未实现。
来源、许可证及本地差异见 `vendor/README.md`。
