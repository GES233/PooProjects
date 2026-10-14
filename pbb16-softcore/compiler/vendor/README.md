# 固定的上游源码

M2-Planet：`https://github.com/oriansj/M2-Planet`

- 标签：`Release_1.13.1`
- commit：`bd2fe4b0659fd0ad3f476a5ad0ef801bd134665d`
- 保留根级 C/H 文件、README.md、LICENSE；未复制上游测试及其他架构运行库。
- 原许可证 GPL-3.0-or-later，见 `M2-Planet/LICENSE` 及各源文件头。

M2libc：`https://github.com/oriansj/M2libc`

- commit：`68a23cfd05d5a355ba7a30c770d684cbe86fcc4e`
- 与上述 M2-Planet commit 的 M2libc 子模块指针一致。
- 只使用 `bootstrappable.c` 和 `bootstrappable.h`，源文件保留 GPL-3.0-or-later 声明。

本地修改保留在 vendored 源码中：

| 文件 | 改动 |
|---|---|
| `cc.h` | 新增独立架构位 PBB16=256 |
| `cc.c` | `-A pbb16`、RET、能力检查及直接汇编输出，跳过 ELF/M1 尾部 |
| `cc_reader.c` | 修复连续逻辑非：`!!x` 按两个 `!` token 读取，同时保留 `!=` |
| `cc_types.c` | PBB16 的 register_size=2 |
| `cc_emit.c` | PBB16 标签格式、立即数发射接口、任意通用寄存器 `PUSH`/`POP`、寄存器名映射、`MOV`/`ADD`/`SUB`/`ADDI` 发射、帧内地址计算 `emit_load_relative_to_register`、`emit_jump_if_zero`/`emit_jump_if_not_zero`（`CMPI`+`JNZ`/`JZ`+`J` 跳板）与 `emit_unconditional_jump`（`J`） |
| `cc_core.c` | PBB16 函数/局部变量/if/while/for 注释使用 `;`；加减乘除模与一元负号的发射；16 位 `LOD.W R0, 0(R0)` / `STR.W R0, 0(R1)` 访存串；比较物化为 0/1（`CMP` + 单标志 `JCC` 跳链，`S⊕V` 判有符号小于）；`!` 及跳转式短路 `&&`/`||`；直接 CALL 与 R5 负偏移参数槽 |
| `cc_macro.c` | 修复上游限制：无换行结尾的源文件最后一个 token 不再误报（仅宏展开才要求后继 token） |

本地后端主体放在 `../pbb16_target.c`（GPL-3.0-or-later）。
能力检查已扩展到函数与语句级：多函数签名、固定 int 参数和调用、局部 int
声明/赋值/读取、二元运算与括号、比较、短路逻辑、if/else、while/do-while/for、break/continue（块内 return/break/continue 收尾、
跨分支与跨循环的已知值环境合并）、
16 位有符号中间结果检查（含变量已知值跟踪）及程序规模限制；
语法分析、代码生成和栈帧回填仍使用上游前端。
其他架构分支保留；本仓库只验证 PBB16 阶段 1～8，没有声称完成上游全架构回归。
如更新上游，需重新核对这些接口，不应只替换源码而跳过测试。
