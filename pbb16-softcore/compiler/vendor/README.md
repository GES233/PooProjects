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
| `cc_types.c` | PBB16 的 register_size=2 |
| `cc_emit.c` | PBB16 标签格式、立即数发射接口 |
| `cc_core.c` | PBB16 函数注释使用现有汇编器支持的 `;` |

本地后端主体放在 `../pbb16_target.c`（GPL-3.0-or-later）。
其他架构分支保留；本仓库只验证 PBB16 阶段 1，没有声称完成上游全架构回归。
如更新上游，需重新核对这些接口，不应只替换源码而跳过测试。
