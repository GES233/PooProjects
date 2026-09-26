#!/usr/bin/env python3
"""Stage 4: local variables — declaration, assignment, read, chained assignment."""
import re
import subprocess
import sys

from build import HERE
from pbb16cc import compile_file, compiler_binary
from test_stage1 import OUT, command, simulate
from test_stage3 import cdiv, run_tests as run_stage3


def cmod(a, b):
    """C remainder takes the dividend's sign (matches hardware REM)."""
    return a - cdiv(a, b) * b


TOKEN_RE = re.compile(r"\d+|[A-Za-z_]\w*|[-+*/%=();]")
IDENT_RE = re.compile(r"[A-Za-z_]\w*")


def evaluate(program):
    """Mirror of the stage-4 gate grammar over a straight-line statement list.

    Returns (result, pushes, depth, local_bytes): the expected R0 value and the
    exact stack traffic the generated code must show in tb_c_return — one PUSH
    per binary/unary operator temporary, plus one per pending assignment target.
    Only decimal literals, so the Python tokenizer matches C exactly.
    """
    tokens = TOKEN_RE.findall(program)
    pos = 0
    env = {}
    order = []

    def peek(offset=0):
        return tokens[pos + offset] if pos + offset < len(tokens) else None

    def advance():
        nonlocal pos
        token = tokens[pos]
        pos += 1
        return token

    def parse_primary():
        token = advance()
        if token == "(":
            value, pushes, depth = parse_expression()
            assert advance() == ")"
            return value, pushes, depth
        if token.isdigit():
            return int(token), 0, 0
        return env[token], 0, 0

    def parse_unary():
        if peek() == "-":
            advance()
            value, pushes, depth = parse_unary()
            return -value, pushes + 1, depth + 1
        return parse_primary()

    def parse_term():
        value, pushes, depth = parse_unary()
        while peek() in ("*", "/", "%"):
            operator = advance()
            right, right_pushes, right_depth = parse_unary()
            if operator == "*":
                value *= right
            elif operator == "/":
                value = cdiv(value, right)
            else:
                value = cmod(value, right)
            pushes, depth = pushes + right_pushes + 1, max(depth, right_depth + 1)
        return value, pushes, depth

    def parse_additive():
        value, pushes, depth = parse_term()
        while peek() in ("+", "-"):
            operator = advance()
            right, right_pushes, right_depth = parse_term()
            value = value - right if operator == "-" else value + right
            pushes, depth = pushes + right_pushes + 1, max(depth, right_depth + 1)
        return value, pushes, depth

    def parse_expression():
        if IDENT_RE.fullmatch(peek() or "") and peek(1) == "=":
            name = advance()
            advance()
            value, pushes, depth = parse_expression()
            env[name] = value
            return value, pushes + 1, depth + 1
        return parse_additive()

    result = 0
    total_pushes = 0
    total_depth = 0
    while True:
        token = advance()
        if token == "int":
            order.append(advance())
            env[order[-1]] = 0
            if peek() == "=":
                advance()
                env[order[-1]], pushes, depth = parse_expression()
                total_pushes += pushes
                total_depth = max(total_depth, depth)
            assert advance() == ";"
        elif token == "return":
            result, pushes, depth = parse_expression()
            total_pushes += pushes
            total_depth = max(total_depth, depth)
            assert advance() == ";"
            break
        else:
            pos -= 1
            _, pushes, depth = parse_expression()
            total_pushes += pushes
            total_depth = max(total_depth, depth)
            assert advance() == ";"
    return result, total_pushes, total_depth, 2 * len(order)


