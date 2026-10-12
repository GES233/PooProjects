#!/usr/bin/env python3
"""Stage 5: comparisons materialized as 0/1 and if/else with blocks."""
import re
import subprocess
import sys

from build import HERE
from pbb16cc import compile_file, compiler_binary
from test_stage1 import OUT, command, simulate
from test_stage3 import cdiv
from test_stage4 import cmod, run_tests as run_stage4

TOKEN_RE = re.compile(r"\d+|[A-Za-z_]\w*|==|!=|<=|>=|[-+*/%=();{}<>]")
IDENT_RE = re.compile(r"[A-Za-z_]\w*")

COMPARE = {
    "<": lambda a, b: a < b,
    "<=": lambda a, b: a <= b,
    ">": lambda a, b: a > b,
    ">=": lambda a, b: a >= b,
    "==": lambda a, b: a == b,
    "!=": lambda a, b: a != b,
}


def evaluate(program):
    """Execute the stage-5 gate grammar, tracking the exact stack traffic.

    Returns (result, pushes, depth, local_bytes): the expected R0 value and
    the stack accounting tb_c_return must observe. Only the taken if/else
    path runs, so its PUSH/POP traffic matches the simulated hardware; the
    untaken path is still parsed to advance the token cursor. Declarations
    are top-level only, so frame sizing is unchanged.
    """
    tokens = TOKEN_RE.findall(program)
    pos = 0
    env = {}
    order = []
    result = [0]
    stats = [0, 0]  # total pushes, max temporary depth

    def peek(offset=0):
        return tokens[pos + offset] if pos + offset < len(tokens) else None

    def advance():
        nonlocal pos
        token = tokens[pos]
        pos += 1
        return token

    def parse_primary(execute):
        token = advance()
        if token == "(":
            value, pushes, depth = parse_expression(execute)
            assert advance() == ")"
            return value, pushes, depth
        if token.isdigit():
            return int(token), 0, 0
        return env.get(token, 0), 0, 0

    def parse_unary(execute):
        if peek() == "-":
            advance()
            value, pushes, depth = parse_unary(execute)
            return -value, pushes + 1, depth + 1
        return parse_primary(execute)

    def parse_term(execute):
        value, pushes, depth = parse_unary(execute)
        while peek() in ("*", "/", "%"):
            operator = advance()
            right, right_pushes, right_depth = parse_unary(execute)
            if operator == "*":
                value *= right
            elif operator == "/":
                value = cdiv(value, right)
            else:
                value = cmod(value, right)
            pushes, depth = pushes + right_pushes + 1, max(depth, right_depth + 1)
        return value, pushes, depth

    def parse_additive(execute):
        value, pushes, depth = parse_term(execute)
        while peek() in ("+", "-"):
            operator = advance()
            right, right_pushes, right_depth = parse_term(execute)
            value = value - right if operator == "-" else value + right
            pushes, depth = pushes + right_pushes + 1, max(depth, right_depth + 1)
        return value, pushes, depth

    def parse_relational(execute):
        value, pushes, depth = parse_additive(execute)
        while peek() in COMPARE:
            operator = advance()
            right, right_pushes, right_depth = parse_additive(execute)
            value = int(COMPARE[operator](value, right))
            pushes, depth = pushes + right_pushes + 1, max(depth, right_depth + 1)
        return value, pushes, depth

    def parse_expression(execute):
        if IDENT_RE.fullmatch(peek() or "") and peek(1) == "=":
            name = advance()
            advance()
            value, pushes, depth = parse_expression(execute)
            if execute:
                env[name] = value
            return value, pushes + 1, depth + 1
        return parse_relational(execute)

    def run_statement(execute):
        """Returns True when a return actually executed on this path."""
        token = peek()
        if token == "int":
            advance()
            name = advance()
            if execute:
                order.append(name)
                env[name] = 0
            if peek() == "=":
                advance()
                value, pushes, depth = parse_expression(execute)
                if execute:
                    stats[0] += pushes
                    stats[1] = max(stats[1], depth)
                    env[name] = value
            assert advance() == ";"
            return False
        if token == "return":
            advance()
            value, pushes, depth = parse_expression(execute)
            if execute:
                stats[0] += pushes
                stats[1] = max(stats[1], depth)
                result[0] = value
            assert advance() == ";"
            return execute
        if token == "if":
            advance()
            assert advance() == "("
            condition, pushes, depth = parse_expression(execute)
            if execute:
                stats[0] += pushes
                stats[1] = max(stats[1], depth)
            assert advance() == ")"
            then_returned = run_body(execute and condition)
            if peek() == "else":
                advance()
                else_returned = run_body(execute and not condition)
                return then_returned or else_returned
            return then_returned
        _, pushes, depth = parse_expression(execute)
        if execute:
            stats[0] += pushes
            stats[1] = max(stats[1], depth)
        assert advance() == ";"
        return False

    def run_body(execute):
        returned = False
        if peek() == "{":
            advance()
            while peek() != "}":
                if run_statement(execute and not returned):
                    returned = True  # rest of the block is dead at runtime
            advance()
            return returned
        return run_statement(execute)

    returned = False
    while pos < len(tokens):
        if run_statement(not returned):
            returned = True
    return result[0], stats[0], stats[1], 2 * len(order)


