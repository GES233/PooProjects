#!/usr/bin/env python3
"""Stage 7: multiple int functions and fixed stack arguments."""
import subprocess
import sys

from build import HERE
from pbb16cc import compile_file, compiler_binary
from test_stage1 import OUT, command
from test_stage6 import run_tests as run_stage6

ROOT = HERE.parent


def simulate(image, expected):
    output = command(["vvp", OUT / "c_calls.vvp", f"+image={image}",
                      f"+expected={expected & 0xffff:04x}"])
    if "== tb_c_calls: PASS" not in output or any(
            marker in output for marker in ("FAIL", "ERROR", "WARNING")):
        raise RuntimeError(output)
    print(image.stem, next(line for line in output.splitlines() if "PASS" in line))


def run_tests():
    run_stage6()
    binary = compiler_binary()
    command(["iverilog", "-g2012", "-Wall", "-I", ROOT / "rtl", "-s", "tb_c_calls",
             "-o", OUT / "c_calls.vvp", *sorted((ROOT / "rtl").glob("*.v")),
             ROOT / "tb/tb_c_calls.v"])

    cases = [
        ("int answer(void) { return 42; }\n"
         "int main(void) { return answer(); }", 42),
        ("int add(int a, int b) { return a + b; }\n"
         "int main(void) { return add(20, 22); }", 42),
        ("int order(int a, int b, int c) { return a * 100 + b * 10 + c; }\n"
         "int main(void) { return order(1, 2, 3); }", 123),
        ("int add(int a, int b) { return a + b; }\n"
         "int main(void) { return add(add(5, 7), add(9, 11)); }", 32),
        ("int add(int a, int b) { return a + b; }\n"
         "int weighted(int a, int b) { int t = a * 10; t = add(t, b); return t; }\n"
         "int main(void) { int x = 4; return weighted(x, 2); }", 42),
        ("int fact(int n) { if (n <= 1) { return 1; } return n * fact(n - 1); }\n"
         "int main(void) { return fact(6); }", 720),
        ("int bump(int n) { n = n + 1; return n; }\n"
         "int main(void) { return bump(41); }", 42),
        ("int sum_to(int n) { int i = 0; int s = 0;"
         " while (i <= n) { s = s + i; i = i + 1; } return s; }\n"
         "int main(void) { return sum_to(9); }", 45),
        ("int sum8(int a, int b, int c, int d, int e, int f, int g, int h) {"
         " return a + b + c + d + e + f + g + h; }\n"
         "int main(void) { return sum8(1, 2, 3, 4, 5, 6, 7, 8); }", 36),
    ]
    for index, (program, expected) in enumerate(cases):
        source = OUT / f"functions_{index}.c"
        source.write_text(program + "\n", encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected)

    example = OUT / "functions.hex"
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/functions.c",
             "-o", example])
    simulate(example, 42)
    assembly = example.with_suffix(".function.asm").read_text(encoding="utf-8")
    required = ("CALL FUNCTION_add", "MOV R5, R2", "MOV R6, R5",
                "ADDI R0, -2", "ADDI R0, -4", "PUSH R7", "POP R7")
    if any(text not in assembly for text in required):
        raise RuntimeError("generated assembly does not implement the documented stack ABI")

    rejected = [
        "int add(int a, int b) { return a + b; } int main(void) { return add(1); }",
        "int add(int a) { return a; } int main(void) { return add(1, 2); }",
        "int main(void) { return missing(1); }",
        "int main(void) { return later(1); } int later(int x) { return x; }",
        "int f(void) { return 1; } int f(void) { return 2; } int main(void) { return f(); }",
        "int helper(void) { return 0; }",
        "int main(int argc) { return argc; }",
        "int f(int x, int x) { return x; } int main(void) { return f(1, 2); }",
        "int f(int f) { return f; } int main(void) { return f(1); }",
        "int f(void) { int f = 1; return f; } int main(void) { return f(); }",
        "int f(int x) { x = x + 1; } int main(void) { return f(1); }",
        "int f(char x) { return x; } int main(void) { return f(1); }",
        "int f(int x); int main(void) { return 0; }",
        "int f(void, int x) { return x; } int main(void) { return f(1); }",
    ]
    nested_call = "0"
    for _ in range(65):
        nested_call = f"f({nested_call})"
    rejected.append(
        f"int f(int x) {{ return x; }} int main(void) {{ return {nested_call}; }}")
    source = OUT / "rejected_functions.c"
    for program in rejected:
        source.write_text(program + "\n", encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"input not cleanly rejected: {program!r}\n{result}")

    # Direct CALL is PC-relative and intentionally remains range checked in stage 7.
    long_body = " ".join("x = x + 1;" for _ in range(80))
    source = OUT / "far_call.c"
    source.write_text(
        f"int far(int x) {{ {long_body} return x; }}\n"
        "int main(void) { return far(0); }\n", encoding="utf-8")
    try:
        compile_file(source, source.with_suffix(".hex"), binary)
    except ValueError as error:
        if "CALL" not in str(error) or "1024" not in str(error):
            raise RuntimeError(f"far call failed without a clear range error: {error}")
    else:
        raise RuntimeError("out-of-range direct CALL unexpectedly assembled")

    print(f"stage 7: PASS ({len(cases) + 1} call simulations, ABI assembly checks, "
          f"{len(rejected)} rejected programs, far-call range check; stages 1-6 also passed)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, AssertionError, subprocess.SubprocessError) as error:
        print(f"stage 7: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