def run_tests():
    run_stage3()
    binary = compiler_binary()
    cases = [
        "int x = 40; int y = 2; return x + y;",
        "int x = 5; x = x + 1; return x;",
        "int x; x = 7; return x;",                       # declare, then assign
        "int a = 1; int b = 2; a = b = a + b; return a * 10 + b;",  # chained assignment
        "int x = 3 * (2 - 7) % 5; int y = x - 5; return x * y;",    # zero times negative
        "int a = 6; int b = a * 7; int c = b / a + a % 4; return c;",
        "int x = 0 - 20; int y = x / 3; return y;",      # negative through a variable
        "int x = 0 - 20; int y = x % 3; return y;",      # remainder keeps the sign
        "int x = 1; return (x = 5) + x;",                # assignment is an expression
        "int x = 3; x * 2; return x;",                   # discarded expression statement
        "int x = 8; x = x / 2; x = x / 2; x = x / 2; return x;",
        # eight locals: sum 1..8 = 36
        "int a = 1; int b = 2; int c = 3; int d = 4; int e = 5; int f = 6;"
        " int g = 7; int h = 8; return a + b + c + d + e + f + g + h;",
    ]
    for index, body in enumerate(cases):
        expected, pushes, depth, local_bytes = evaluate(body)
        assert -32768 <= expected <= 32767, body
        source = OUT / f"locals_{index}.c"
        source.write_text(f"int main(void) {{ {body} }}\n", encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected,
                 pushes=pushes, depth=depth, localbytes=local_bytes)

    output = OUT / "locals.hex"
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/locals.c", "-o", output])
    example_expected, example_pushes, example_depth, example_locals = evaluate(
        "int total = 40; int step = 3; total = total + step * 2; step = total % 7;"
        " return total - step;")
    assert example_expected == 42
    simulate(output, example_expected, pushes=example_pushes,
             depth=example_depth, localbytes=example_locals)

    rejected = [
        "return x;",                                # undeclared variable
        "x = 1; return x;",                         # assign to undeclared
        "int x = x; return 0;",                     # own initializer is out of scope
        "int x = 1; int x = 2; return x;",          # redeclaration
        "int a, b; return 0;",                      # one declarator per statement
        "int a[4]; return 0;",                      # arrays are a later stage
        "char c = 1; return c;",                    # only int
        "int main = 1; return main;",               # main is taken
        "int return; return 0;",                    # keyword as a name
        "int x = 1; { int y = 2; } return x;",      # nested blocks are a later stage
        "int x = 200 * 200; return x;",             # overflow through an initializer
        "int x = 5; return x * 10000;",             # overflow through a known variable
        "int x = 3; return x / 0;",                 # division by zero stays rejected
        "int x = 1; x + 2 = 3; return x;",          # left side of = must be a variable
        "1 = 2; return 0;",                         # ... literally
        "int x = 1; x += 1; return x;",             # compound assignment is a later stage
        "if (1) return 1; return 0;",               # control flow is the next stage
        "int x = 1 return x;",                      # missing semicolon
        "int x = 1; return x; int y = 2;",          # return must be the last statement
    ]
    too_many = " ".join(f"int v{i} = {i};" for i in range(33)) + " return v0;"
    rejected.append(too_many)
    source = OUT / "rejected_locals.c"
    for body in rejected:
        source.write_text(f"int main(void) {{ {body} }}\n", encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"input not cleanly rejected: {body!r}\n{result}")

    # A late error must not publish partial code over successful artifacts.
    paths = (output, output.with_suffix(".asm"), output.with_suffix(".function.asm"))
    before = [path.read_bytes() for path in paths]
    source.write_text("int main(void) { int x = 1; return x / (3 - 3); }\n", encoding="utf-8")
    result = subprocess.run([sys.executable, str(HERE / "pbb16cc.py"), str(source), "-o", str(output)],
                            capture_output=True, text=True, timeout=10)
    if result.returncode != 1 or before != [path.read_bytes() for path in paths]:
        raise RuntimeError("failed statement compilation replaced existing output")

    print(f"stage 4: PASS ({len(cases) + 1} program simulations, {len(rejected)} rejected programs, "
          "output preservation; stages 1-3 also passed)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, AssertionError, subprocess.SubprocessError) as error:
        print(f"stage 4: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
