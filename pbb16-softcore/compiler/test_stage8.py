#!/usr/bin/env python3
"""Stage 8: logical negation and short-circuit &&/||."""
import subprocess
import sys

from build import HERE
from pbb16cc import compile_file, compiler_binary
from test_stage1 import OUT, command
from test_stage7 import run_tests as run_stage7

ROOT = HERE.parent


def simulate(image, expected):
    output = command(["vvp", OUT / "c_calls.vvp", f"+image={image}",
                      f"+expected={expected & 0xffff:04x}"])
    if "== tb_c_calls: PASS" not in output or any(
            marker in output for marker in ("FAIL", "ERROR", "WARNING")):
        raise RuntimeError(output)
    print(image.stem, next(line for line in output.splitlines() if "PASS" in line))


def run_tests():
    run_stage7()
    binary = compiler_binary()
    command(["iverilog", "-g2012", "-Wall", "-I", ROOT / "rtl", "-s", "tb_c_calls",
             "-o", OUT / "c_calls.vvp", *sorted((ROOT / "rtl").glob("*.v")),
             ROOT / "tb/tb_c_calls.v"])

    cases = [
        ("int main(void) { return !0; }", 1),
        ("int main(void) { return !42; }", 0),
        ("int main(void) { return !!-7; }", 1),
        ("int main(void) { return 2 && -3; }", 1),
        ("int main(void) { return 0 || 42; }", 1),
        ("int main(void) { return 0 || 0; }", 0),
        ("int main(void) { return 1 || 0 && 0; }", 1),
        ("int main(void) { return 0 && 1 || 2 && 3; }", 1),
        ("int main(void) { int x = 5; 0 && (x = 7); return x; }", 5),
        ("int main(void) { int x = 5; 1 || (x = 7); return x; }", 5),
        ("int main(void) { int x = 5; 1 && (x = 7); return x; }", 7),
        ("int main(void) { int x = 5; 0 || (x = 7); return x; }", 7),
        ("int f(int a) { int x = 5; a && (x = 7); return x; }"
         " int main(void) { return f(0) * 10 + f(1); }", 57),
        ("int f(int a) { int x = 5; a && (x = 7); return x * 5000; }"
         " int main(void) { return f(0); }", 25000),
        ("int f(int a) { return a && 0; } int main(void) { return f(42); }", 0),
        ("int f(int a) { return a || 9; } int main(void) { return f(0) + f(5) * 10; }", 11),
        ("int id(int x) { return x; } int main(void) { return id(0 || 9); }", 1),
        ("int main(void) { int i = 0; int s = 0;"
         " while (i < 8 && s < 10) { s = s + i; i = i + 1; } return s; }", 10),
        ("int spin(int n) { return spin(n + 1); }"
         " int main(void) { return 0 && spin(0); }", 0),
        ("int spin(int n) { return spin(n + 1); }"
         " int main(void) { return 1 || spin(0); }", 1),
    ]
    for index, (program, expected) in enumerate(cases):
        source = OUT / f"logical_{index}.c"
        source.write_text(program + "\n", encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected)

    # Force the skipped right operand beyond JCC's +/-128-byte range. The
    # conditional trampoline must still bypass it without changing x.
    long_sum = " + ".join(["x"] + ["1"] * 24)
    source = OUT / "logical_long_rhs.c"
    source.write_text(
        f"int main(void) {{ int x = 7; 0 && (x = {long_sum}); return x; }}\n",
        encoding="utf-8")
    compile_file(source, source.with_suffix(".hex"), binary)
    simulate(source.with_suffix(".hex"), 7)
    assembly = source.with_suffix(".function.asm").read_text(encoding="utf-8")
    if "short-circuit && left" not in assembly or ".t:" not in assembly:
        raise RuntimeError("long logical RHS did not use the conditional trampoline")

    example = OUT / "logical.hex"
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/logical.c",
             "-o", example])
    simulate(example, 42)
    assembly = example.with_suffix(".function.asm").read_text(encoding="utf-8")
    required = ("LNOT_", "LAND_LEFT_FALSE_", "LOR_LEFT_TRUE_", "CALL FUNCTION_is_nonzero")
    if any(text not in assembly for text in required):
        raise RuntimeError("generated assembly is missing logical control-flow sequences")

    rejected = [
        "int main(void) { return 1 &&; }",
        "int main(void) { return || 1; }",
        "int main(void) { return !; }",
        "int main(void) { return 1 && missing; }",
        "int main(void) { int x = 5; 0 && (x = 7); return x * 7000; }",
        "int main(void) { int x = 5; 1 && (x = 7); return x * 5000; }",
        "int main(void) { return 0 && (1 / 0); }",
        "int main(void) { return 1 || (32767 + 1); }",
    ]
    logical_chain = " && ".join(["1"] * 258)
    rejected.append(f"int main(void) {{ return {logical_chain}; }}")
    source = OUT / "rejected_logical.c"
    for program in rejected:
        source.write_text(program + "\n", encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"input not cleanly rejected: {program!r}\n{result}")

    print(f"stage 8: PASS ({len(cases) + 2} logical simulations, short-circuit and "
          f"trampoline assembly checks, {len(rejected)} rejected programs; "
          "stages 1-7 also passed)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, AssertionError, subprocess.SubprocessError) as error:
        print(f"stage 8: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
