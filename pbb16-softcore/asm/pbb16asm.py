#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pbb16asm.py — PBB16 v2 简易汇编器（两遍扫描，仅用标准库）

用法：
    python asm/pbb16asm.py 输入.asm -o 输出文件 [--format memh|raw]

- memh：$readmemh 兼容的十六进制字节流（小端，指令低字节在前），
  地址空洞用 @地址 分隔，可直接读入 `reg [7:0] mem[0:65535]`。
- raw ：Logisim "v2.0 raw" 映像（16 位字，空洞补 0）。

语法要点：
- 行尾注释 `;`；标签 `name:`（可独占一行或前缀指令），标签区分大小写
- 助记符、寄存器 R0-R7 大小写不敏感；数字支持十进制 / 0x 十六进制 / 负数
- 伪指令：.org 地址 / .word 值[,...] / .byte 值[,...]
- 跳转类操作数为标签或数字偏移（相对本指令自身地址，汇编器检查范围）
- JCC 通用形 `JCC Z, 0, loop`；糖：JZ/JNZ/JS/JNS/JC/JNC/JV/JNV
"""

import argparse
import re
import sys

# ---------------- 编码表（对照 docs/PBB16_v2_ISA.md 第 3 节） ----------------

# I8 型：op[15:11] | rd[10:8] | Imm8[7:0]
I8_OP = {
    "MOVI": 0x2000, "MOVUI": 0x2800,
    "ADDI": 0xC000, "ANDI": 0xC800, "ORI": 0xD000, "CMPI": 0xD800,
}

# R 型：0x4000 | rd[10:8] | rs[7:5] | fct5[4:0]
R_FCT = {
    "ADD": 0, "SUB": 1, "ADC": 2, "SBB": 3,
    "MUL": 4, "MLH": 5, "DIV": 6, "REM": 7,
    "AND": 8, "OR": 9, "XOR": 10, "NAND": 11, "NOR": 12,
    "NOT": 13, "MOV": 16, "XCHG": 17, "CMP": 18, "CMPU": 19,
    "SHL": 20, "SHR": 21, "SAR": 22, "ROL": 23, "ROR": 24,
}

# S 型：0x4800 | rd[10:8] | shamt4[7:4] | fct4[3:0]（助记符与 R 型相同，按操作数区分）
S_FCT = {"SHL": 0, "SHR": 1, "SAR": 2, "ROL": 3, "ROR": 4}

# M 型：op[15:11] | rd[10:8] | rb[7:5] | Imm5[4:0]（sext，±16）
M_OP = {"LOD.W": 0x6000, "STR.W": 0x6800, "LOD.B": 0x7000, "STR.B": 0x7800}

# A 型：op[15:11] | rgs[10:8]
A_OP = {"PUSH": 0x8000, "POP": 0x8800, "JR": 0x9000}

# 固定编码
FIXED = {
    "NOP": 0x0000, "HLT": 0xFFFF, "RET": 0xB800,
    "TRAP": 0xF000, "ERET": 0xF100,   # Y 型：0xF000 | fct3[10:8]
}

# JCC：0xA800 | flg[10:9] | cm[8] | Imm8[7:0]；flg：11:Z 10:V 01:S 00:C
FLG = {"Z": 3, "V": 2, "S": 1, "C": 0}
JCC_SUGAR = {  # 助记符 -> (flg, cm)
    "JZ": (3, 1), "JNZ": (3, 0), "JS": (1, 1), "JNS": (1, 0),
    "JC": (0, 1), "JNC": (0, 0), "JV": (2, 1), "JNV": (2, 0),
}

# 控制寄存器名（也接受 CRn 或纯数字 0-15）
CR_NAME = {"ZERO": 0, "STATUS": 8, "CAUSE": 9, "EPC": 11, "PRID": 15}

LABEL_RE = re.compile(r"^([A-Za-z_.$][\w.$]*):")
REG_RE = re.compile(r"^[Rr]([0-7])$")
MEM_RE = re.compile(r"^([+-]?[\w]+)\(\s*([Rr][0-7])\s*\)$")  # off(Rb) 形式


class AsmError(Exception):
    """带行号的汇编错误。"""

    def __init__(self, line_no, msg):
        self.line_no = line_no
        self.msg = msg
        super().__init__(msg)


# ---------------- 基础解析 ----------------

def parse_num(tok, line_no):
    """解析数字：十进制 / 0x 十六进制 / 0b 二进制，可带符号。"""
    t = tok.strip()
    neg = t.startswith("-")
    t = t.lstrip("+-")
    low = t.lower()
    base = 16 if low.startswith("0x") else 2 if low.startswith("0b") else 10
    try:
        v = int(t, base)
    except ValueError:
        raise AsmError(line_no, "无法解析数字: %r" % tok)
    return -v if neg else v


def parse_reg(tok, line_no):
    """解析寄存器 R0-R7（大小写不敏感）。"""
    m = REG_RE.match(tok.strip())
    if not m:
        raise AsmError(line_no, "非法寄存器: %r（应为 R0-R7）" % tok)
    return int(m.group(1))


def split_ops(rest, line_no):
    """按逗号切分操作数并去空白。"""
    if not rest.strip():
        return []
    return [o.strip() for o in rest.split(",")]


def check_range(v, lo, hi, line_no, what):
    if not (lo <= v <= hi):
        raise AsmError(line_no, "%s 越界: %d（允许 %d..%d）" % (what, v, lo, hi))
    return v


# ---------------- 两遍扫描 ----------------

def strip_comment(line):
    return line.split(";", 1)[0]


def pass1(lines):
    """第一遍：解析行结构、收集标签地址、生成中间项列表。

    返回 (items, labels)；items 元素为 dict：
    {line_no, addr, kind: 'instr'|'word'|'byte', text/values}
    """
    labels = {}
    items = []
    pc = 0
    errors = []

    for idx, raw in enumerate(lines, 1):
        text = strip_comment(raw).strip()
        if not text:
            continue
        # 提取行首的所有标签
        while True:
            m = LABEL_RE.match(text)
            if not m:
                break
            name = m.group(1)
            if name in labels:
                errors.append(AsmError(idx, "标签重复定义: %r" % name))
            else:
                labels[name] = pc
            text = text[m.end():].strip()
        if not text:
            continue

        parts = text.split(None, 1)
        mnemonic = parts[0].upper()
        rest = parts[1] if len(parts) > 1 else ""

        if mnemonic.startswith("."):
            if mnemonic == ".ORG":
                ops = split_ops(rest, idx)
                if len(ops) != 1:
                    errors.append(AsmError(idx, ".org 需要 1 个操作数"))
                    continue
                try:
                    pc = check_range(parse_num(ops[0], idx), 0, 0xFFFF, idx, ".org 地址")
                except AsmError as e:
                    errors.append(e)
            elif mnemonic == ".WORD":
                ops = split_ops(rest, idx)
                if not ops:
                    errors.append(AsmError(idx, ".word 需要至少 1 个操作数"))
                    continue
                items.append(dict(line_no=idx, addr=pc, kind="word", values=ops))
                pc += 2 * len(ops)
            elif mnemonic == ".BYTE":
                ops = split_ops(rest, idx)
                if not ops:
                    errors.append(AsmError(idx, ".byte 需要至少 1 个操作数"))
                    continue
                items.append(dict(line_no=idx, addr=pc, kind="byte", values=ops))
                pc += len(ops)
            else:
                errors.append(AsmError(idx, "未知伪指令: %r" % mnemonic))
            continue

        if pc > 0xFFFF:
            errors.append(AsmError(idx, "代码超出 64K 地址空间"))
            continue
        items.append(dict(line_no=idx, addr=pc, kind="instr",
                          mnemonic=mnemonic, rest=rest))
        pc += 2

    return items, labels, errors


def resolve_target(tok, cur_addr, labels, line_no):
    """跳转目标：标签 -> 相对本指令地址的偏移；数字 -> 直接作为偏移。"""
    try:
        return parse_num(tok, line_no)
    except AsmError:
        pass
    if tok in labels:
        return labels[tok] - cur_addr
    raise AsmError(line_no, "未定义标签: %r" % tok)


def encode_instr(item, labels):
    """第二遍：把单条指令编码为 16 位字。"""
    line_no = item["line_no"]
    addr = item["addr"]
    m = item["mnemonic"]
    ops = split_ops(item["rest"], line_no)

    def need(n):
        if len(ops) != n:
            raise AsmError(line_no, "%s 需要 %d 个操作数，实得 %d 个"
                           % (m, n, len(ops)))

    if m in FIXED:
        need(0)
        return FIXED[m]

    if m in I8_OP:
        need(2)
        rd = parse_reg(ops[0], line_no)
        # Imm8：允许 -128..255（取低 8 位），语义扩展方式由指令决定
        imm = check_range(parse_num(ops[1], line_no), -128, 255, line_no,
                          "%s 的 Imm8" % m)
        return I8_OP[m] | (rd << 8) | (imm & 0xFF)

    if m in R_FCT and m not in S_FCT:
        need(2)
        return (0x4000 | (parse_reg(ops[0], line_no) << 8)
                | (parse_reg(ops[1], line_no) << 5) | R_FCT[m])

    if m in S_FCT:  # SHL/SHR/SAR/ROL/ROR：第二操作数是寄存器走 R 型，是数字走 S 型
        need(2)
        rd = parse_reg(ops[0], line_no)
        if REG_RE.match(ops[1]):
            return 0x4000 | (rd << 8) | (parse_reg(ops[1], line_no) << 5) | R_FCT[m]
        sh = check_range(parse_num(ops[1], line_no), 0, 15, line_no, "移位量")
        return 0x4800 | (rd << 8) | (sh << 4) | S_FCT[m]

    if m in M_OP:
        if len(ops) not in (2, 3):
            raise AsmError(line_no, "%s 操作数形式应为 'Rd, off(Rb)' 或 'Rd, Rb, off'" % m)
        rd = parse_reg(ops[0], line_no)
        mm = MEM_RE.match(ops[1].replace(" ", "")) if len(ops) == 2 else None
        if mm:  # off(Rb) 形式
            off_tok, rb_tok = mm.group(1), mm.group(2)
        elif len(ops) == 3:   # Rd, Rb, off 形式
            rb_tok, off_tok = ops[1], ops[2]
        else:
            raise AsmError(line_no, "%s 操作数形式应为 'Rd, off(Rb)' 或 'Rd, Rb, off'" % m)
        rb = parse_reg(rb_tok, line_no)
        off = check_range(parse_num(off_tok, line_no), -16, 15, line_no, "Imm5 偏移")
        return M_OP[m] | (rd << 8) | (rb << 5) | (off & 0x1F)

    if m in A_OP:
        need(1)
        return A_OP[m] | (parse_reg(ops[0], line_no) << 8)

    if m in ("J", "CALL"):
        need(1)
        off = check_range(resolve_target(ops[0], addr, labels, line_no),
                          -1024, 1023, line_no, "%s 偏移" % m)
        base = 0xA000 if m == "J" else 0xB000
        return base | (off & 0x7FF)

    if m == "JCC":
        need(3)
        flg_name = ops[0].upper()
        if flg_name not in FLG:
            raise AsmError(line_no, "非法标志: %r（应为 Z/S/C/V）" % ops[0])
        cm = check_range(parse_num(ops[1], line_no), 0, 1, line_no, "期望标志值")
        off = check_range(resolve_target(ops[2], addr, labels, line_no),
                          -128, 127, line_no, "JCC 偏移")
        return 0xA800 | (FLG[flg_name] << 9) | (cm << 8) | (off & 0xFF)

    if m in JCC_SUGAR:
        need(1)
        flg, cm = JCC_SUGAR[m]
        off = check_range(resolve_target(ops[0], addr, labels, line_no),
                          -128, 127, line_no, "%s 偏移" % m)
        return 0xA800 | (flg << 9) | (cm << 8) | (off & 0xFF)

    if m in ("MFC", "MTC"):
        need(2)
        rgs = parse_reg(ops[0], line_no)
        cr_tok = ops[1].upper()
        if cr_tok in CR_NAME:
            cr = CR_NAME[cr_tok]
        else:
            if cr_tok.startswith("CR"):
                cr_tok = cr_tok[2:]
            cr = check_range(parse_num(cr_tok, line_no), 0, 15, line_no, "控制寄存器号")
        base = 0xE000 if m == "MFC" else 0xE800
        return base | (rgs << 8) | (cr << 4)

    raise AsmError(line_no, "非法助记符: %r" % m)


def assemble(source):
    """汇编源码字符串，返回 {地址: 字节} 与错误列表。"""
    lines = source.splitlines()
    items, labels, errors = pass1(lines)
    mem = {}

    for it in items:
        if it["kind"] == "instr":
            try:
                w = encode_instr(it, labels)
            except AsmError as e:
                errors.append(e)
                continue
            a = it["addr"]
            mem[a] = w & 0xFF          # 小端：低字节在前
            mem[a + 1] = (w >> 8) & 0xFF
        else:
            width = 2 if it["kind"] == "word" else 1
            lo, hi = (-32768, 0xFFFF) if width == 2 else (-128, 0xFF)
            a = it["addr"]
            for tok in it["values"]:
                try:
                    v = check_range(parse_num(tok, it["line_no"]), lo, hi,
                                    it["line_no"], ".%s 的值" % it["kind"])
                except AsmError as e:
                    errors.append(e)
                    continue
                mem[a] = v & 0xFF
                if width == 2:
                    mem[a + 1] = (v >> 8) & 0xFF
                a += width

    return mem, errors


# ---------------- 输出 ----------------

def emit_memh(mem):
    """$readmemh 兼容字节流：连续段按 @地址 分隔，每行 16 字节。"""
    if not mem:
        return ""
    out = []
    addrs = sorted(mem)
    seg_start = prev = addrs[0]
    chunk = []

    def flush(start, data):
        out.append("@%04X" % start)
        for i in range(0, len(data), 16):
            out.append(" ".join("%02X" % b for b in data[i:i + 16]))

    for a in addrs[1:]:
        if a != prev + 1:  # 地址空洞：结束当前段
            flush(seg_start, [mem[x] for x in range(seg_start, prev + 1)])
            seg_start = a
        prev = a
    flush(seg_start, [mem[x] for x in range(seg_start, prev + 1)])
    return "\n".join(out) + "\n"


def emit_raw(mem):
    """Logisim v2.0 raw：16 位字序列，从 0 开始空洞补 0，每行 8 字。"""
    if not mem:
        return "v2.0 raw\n"
    max_addr = max(mem)
    words = []
    for a in range(0, max_addr + 1, 2):
        lo = mem.get(a, 0)
        hi = mem.get(a + 1, 0)
        words.append((hi << 8) | lo)
    lines = ["v2.0 raw"]
    for i in range(0, len(words), 8):
        lines.append(" ".join("%04x" % w for w in words[i:i + 8]))
    return "\n".join(lines) + "\n"


# ---------------- CLI ----------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="PBB16 v2 简易汇编器")
    ap.add_argument("input", help="输入汇编源文件")
    ap.add_argument("-o", "--output", required=True, help="输出文件")
    ap.add_argument("--format", choices=["memh", "raw"], default="memh",
                    help="输出格式（默认 memh）")
    args = ap.parse_args(argv)

    try:
        with open(args.input, "r", encoding="utf-8") as f:
            source = f.read()
    except OSError as e:
        print("错误: 无法读取 %s: %s" % (args.input, e), file=sys.stderr)
        return 1

    mem, errors = assemble(source)
    if errors:
        for e in errors:
            print("%s:%d: 错误: %s" % (args.input, e.line_no, e.msg),
                  file=sys.stderr)
        return 1

    text = emit_memh(mem) if args.format == "memh" else emit_raw(mem)
    try:
        with open(args.output, "w", encoding="ascii") as f:
            f.write(text)
    except OSError as e:
        print("错误: 无法写入 %s: %s" % (args.output, e), file=sys.stderr)
        return 1

    n_instr_bytes = len(mem)
    print("汇编成功: %s -> %s（%d 字节，格式 %s）"
          % (args.input, args.output, n_instr_bytes, args.format))
    return 0


if __name__ == "__main__":
    sys.exit(main())
