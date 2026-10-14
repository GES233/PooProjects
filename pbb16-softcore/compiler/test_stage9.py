#!/usr/bin/env python3
"""Stage 9: 16-bit bitwise and shift operators."""
import subprocess
import sys

from build import HERE
from pbb16cc import compile_file, compiler_binary
from test_stage1 import OUT, command
from test_stage8 import run_tests as run_stage8

ROOT = HERE.parent


def simulate(image, expected):
    output = command(["vvp", OUT / "c_calls.vvp", f"+image={image}",
                      f"+expected={expected & 0xffff:04x}"])
    if "== tb_c_calls: PASS" not in output or any(
            marker in output for marker in ("FAIL", "ERROR", "WARNING")):
        raise RuntimeError(output)
    print(image.stem, next(line for line in output.splitlines() if "PASS" in line))


def run_tests():
    run_stage8()
    binary = compiler_binary()
    command(["iverilog", "-g2012", "-Wall", "-I", ROOT / "rtl", "-s", "tb_c_calls",
             "-o", OUT / "c_calls.vvp", *sorted((ROOT / "rtl").glob("*.v")),
             ROOT / "tb/tb_c_calls.v"])

    cases = [
        ("int main(void) { return ~0; }", -1),
        ("int main(void) { return ~32767; }", -32768),
        ("int main(void) { return ~~123; }", 123),
        ("int main(void) { return 0x5a5a & 0x0ff0; }", 0x0a50),
        ("int main(void) { return -1 & 0x1234; }", 0x1234),
        ("int main(void) { return 0x5000 | 0x0a0a; }", 0x5a0a),
        ("int main(void) { return (0 - 32767 - 1) | 1; }", -32767),
        ("int main(void) { return 0x5555 ^ 0x0f0f; }", 0x5a5a),
        ("int main(void) { return 3 << 4; }", 48),
        ("int main(void) { return 16383 << 1; }", 32766),
        ("int main(void) { return 32767 << 0; }", 32767),
        ("int main(void) { return 1 << 14; }", 16384),
        ("int main(void) { return -8 >> 2; }", -2),
        ("int main(void) { return -1 >> 15; }", -1),
        ("int main(void) { return 32767 >> 15; }", 0),
        ("int main(void) { return 1 + 2 << 3; }", 24),
        ("int main(void) { return 1 | 2 ^ 3 & 1; }", 3),
        ("int main(void) { return 1 | 0 && 0; }", 0),
        ("int main(void) { return 1 & 2 == 2 == 1; }", 1),
        ("int f(int x, int n) { return (~x & 255) ^ (x >> n); }"
         " int main(void) { return f(240, 4); }", 0),
        ("int odd(int x) { if (x & 1) return 42; return 0; }"
         " int main(void) { return odd(7); }", 42),
        ("int shl(int x, int n) { return x << n; }"
         " int main(void) { return shl(21, 1); }", 42),
    ]
    for index, (program, expected) in enumerate(cases):
        source = OUT / f"bitwise_{index}.c"
        source.write_text(program + "\n", encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected)

    example = OUT / "bitwise.hex"
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/bitwise.c",
             "-o", example])
    simulate(example, 42)
    assembly = example.with_suffix(".function.asm").read_text(encoding="utf-8")
    required = ("NOT R0, R0", "SHL R1, R0", "SAR R1, R0", "AND R0, R1",
                "XOR R0, R1", "OR R0, R1")
    if any(text not in assembly for text in required):
        raise RuntimeError("generated assembly is missing a bitwise/shift instruction")

    rejected = [
        "int main(void) { return 1 << -1; }",
        "int main(void) { return 1 >> 16; }",
        "int main(void) { int n = 16; return 1 << n; }",
        "int main(void) { return -1 << 1; }",
        "int main(void) { return 1 << 15; }",
        "int main(void) { return 16384 << 1; }",
        "int main(void) { return 32767 << 1; }",
        "int main(void) { int x = 16384; return x << 1; }",
        "int main(void) { int x = 0 - 1; return x << 1; }",
        "int main(void) { return 1 <<; }",
        "int main(void) { return ~; }",
        "int main(void) { return 1 &; }",
        "int main(void) { return &1; }",
        "int main(void) { int x = 1; x &= 1; return x; }",
        "int main(void) { int x = 1; x ^= 1; return x; }",
        "int main(void) { int x = 1; x |= 1; return x; }",
        "int main(void) { int x = 1; x <<= 1; return x; }",
        "int main(void) { int x = 1; x >>= 1; return x; }",
        "int main(void) { return 1 <<< 1; }",
        "int main(void) { return 1 >>> 1; }",
    ]
    bitwise_chain = " & ".join(["1"] * 258)
    rejected.append(f"int main(void) {{ return {bitwise_chain}; }}")
    source = OUT / "rejected_bitwise.c"
    for program in rejected:
        source.write_text(program + "\n", encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"input not cleanly rejected: {program!r}\n{result}")

    print(f"stage 9: PASS ({len(cases) + 1} bitwise/shift simulations, instruction "
          f"checks, {len(rejected)} rejected programs; stages 1-8 also passed)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, AssertionError, subprocess.SubprocessError) as error:
        print(f"stage 9: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
