# AGENTS.md

## 项目概述

这是一个**数字逻辑 / 自制 CPU 电路设计工作区**（作者署名 @GES233，约 2015–2021 年），不是传统的软件工程项目。核心内容是基于 [Logisim](http://www.cburch.com/logisim/) / Logisim Evolution 的电路设计文件（`.circ`），辅以少量 Verilog 模块、指令集（ISA）文档、汇编示例和内存映像文件。

本目录**没有**任何包管理或构建配置文件（无 `pyproject.toml`、`package.json`、`Cargo.toml`、`Makefile` 等），但**已是 git 仓库**（2026-09 初始化，`master` 分支，`core.autocrlf=false`；`.gitignore` 排除了 `*.jar`/`*.pdf`/`*.zip`/`*.txz` 大型二进制和 `*.vvp` 仿真产物）。老电路的"运行"仍通过在 Logisim GUI 中打开 `.circ` 文件进行；`PBBP/pbb16-softcore/` 子项目有自己的 iverilog 仿真流程（见下文目录结构与测试两节）。

主要项目是 **PBBP** 系列自制 CPU（8 位和 16 位），存放在 `PBBP/` 目录下，按版本演进组织。

## 目录结构

- `PBBP/` — 主项目目录，PBBP 系列 CPU 的各个版本与子模块
  - `PBBP/8 Easy/` — 8 位 CPU 的 Verilog 实现（`PC.v`、`IR.v`、`ID.v`、`ALU.v`、`Regfile.v`、`RAM.v`、`Timer.v`、`Immed.v` 等），`README.txt` 描述了模块划分（Registers / Decode / ALU）
  - `PBBP/16 bit CPU/` — 16 位 CPU 的 Verilog 草稿（`RAM.v` 等）
  - `PBBP/PBBP v0.01/`、`PBBP/PBBP v0.02/`、`PBBP/v0.11/`、`PBBP/PBB 16/` — 各版本的 `.circ` 电路图、ISA 文档和结构截图（`.jpg`）。`PBB 16` 是完成度最高的版本，最新电路为 `20171002_CPU.circ`；`PBBP/PBB 16/PBB16_ISA.md` 是由 `00.txt` 整理并经 `20171002_CPU.circ` 静态分析校正的人类可读 PBB16 指令集规格
  - `PBBP/pbb16-softcore/` — PBB16 的 Verilog 软核项目（中度重设计版，iverilog 仿真优先），ISA 规格草案见 `docs/PBB16_v2_ISA.md`；`rtl/` 为可综合 RTL（多周期核，全部 48 条指令已实现：含访存/栈/CALL/RET/MFC/MTC/TRAP/ERET/异常与 4 路外部中断），`tb/` 为 testbench。仿真：`iverilog -g2012 -I rtl -o tb/out.vvp rtl/*.v tb/tb_count_loop.v && vvp tb/out.vvp`；ALU 单测：`iverilog -g2012 -I rtl -o tb/alu.vvp rtl/alu.v tb/tb_alu.v && vvp tb/alu.vvp`；第二阶段系统测试（先汇编再跑）：`python asm/pbb16asm.py asm/test_phase2.asm -o asm/test_phase2.hex && iverilog -g2012 -I rtl -o tb/phase2.vvp rtl/*.v tb/tb_phase2.v && vvp tb/phase2.vvp`；`asm/` 为配套单文件 Python 汇编器（仅用标准库）：`python asm/pbb16asm.py 输入.asm -o 输出.hex [--format memh|raw]`（默认 memh，供 testbench 用 `$readmemh` 加载；raw 为 Logisim `v2.0 raw` 映像）
  - `PBBP/内存映像/`、`PBBP/PBB 16/mem/` — Logisim 内存映像文件（`v2.0 raw` 十六进制格式）
  - 根级散落的 `*.circ`（`2333.circ`、`Stack.circ`、`TEST.circ` 等）为实验性电路
- `新建文件夹/` — 较新的设计：`lambdaCPU v4.circ`（含配套的 `lambdaCPU instructionset.xlsx` 指令集表格）、`muCPU[rev1].circ`、`FPU_ro.circ`
- `杂/` — 杂项实验电路（含一个 Logisim Evolution 2.13.22 格式的 `00.circ`，以及歌词显示器等）
- 根目录工具与参考：
  - `logisim-generic-2.7.1_TRP汉化版.jar` — Logisim 2.7.1（汉化版），**绝大多数 `.circ` 文件用此版本创建**（文件头 `source="2.7.1"`）
  - `logisim-evolution.jar` — Logisim Evolution（`杂/00.circ` 为 2.13.22 格式）
  - `buzzer.jar`、`kahdeg.jar` — Logisim 第三方组件库（蜂鸣器 / 声音，需作为 Logisim 库加载）
  - `CPU自制入门.pdf` — 参考书《CPU自制入门》

## 构建与运行

没有构建流程。工作方式：

1. 运行 Logisim：`java -jar logisim-generic-2.7.1_TRP汉化版.jar`（需要 Java 运行时）。
2. 在 Logisim 中打开对应的 `.circ` 文件进行查看、仿真和编辑。
3. 内存映像通过 Logisim 的 RAM 组件右键菜单 "Load Image" 加载（格式为 `v2.0 raw` 十六进制文本）。
4. `.jar` 组件库通过 Logisim 的 Project → Load Library → JAR Library 加载。

**注意**：`杂/00.circ` 是 Logisim Evolution 格式（`source="2.13.22"`），必须用 `logisim-evolution.jar` 打开；其余 `.circ` 均为经典 Logisim 2.7.1 格式，两种格式互不兼容。

## 代码与文档约定

- `.circ` 文件是 XML，可直接文本查看；编辑应通过 Logisim GUI 完成，手工改 XML 需谨慎。
- 指令集（ISA）文档为纯文本（如 `PBBP/PBB 16/00.txt`、`PBBP/00001.txt`），用 ASCII 表格描述指令位段编码（op1/op2/fct/rgs/Immediate 等字段）。
- 汇编示例见 `PBBP/PBBP v0.01/Basic Program.asm`，为自定义 ISA 的注释式汇编（助记符如 `MOVI`、`LOD`、`ADD`、`BNE`、`STR`、`HLT`），**没有配套的汇编器**，机器码是手工标注的。
- 早期 Verilog 代码为草稿性质（例如 `PBBP/8 Easy/ALU.v` 中存在 `A=B_flag` 这样的非法标识符和多余逗号，无法直接通过编译）；不要假设 `8 Easy/`、`16 bit CPU/` 下的 `.v` 文件可以用 iverilog/Verilator 直接构建。`PBBP/pbb16-softcore/rtl/` 不在此列（可编译、有测试）。
- 目录和文档混用中英文：目录名多为中文（`杂`、`新建文件夹`、`内存映像`、`图像`），技术注释以英文为主。新增文档建议沿用所在目录的语言习惯。

## 测试

老电路（`.circ`）没有测试框架，验证方式是在 Logisim 中时钟步进/运行仿真、观察寄存器和 RAM，或用 `TEST.circ` 做模块级验证；早期 Verilog 草稿（`8 Easy/` 等）没有 testbench 也编译不过。

**例外**：`PBBP/pbb16-softcore/` 有完整的 iverilog 测试流程（`tb/` 下系统级 + ALU 单元测试，均输出 PASS/FAIL），修改其子项目的 RTL 后必须重跑：

- `iverilog -g2012 -Wall -I rtl -o tb/out.vvp rtl/*.v tb/tb_count_loop.v && vvp tb/out.vvp`
- `iverilog -g2012 -Wall -I rtl -o tb/alu.vvp rtl/alu.v tb/tb_alu.v && vvp tb/alu.vvp`
- `python asm/pbb16asm.py asm/test_phase2.asm -o asm/test_phase2.hex && iverilog -g2012 -Wall -I rtl -o tb/phase2.vvp rtl/*.v tb/tb_phase2.v && vvp tb/phase2.vvp`

## 修改时的注意事项

- `.circ`、`.txz`、内存映像等文件请先用 Logisim 打开确认兼容性再修改；不同 Logisim 版本写出的文件可能互相打不开。
- 部分旧文本文件（如 `PBBP/00001.txt`）是 GBK/ANSI 编码，直接按 UTF-8 读取会出现乱码，编辑时注意保持原编码。
- 很多文件名包含中文和空格（如 `2333 - 副本.circ`、`内存映像/new  1`），shell 操作时必须加引号。
- 本目录是个人学习/实验性质的作品集，文件命名随意、存在大量重复和副本文件；不要擅自"整理"、重命名或删除任何文件。
