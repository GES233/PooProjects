#!/usr/bin/env python3
"""Stage 6: while/do-while/for loops with break and continue."""
import subprocess
import sys

from build import HERE
from pbb16cc import compile_file, compiler_binary
from test_stage1 import OUT, command, simulate
from test_stage3 import cdiv
from test_stage4 import cmod
from test_stage5 import COMPARE, IDENT_RE, TOKEN_RE, run_tests as run_stage5

MAX_ITERATIONS = 100000  # guard against infinite loops in the test itself


def evaluate(program):
    """Execute the stage-6 gate grammar, tracking the exact stack traffic.

    Returns (result, pushes, depth, local_bytes): the expected R0 value and
    the stack accounting tb_c_return must observe. Loops really loop: the
    same body tokens are re-parsed every iteration, so PUSH counts and depth
    match the simulated hardware. Statements signal "return"/"break"/
    "continue" when one actually executed; blocks dry-run the dead rest.
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

    def accumulate(pushes, depth):
        stats[0] += pushes
        stats[1] = max(stats[1], depth)

    def eval_slice(start, end, execute):
        """Evaluate tokens[start:end] as one expression without moving pos."""
        nonlocal pos
        saved = pos
        pos = start
        value, pushes, depth = parse_expression(execute)
        assert pos == end
        pos = saved
        if execute:
            accumulate(pushes, depth)
        return value

    def find_header_end(start):
        """Locate the first depth-0 ';' and the depth-0 ')' at/after start."""
        depth = 0
        semi = None
        i = start
        while True:
            token = tokens[i]
            if token == "(":
                depth += 1
            elif token == ")":
                if depth == 0:
                    return semi, i
                depth -= 1
            elif token == ";" and depth == 0 and semi is None:
                semi = i
            i += 1

    def run_body(execute):
        signal = None
        if peek() == "{":
            advance()
            while peek() != "}":
                statement_signal = run_statement(execute and signal is None)
                if execute and signal is None:
                    signal = statement_signal
            advance()
            return signal
        return run_statement(execute)

    def run_while(execute):
        nonlocal pos
        assert advance() == "("
        if not execute:
            parse_expression(False)
            assert advance() == ")"
            run_body(False)
            return None
        cond_start = pos
        _, cond_end = find_header_end(cond_start)
        assert tokens[cond_end] == ")"
        body_start = cond_end + 1
        iterations = 0
        while True:
            if not eval_slice(cond_start, cond_end, True):
                break
            pos = body_start
            signal = run_body(True)
            if signal == "return":
                return "return"  # body tokens fully consumed; pos is past them
            if signal == "break":
                break
            iterations += 1
            if iterations > MAX_ITERATIONS:
                raise RuntimeError("loop iteration cap exceeded")
        pos = body_start
        run_body(False)
        return None

    def run_do(execute):
        nonlocal pos
        body_start = pos
        if not execute:
            run_body(False)
            assert advance() == "while"
            assert advance() == "("
            parse_expression(False)
            assert advance() == ")"
            assert advance() == ";"
            return None
        iterations = 0
        while True:
            pos = body_start
            signal = run_body(True)
            assert advance() == "while"
            assert advance() == "("
            if signal == "return":
                parse_expression(False)
                assert advance() == ")"
                assert advance() == ";"
                return "return"
            condition, pushes, depth = parse_expression(True)
            accumulate(pushes, depth)
            assert advance() == ")"
            assert advance() == ";"
            if signal == "break" or not condition:
                break
            iterations += 1
            if iterations > MAX_ITERATIONS:
                raise RuntimeError("loop iteration cap exceeded")
        return None

    def run_for(execute):
        nonlocal pos
        assert advance() == "("
        if peek() != ";":
            _, pushes, depth = parse_expression(execute)
            if execute:
                accumulate(pushes, depth)
        assert advance() == ";"
        cond_start = pos
        cond_end, incr_end = find_header_end(cond_start)
        assert tokens[cond_end] == ";" and tokens[incr_end] == ")"
        incr_start = cond_end + 1
        body_start = incr_end + 1
        if not execute:
            eval_slice(cond_start, cond_end, False)
            eval_slice(incr_start, incr_end, False)
            pos = body_start
            run_body(False)
            return None
        iterations = 0
        while True:
            if not eval_slice(cond_start, cond_end, True):
                break
            pos = body_start
            signal = run_body(True)
            if signal == "return":
                return "return"
            if signal == "break":
                break  # break skips the increment; continue runs it
            eval_slice(incr_start, incr_end, True)
            iterations += 1
            if iterations > MAX_ITERATIONS:
                raise RuntimeError("loop iteration cap exceeded")
        pos = body_start
        run_body(False)
        return None

    def run_statement(execute):
        """Returns "return"/"break"/"continue" if one actually executed."""
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
                    accumulate(pushes, depth)
                    env[name] = value
            assert advance() == ";"
            return None
        if token == "return":
            advance()
            value, pushes, depth = parse_expression(execute)
            if execute:
                accumulate(pushes, depth)
                result[0] = value
            assert advance() == ";"
            return "return" if execute else None
        if token == "if":
            advance()
            assert advance() == "("
            condition, pushes, depth = parse_expression(execute)
            if execute:
                accumulate(pushes, depth)
            assert advance() == ")"
            signal = run_body(execute and condition)
            if peek() == "else":
                advance()
                else_signal = run_body(execute and not condition)
                if else_signal is not None:
                    signal = else_signal
            return signal
        if token == "while":
            advance()
            return run_while(execute)
        if token == "do":
            advance()
            return run_do(execute)
        if token == "for":
            advance()
            return run_for(execute)
        if token in ("break", "continue"):
            advance()
            assert advance() == ";"
            return token if execute else None
        _, pushes, depth = parse_expression(execute)
        if execute:
            accumulate(pushes, depth)
        assert advance() == ";"
        return None

    returned = False
    while pos < len(tokens):
        if run_statement(not returned) == "return":
            returned = True
    return result[0], stats[0], stats[1], 2 * len(order)


def run_tests():
    run_stage5()
    binary = compiler_binary()
    long_body = " ".join("y = y + 1;" for _ in range(24))  # > 128 bytes of code
    cases = [
        "int x = 0; while (x < 5) { x = x + 1; } return x;",
        "int i = 0; int s = 0; while (i < 10) { s = s + i; i = i + 1; } return s;",
        "int x = 7; while (x < 0) { x = x + 1; } return x;",      # never taken
        "int x = 0; while (x < 3) x = x + 1; return x;",          # single-statement body
        "int x = 5; int n = 0; while (x = x - 1) { n = n + 1; } return n * 10 + x;",
        "int x = 10; do { x = x + 1; } while (x < 0); return x;",  # do runs once
        "int x = 0; do { x = x + 3; } while (x < 10); return x;",
        "int x = 0; do x = x + 2; while (x < 6); return x;",
        "int x = 0; do { x = x + 1; if (x == 4) { break; } } while (1); return x;",
        "int s = 0; int i; for (i = 1; i <= 5; i = i + 1) { s = s + i; } return s;",
        "int s = 0; int i; for (i = 0; i < 4; i = i + 1) s = s + 2; return s;",
        "int s = 0; int i; for (; i < 4; i = i + 1) { s = s + 1; } return s;",  # empty init
        # continue in a for lands on the increment (the rotated layout):
        "int s = 0; int i; for (i = 0; i < 10; i = i + 1) { if (i < 5) { continue; }"
        " if (i > 7) { break; } s = s + i; } return s;",
        "int x = 0; while (1) { x = x + 1; if (x == 5) { break; } } return x;",
        "int i = 0; int s = 0; while (i < 10) { i = i + 1; if (i % 2 == 0) { continue; }"
        " s = s + i; } return s;",
        # nested loops, inner break:
        "int i = 0; int j; int n = 0; while (i < 3) { j = 0; while (j < 5) {"
        " if (j == 2) { break; } n = n + 1; j = j + 1; } i = i + 1; } return n;",
        # early return from inside a loop:
        "int x = 0; while (x < 100) { if (x * x > 50) { return x; } x = x + 1; } return 0 - 1;",
        # if outside, loop inside, continue inside:
        "int x = 0; int y = 0; if (x == 0) { while (y < 4) { y = y + 1;"
        " if (y == 3) { continue; } x = x + 10; } } return x + y;",
        # loop merge forgets x: 3 * 10000 passes the gate, in range at runtime
        "int x = 1; while (x < 3) { x = x + 1; } return x * 10000;",
        # >128-byte bodies need the JCC/J trampolines, both directions:
        f"int x = 0; int y = 0; while (x < 2) {{ x = x + 1; {long_body} }} return y;",
        f"int x = 0; int y = 0; do {{ x = x + 1; {long_body} }} while (x < 2); return y;",
    ]
    for index, body in enumerate(cases):
        expected, pushes, depth, local_bytes = evaluate(body)
        assert -32768 <= expected <= 32767, body
        source = OUT / f"loops_{index}.c"
        source.write_text(f"int main(void) {{ {body} }}\n", encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected,
                 pushes=pushes, depth=depth, localbytes=local_bytes)

    # The long-body cases only assemble thanks to the JCC/J trampolines.
    while_asm = (OUT / "loops_19.asm").read_text(encoding="utf-8")
    do_asm = (OUT / "loops_20.asm").read_text(encoding="utf-8")
    if "\nJ END_WHILE_main_" not in while_asm:
        raise RuntimeError("long while body did not use the exit trampoline")
    if "\nJ DO_main_" not in do_asm:
        raise RuntimeError("long do-while body did not use the back-edge trampoline")

    output = OUT / "loops.hex"
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/loops.c", "-o", output])
    example_expected, example_pushes, example_depth, example_locals = evaluate(
        "int i = 0; int odds = 0; int n = 0; int t = 0;"
        " while (i < 10) { i = i + 1; if (i % 2 == 0) { continue; } odds = odds + i; }"
        " for (n = 1; n < 100; n = n + 1) { if (n * n > 50) { break; } }"
        " do { t = t + 3; } while (t < 8); return odds + n + t;")
    assert example_expected == 42
    simulate(output, example_expected, pushes=example_pushes,
             depth=example_depth, localbytes=example_locals)

    rejected = [
        "while (1) { return 1; }",                        # main still needs a trailing return
        "break; return 0;",                               # break outside a loop
        "continue; return 0;",                            # continue outside a loop
        "int x = 0; while (1) { break; x = 1; } return x;",  # statement after break
        "int x = 0; while (x < 1) { x = x + 1; continue; x = 9; } return x;",
        "for (int i = 0; i < 3; i = i + 1) { } return 0;",   # for-init declaration
        "for (;;) { return 1; } return 0;",               # condition is required
        "int i = 0; for (i = 0; i < 3;) { } return 0;",   # increment is required
        "int x = 0; do { x = 1; } while (0) return x;",   # do-while needs its semicolon
        "do { } until (1); return 0;",                    # do needs while
        "int x = 0; while (x < 3) int y = 1; return x;",  # declaration in a loop body
        "int x = 0; while (1) { if (1) { break; } else { break; } x = 1; } return x;",
    ]
    deep = "int x = 0; " + "while (1) " * 17 + "{ } return x;"
    rejected.append(deep)  # control-flow nesting is capped at 16
    source = OUT / "rejected_loops.c"
    for body in rejected:
        source.write_text(f"int main(void) {{ {body} }}\n", encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"input not cleanly rejected: {body!r}\n{result}")

    print(f"stage 6: PASS ({len(cases) + 1} program simulations, trampoline checks, "
          f"{len(rejected)} rejected programs; stages 1-5 also passed)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, AssertionError, subprocess.SubprocessError) as error:
        print(f"stage 6: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
