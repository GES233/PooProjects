#!/usr/bin/env python3
"""Stage 1 regression + arithmetic semantics and temporary-stack discipline."""
import ast
import random
import subprocess
import sys

from build import HERE
from pbb16cc import compile_file, compiler_binary
from test_stage1 import OUT, command, run_tests as run_stage1, simulate


def oracle(expression):
    """Independent Python AST oracle: value, binary-op count, temporary depth.

    Evaluating a binary RHS holds one saved LHS; grouping alone needs no stack.
    Only use this for shared Python/C decimal arithmetic, not C octal notation.
    """
    def visit(node):
        if isinstance(node, ast.Constant) and type(node.value) is int:
            return node.value, 0, 0
        if not isinstance(node, ast.BinOp) or not isinstance(node.op, (ast.Add, ast.Sub)):
            raise ValueError(f"unsupported oracle expression: {expression}")
        left, left_ops, left_depth = visit(node.left)
        right, right_ops, right_depth = visit(node.right)
        value = left + right if isinstance(node.op, ast.Add) else left - right
        if not -32768 <= value <= 32767:
            raise ValueError(f"oracle signed overflow: {expression}")
        return value, left_ops + right_ops + 1, max(left_depth, right_depth + 1)

    return visit(ast.parse(expression, mode="eval").body)


def run_tests():
    run_stage1()
    binary = compiler_binary()
    cases = [
        "(42)", "(((42)))", "20+22", "20-3-5", "20-(3-5)", "20-(3+5)",
        "(20+30)-(3+5)", "100-20+3-4", "1+2-3+4-5+6", "3-5", "0-(1+2)",
        "(3-5)-(8-12)", "1000+234", "32767-32767", "32766+1", "0-32767-1",
        "(0-32767-1)+32767", "32767+(0-32767-1)", "0-(0-32767)",
        "(0-32767-1)-(0-32767-1)", "32767-(0-32767-1+32767+1)",
        "100-(20-(3+(8-5)))", "((1+2)+(3+4))-((5+6)-(7+8))",
        "(" * 64 + "42" + ")" * 64,
        "+".join(["1"] * 257),  # 256 operators: long left-associative chain.
    ]
    # Deep RHS needs 65 live temporaries, unlike a long left-associative chain.
    deep = "1+1"
    for _ in range(64):
        deep = f"1+({deep})"
    cases.append(deep)

    rng = random.Random(233)

    def tree(depth):
        if depth == 0 or rng.random() < 0.25:
            return str(rng.randrange(1000))
        return f"({tree(depth - 1)}{rng.choice(['+', '-'])}{tree(depth - 1)})"

    cases.extend(tree(4) for _ in range(24))
    for index, expression in enumerate(cases):
        expected, pushes, depth = oracle(expression)
        source = OUT / f"expression_{index}.c"
        source.write_text(f"int main(void) {{ return {expression}; }}\n", encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected, pushes=pushes, depth=depth)

    # C-only notation plus comments/newlines, so give expectations explicitly.
    source = OUT / "expression_notation.c"
    source.write_text("int main() { return (0X100 /* lhs */ -\n 010) + // rhs\n 0x2a; }\n",
                      encoding="utf-8")
    compile_file(source, source.with_suffix(".hex"), binary)
    simulate(source.with_suffix(".hex"), 290, pushes=2, depth=1)

    output = OUT / "arithmetic.hex"
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/arithmetic.c", "-o", output])
    simulate(output, 12, pushes=2, depth=2)

    invalid = [
        "()", "(1", "1)", "1+(2-3", "1+", "1-", "+1", "1--2",
        "1++2", "1 + + 2", "1 2", "(1)(2)",
        "1<<2", "1&2", "1<2", "1?2:3", "1,2", "(int)1", "main()", "a+1",
        "1+32768", "1+08", "1+0x", "1+1u", "'a'+1", "1+=2",
        "32767+1", "0-32767-2", "0-(0-32767-1)", "(32767+1)-1",
        "(0-32767-1)-1+1", "32767-(0-1)", "(0-32767-1)+(0-1)",
        "1+(32767+1)", "(" * 65 + "1" + ")" * 65, "+".join(["0"] * 258),
    ]
    source = OUT / "rejected_expression.c"
    for expression in invalid:
        source.write_text(f"int main(void) {{ return {expression}; }}\n", encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"input not cleanly rejected: {expression!r}\n{result}")

    # A late RHS error must not publish partial code over successful artifacts.
    paths = (output, output.with_suffix(".asm"), output.with_suffix(".function.asm"))
    before = [path.read_bytes() for path in paths]
    source.write_text("int main(void) { return 20 + (6 / 0); }\n", encoding="utf-8")
    result = subprocess.run([sys.executable, str(HERE / "pbb16cc.py"), str(source), "-o", str(output)],
                            capture_output=True, text=True, timeout=10)
    if result.returncode != 1 or before != [path.read_bytes() for path in paths]:
        raise RuntimeError("failed expression compilation replaced existing output")

    print(f"stage 2: PASS ({len(cases) + 2} arithmetic simulations, {len(invalid)} rejected expressions, "
          "output preservation; stage 1 also passed)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"stage 2: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
