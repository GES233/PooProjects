#!/usr/bin/env python3
"""Stage 3: multiplicative operators * / % and unary minus, with C semantics."""
import ast
import random
import subprocess
import sys

from build import HERE
from pbb16cc import compile_file, compiler_binary
from test_stage1 import OUT, command, simulate
from test_stage2 import run_tests as run_stage2


def cdiv(a, b):
    """C division truncates toward zero; Python // floors. Operands fit int16."""
    quotient = abs(a) // abs(b)
    return -quotient if (a < 0) != (b < 0) else quotient


def oracle(expression):
    """Independent Python AST oracle with C semantics: value, op count, temporary depth.

    Unary minus emits a pushed 0 and a subtract, so it costs one operation and
    one extra live temporary over its operand. Only use this for shared
    Python/C decimal arithmetic, not C octal notation.
    """
    def check(value):
        if not -32768 <= value <= 32767:
            raise ValueError(f"oracle signed overflow: {expression}")
        return value

    def visit(node):
        if isinstance(node, ast.Constant) and type(node.value) is int:
            return node.value, 0, 0
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            value, ops, depth = visit(node.operand)
            return check(-value), ops + 1, depth + 1
        if not isinstance(node, ast.BinOp) or not isinstance(
                node.op, (ast.Add, ast.Sub, ast.Mult, ast.Div, ast.Mod)):
            raise ValueError(f"unsupported oracle expression: {expression}")
        left, left_ops, left_depth = visit(node.left)
        right, right_ops, right_depth = visit(node.right)
        if isinstance(node.op, ast.Add):
            value = left + right
        elif isinstance(node.op, ast.Sub):
            value = left - right
        elif isinstance(node.op, ast.Mult):
            value = left * right
        elif isinstance(node.op, ast.Div):
            value = cdiv(left, right)
        else:
            value = left - cdiv(left, right) * right
        return check(value), left_ops + right_ops + 1, max(left_depth, right_depth + 1)

    return visit(ast.parse(expression, mode="eval").body)


def run_tests():
    run_stage2()
    binary = compiler_binary()
    cases = [
        "3*(2-7)%5",            # 0; the expression that opened this stage
        "2+3*4",                # 14: * binds tighter than +
        "2*3+4*5",              # 26
        "(2+3)*4",              # 20
        "20/3", "20%3",         # 6, 2
        "(0-20)/3",             # -6: truncation toward zero, not floor -7
        "(0-20)%3",             # -2: remainder takes the dividend's sign
        "20/(0-3)", "20%(0-3)", # -6, 2
        "100/10/2",             # 5: left associative
        "100/(10/2)",           # 20
        "2*3*4",                # 24
        "7%3*2",                # (7%3)*2 = 2
        "-5", "-(3+2)",         # unary minus
        "3*-2", "-2*-3",        # -6, 6
        "- -5",                 # 5: two unary minuses
        "-(2)*3",               # -6
        "1*32767", "255*128",   # 32767, 32640
        "(0-256)*128",          # -32768: the most negative int16 is reachable
        "(0-1)*32767",          # -32767
        "-32767*1",             # -32767
        "((6*7)-(5*4))%9",      # 22%9 = 4
        "32767/1", "(0-32767-1)/1",  # 32767, -32768
        "(0-32767-1)%1",        # 0
        "1" + "*1" * 256,       # 256 operations: long left-associative chain
    ]
    rng = random.Random(2333)

    def tree(depth):
        if depth == 0 or rng.random() < 0.25:
            return str(rng.randrange(40))
        if rng.random() < 0.15:
            return f"-({tree(depth - 1)})"
        return f"({tree(depth - 1)}{rng.choice(['+', '-', '*'])}{tree(depth - 1)})"

    generated = 0
    while generated < 16:
        candidate = tree(3)
        try:
            oracle(candidate)
        except (ValueError, ZeroDivisionError):
            continue
        cases.append(candidate)
        generated += 1

    for index, expression in enumerate(cases):
        expected, pushes, depth = oracle(expression)
        source = OUT / f"muldiv_{index}.c"
        source.write_text(f"int main(void) {{ return {expression}; }}\n", encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected, pushes=pushes, depth=depth)

    output = OUT / "muldiv.hex"
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/muldiv.c", "-o", output])
    simulate(output, 0, pushes=3, depth=2)

    invalid = [
        "1/0", "1%0", "3*(2-7)%0",                # division by zero is undefined in C
        "200*200", "32767*2", "(0-256)*129",      # multiply overflow
        "(0-32767-1)*(0-1)",                      # -32768 * -1 = 32768
        "(0-32767-1)/(0-1)",                      # INT16_MIN / -1
        "-(0-32767-1)",                           # -INT16_MIN = 32768
        "--5",                                    # prefix decrement token, not two minuses
        "1**2", "1*/2", "*1", "/1", "%1", "1*2*",
        "~1", "1~2",                              # bitwise not is not in this stage
        "+5",                                     # unary plus still unsupported
        "1 + * 2",
        "1" + "*1" * 257,                         # 257 operations: over the limit
    ]
    source = OUT / "rejected_muldiv.c"
    for expression in invalid:
        source.write_text(f"int main(void) {{ return {expression}; }}\n", encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"input not cleanly rejected: {expression!r}\n{result}")

    # A late RHS error must not publish partial code over successful artifacts.
    paths = (output, output.with_suffix(".asm"), output.with_suffix(".function.asm"))
    before = [path.read_bytes() for path in paths]
    source.write_text("int main(void) { return 3 * (12 / (5 - 5)); }\n", encoding="utf-8")
    result = subprocess.run([sys.executable, str(HERE / "pbb16cc.py"), str(source), "-o", str(output)],
                            capture_output=True, text=True, timeout=10)
    if result.returncode != 1 or before != [path.read_bytes() for path in paths]:
        raise RuntimeError("failed expression compilation replaced existing output")

    print(f"stage 3: PASS ({len(cases) + 1} expression simulations, {len(invalid)} rejected expressions, "
          "output preservation; stages 1-2 also passed)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"stage 3: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
