# M2-Planet → PBB16 v2 后端预研备忘

> **实施进展（2026-09-25）**：`../compiler/` 已固定 M2-Planet 1.13.1 并打通
> 无参数 main 返回非负 16 位 int 常量的 C→汇编→RTL 仿真链。
> 最小约定及可运行命令见 `../compiler/README.md`；下文保留为原始预研，
> 其完整后端工量、自举可行性与全类型支持估计尚未验证。
> 注意：下文示意中的 MOVI→MOVUI 顺序会丢失低字节；实际实现使用 MOVUI→ORI。
> 启动栈顶改用 0xEFFE，避开 MMIO 和异常向量页。

> 调研日期：2026-09-24，对象：M2-Planet master（v1.13.1）、M2libc master、mescc-tools master。
> 结论先行：**可行，是自制 CPU 获得 C 编译器改动量最小的现实路线**；
> 总量估计 1000–1800 行，最大风险是跳转距离工程和 `register_size=2` 未走过路径。
> 本文档为预研记录，暂不改动任何 RTL/ISA。

## 1. M2-Planet 是什么

stage0 自举生态中的 C 子集编译器：直接发射 **M1 宏汇编文本**（stage0 的中间格式），
再由 mescc-tools 的 M1（宏汇编器）→ hex2（链接器）产出二进制。
指令编码不在编译器里，而在 `M2libc/<arch>/<arch>_defs.M1` 的 `DEFINE` 表中。

支持的 C 子集（v1.13.1）：if/while/do/for/switch/goto、struct/union/enum/typedef、
数组与指针算术、函数指针、复合赋值、变参、`asm()`、预处理器、字符串字面量。
**不支持**：float/double、位域、struct 按值传递/返回、真 64 位类型；
**坑**：`&&`/`||` 不短路（按 `&`/`|` 生成）；三元 `?:` 未见支持。

## 2. 后端接口（关键发现：没有插件架构）

架构相关代码以 `if(Architecture == ...)` 分支散布在共享文件中，新后端 = 加分支：

| 位置 | 改动 |
|---|---|
| `cc.h` | 架构枚举加 `PBB16` |
| `cc.c` | `-A pbb16` 解析、`stack_direction = MINUS`、`return_instruction = "RET\n"` |
| `cc_types.c` | `register_size = 2` 新分支（目前只有 4/8） |
| `cc_emit.c` | **约 20 个发射原语各加分支**（push/pop/move/add/sub/mul/load/store/jump 等，清单见 `cc_emit.h`） |
| `cc_core.c` | 约 10 处内联 M1 字符串（二元运算/load-store 尺寸表/函数调用/参数 depth） |
| `M2libc/pbb16/` | 新目录：指令编码 DEFINE 表 + `libc-core.M1`（`_start`） |
| 工具链 | M1/hex2 加 pbb16 架构，**或绕过 M1 自写汇编器**（见风险 5） |

**操作数模型固定**：R0 = 累加器/返回值、R1 = 次操作数；二元运算先 push 左操作数、
算出右操作数于 R0、pop 到 R1，再发一条三地址运算。
逻辑寄存器共 9 个角色：`ZERO/ONE/TEMP/TEMP2/BASE/RETURN/STACK/LOCALS/EMIT_TEMP`。

**调用约定**：参数全部从栈传（从左到右 push），返回值在 R0；
CALL 压栈返回地址（PBB16 硬件一致，走 x86 模式，`RETURN` 寄存器角色不需要）；
栈帧 `[旧LOCALS][旧BASE][参数..][返回地址][局部变量..]`，参数按 `BASE+depth`、
局部变量按 `LOCALS-depth` 寻址；**首参 depth 每架构硬编码**，需按 PBB16
CALL 压 2 字节返回地址计算（预计 = 2）。

### PBB16 寄存器映射建议（与 M2 角色一一对应，8+8 刚好够用）

```
R0=ZERO(累加器/返回值)  R1=ONE   R2=TEMP   R3=TEMP2
R4=EMIT_TEMP  R5=BASE   R6=STACK(SP)      R7=LOCALS
（RETURN 角色闲置——CALL 硬件压栈）
```