def run_tests():
    run_stage4()
    binary = compiler_binary()
    long_body = " ".join("x = x + 1;" for _ in range(24))  # > 128 bytes of code
    cases = [
        "return 1 < 2;",
        "return 2 < 1;",
        "return 3 == 3;",
        "return 3 != 3;",
        "return 5 >= 5;",
        "return 5 <= 4;",
        "return (0 - 5) < 1;",                              # negative operand
        "int a = 0 - 32767 - 1; int b = 32767; return a < b;",   # a=-32768: CMP overflows, V=1 path
        "int a = 0 - 32767 - 1; int b = 32767; return a > b;",
        "int a = 0 - 32767 - 1; int b = 32767; return b >= a;",
        "return 1 < 2 == 1;",                               # one flat level: (1<2)==1
        "int x = 6; int y = 7; return x < y != 0;",         # chained, through variables
        "int x = 1; if (x > 0) x = 5; return x;",
        "int x = 1; if (x > 2) x = 5; return x;",
        "int x = 9; int y; if (x < 10) { y = 1; } else { y = 2; } return y;",
        "int x = 10; int y; if (x < 10) { y = 1; } else { y = 2; } return y;",
        "int x = 2; int y; if (x == 1) y = 10; else if (x == 2) y = 20; else y = 30; return y;",
        "int x = 3; int y = 0; if (x > 1) { if (x > 2) { y = 7; } } return y;",
        "int x = 0 - 3; if (x < 0) { return 0 - x; } return 0;",  # early return
        "int c = 3 < 5; return c + 41;",                    # comparison as a value
        "if (3 > 2) return 42; else return 0;",             # if as the last statement
        "int x = 1; if (x) { x = 2; } return x * 10000;",   # merge forgets x: 20000 allowed
        "int x = 0; if (x = 7) { x = x + 1; } return x;",   # assignment as the condition
        f"int x = 0; if (x == 0) {{ {long_body} }} return x;",   # taken trampoline (>128B body)
        f"int x = 5; if (x < 0) {{ {long_body} }} return x;",    # skipped long body
    ]
    for index, body in enumerate(cases):
        expected, pushes, depth, local_bytes = evaluate(body)
        assert -32768 <= expected <= 32767, body
        source = OUT / f"ifelse_{index}.c"
        source.write_text(f"int main(void) {{ {body} }}\n", encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected,
                 pushes=pushes, depth=depth, localbytes=local_bytes)

    # The long-body case only assembles thanks to the JNZ/J trampoline.
    long_asm = (OUT / "ifelse_23.asm").read_text(encoding="utf-8")
    if "\nJ ELSE_main_" not in long_asm:
        raise RuntimeError("long if-body did not use the JNZ/J trampoline")

    output = OUT / "ifelse.hex"
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/ifelse.c", "-o", output])
    example_expected, example_pushes, example_depth, example_locals = evaluate(
        "int a = 20 - 27; int b = 3; int max; if (a > b) { max = a; } else { max = b; }"
        " if (max < 0) { max = 0 - max; } if (max == 3) { max = max * 14; } return max;")
    assert example_expected == 42
    simulate(output, example_expected, pushes=example_pushes,
             depth=example_depth, localbytes=example_locals)

    rejected = [
        "while (1) { return 1; } return 0;",              # loops are a later stage
        "for (;;) { return 1; } return 0;",
        "do { return 1; } while (0); return 0;",
        "switch (1) { case 1: return 1; } return 0;",
        "goto end; return 0;",
        "if (1) int x = 2; return 0;",                    # declarations stay at top level
        "if (1) { int x = 2; } return 0;",
        "{ return 1; }",                                  # blocks need an if/else
        "if (1) { return 1; }",                           # main must definitely return
        "int x = 0; if (1) { return 1; } else { x = 2; }",  # else path falls through
        "if (1) { return 1; return 2; } return 0;",       # statement after return
        "if (1) { return 1; } else { return 2; } return 3;",  # after a definite return
        "if 1) return 1; return 0;",                      # missing (
        "if (1 return 1; return 0;",                      # missing )
        "if (1) return 1; else return 2; else return 3;", # double else
        "else return 1;",                                 # else without if
        "if (1) { x = 1; } return 0;",                    # undeclared variable
        "if (0) { return 200 * 200; } return 1;",         # dead code is still validated
        "return 1 && 1;",                                 # logical operators are a later stage
        "return !1;",                                     # unary ! is a later stage
        "return 1 | 2;",                                  # bitwise operators are a later stage
        "return ~1;",
    ]
    deep = "int x = 0; " + "if (1) " * 17 + "x = 1; return x;"
    rejected.append(deep)  # if nesting is capped at 16
    source = OUT / "rejected_ifelse.c"
    for body in rejected:
        source.write_text(f"int main(void) {{ {body} }}\n", encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"input not cleanly rejected: {body!r}\n{result}")

    print(f"stage 5: PASS ({len(cases) + 1} program simulations, trampoline check, "
          f"{len(rejected)} rejected programs; stages 1-4 also passed)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, AssertionError, subprocess.SubprocessError) as error:
        print(f"stage 5: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