## 3. 运行时依赖（极轻）

最小运行时 = `_start` 几行汇编（man 页原话 "literally only a half-dozen lines"）：

```
; PBB16 裸机版 _start 示意
_start: MOVUI R6, 0xFF ; ORI R6, 0xFE   ; SP = 0xFFFE（复位已做，可省）
        CALL main
        HLT            ; = exit
```

编译器本身不生成任何 IO——裸机程序用 `asm()` 内联汇编操作 MMIO 串口；
将来玩具内核可提供 `fputc/fgetc/exit`。注意：`#include <stdio.h>` 会把 libc
需求从 `libc-core` 提升到 `libc-full`。

## 4. 技术风险（按严重度）

1. **跳转距离**：JCC ±128B / J ±1KB，而 C 代码的 if/while/switch 跳转任意远。
   对策 = 照抄 AArch64 移植套路：**反向短条件跳 + 跳过"MOVI/MOVUI 装绝对地址 + JR"
   定长块**（`JCC +8; MOVI Rx,lo; MOVUI Rx,hi; JR Rx`）。`emit_jump_*` 全部按此实现，
   每处条件语义要正确取反（AArch64 笔记明确说这是易错点）。
2. **`register_size=2` 是未走过路径**：全局数据填充、指针初始化补丁、push/pop 常量、
   switch 表等从未在 2 字节字长下测试；且 M2 统一发 `&label`（M1 语义 4 字节指针），
   64KB 空间必须全部换成 2 字节（`@label`/`$label`）或给 M1/hex2 加 pbb16 架构。
3. **LOD/STR 偏移只有 ±16 字节**：栈帧/结构体访问大多超范围，退化为
   "算地址到寄存器 + [R+0] 访存"，代码膨胀但可用；大立即数装两拍（MOVI+MOVUI），
   恰好匹配 ARMv7L/AArch64 的多拍 `write_load_immediate` 模式，可照抄。
4. **无 setcc 指令**：关系运算物化 0/1 需 CMP + JCC 链，每个比较约 4–6 条指令。
   （PBB16 的 DIV/REM/MUL 硬件齐全，反而比需要 libcall 的 ARMv7L 舒服。）
5. **M1 宏汇编要求指令位段与十六进制 nybble 对齐**（HACKING 文档 AArch64 笔记的
   原话痛点）：PBB16 是 16 位定长 + 3 位寄存器字段，不对齐。**建议绕过 M1**：
   写一个小工具把 M2 输出文本直接翻成机器码——可以扩展现有 `asm/pbb16asm.py`
   支持 M2 风格标签/重定位语法（~200 行 Python）。
6. **banking（4MB）与 16 位指针模型冲突**：C 后端明确排除 banking，64KB 为限。
   （banking 留给 OS/驱动层，不暴露给 C 指针模型。）

## 5. 实施路线（依赖关系）

1. ~~第二阶段：48 条指令 + 异常~~ ✅ 已完成
2. **总线化 + MMIO 串口**（C 程序的 printf/getchar 的前提）← 下一步
3. ABI 定稿：寄存器映射（第 2 节）+ 栈帧布局 + 首参 depth，写入规格
4. M2-Planet 后端：先打通 `test/test0000`（`return 42`）最小链路，再扩测试
   （`test/test0000`–`test0026`、`test/run-pass/*`，在 iverilog 仿真里回归）
5. 自举里程碑：PBB16 后端能编译 M2-Planet 自身（自举验证 = 输出逐字节一致）

## 6. 参考链接

- M2-Planet: https://github.com/oriansj/M2-Planet （HACKING 文档含 AArch64 移植笔记，必读）
- stage0: https://github.com/oriansj/stage0
- M2libc: https://github.com/oriansj/M2libc （`knight/` 目录为最近参照）
- mescc-tools: https://github.com/oriansj/mescc-tools

## 7. 未验证项

- knight VM 寄存器位宽是从代码证据推断（32 位），stage0 ISA 文档未逐字陈述；
- 三元运算符不支持为消极证据（未找到处理代码）；
- `register_size=2` 的具体 bug 清单需实测才能穷尽。
