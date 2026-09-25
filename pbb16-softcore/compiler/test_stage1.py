#!/usr/bin/env python3
"""Build once; run reference assembly, generated C cases, and rejection checks."""
from pathlib import Path
import subprocess
import sys

from build import HERE, build
from pbb16cc import assemble, compile_file, emit_memh

ROOT = HERE.parent
OUT = HERE / "build" / "tests"


def command(argv):
    result = subprocess.run([str(arg) for arg in argv], cwd=ROOT,
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, argv))}\n{result.stdout}{result.stderr}")
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    return result.stdout


def simulate(image, expected, *, pushes=0, depth=0):
    output = command(["vvp", OUT / "c_return.vvp", f"+image={image}",
                      f"+expected={expected & 0xffff:04x}", f"+pushes={pushes}", f"+depth={depth}"])
    if "== tb_c_return: PASS" not in output or any(s in output for s in ("FAIL", "ERROR", "WARNING")):
        raise RuntimeError(output)
    print(image.stem, next(line for line in output.splitlines() if "PASS" in line))


def run_tests():
    binary = build()
    OUT.mkdir(parents=True, exist_ok=True)
    command(["iverilog", "-g2012", "-Wall", "-I", ROOT / "rtl", "-s", "tb_c_return",
             "-o", OUT / "c_return.vvp", *sorted((ROOT / "rtl").glob("*.v")), ROOT / "tb/tb_c_return.v"])
    memory, errors = assemble((HERE / "tests/reference_return42.asm").read_text(encoding="utf-8"))
    if errors:
        raise RuntimeError(str(errors))
    reference = OUT / "reference.hex"
    reference.write_text(emit_memh(memory), encoding="ascii")
    simulate(reference, 42)

    # End-to-end CLI smoke test and reproducibility against hand assembly.
    command([sys.executable, HERE / "pbb16cc.py", HERE / "examples/return42.c", "-o", OUT / "return42.hex"])
    simulate(OUT / "return42.hex", 42)
    actual, errors = assemble((OUT / "return42.asm").read_text(encoding="utf-8"))
    if errors or actual != memory:
        raise RuntimeError("compiled return42 does not match reference machine code")

    cases = [(str(n), n) for n in (0, 1, 42, 127, 128, 255, 256, 257, 4660, 32767)]
    cases += [("0x2a", 42), ("0X1234", 4660), ("0777", 511)]
    for index, (literal, expected) in enumerate(cases):
        source = OUT / f"constant_{index}.c"
        # Exercise whitespace/comments and both (void) and () without parameters.
        parameters = "void" if index % 2 else ""
        source.write_text(f"// case {index}\nint main({parameters}) {{ /* return */ return {literal}; }}\n",
                          encoding="utf-8")
        compile_file(source, source.with_suffix(".hex"), binary)
        simulate(source.with_suffix(".hex"), expected)

    rejected = [
        "int main(void) { return -1; }", "int main(void) { return 32768; }",
        "int main(void) { return 65536; }", "int main(void) { return 9999999999999999999999999999; }",
        "int main(void) { return 08; }", "int main(void) { return 0x; }",
        "int main(void) { return 42u; }", "int main(void) { return 1 * 2; }",
        "int main(void) { int a; return 42; }", "int main(void) { if(1) return 42; return 0; }",
        "int main(void) { return; }", "int main(void) { return 42 }",
        "int main(int x) { return 42; }", "int other(void) { return 42; }",
        "int main(void) { return 42; } int other(void) { return 0; }",
        "int main(void) { return sizeof(long); }", "int main(void) { asm(\"HLT\"); return 0; }",
        "#define N 42\nint main(void) { return N; }", "", "int main(void) { return 42;",
    ]
    source = OUT / "rejected.c"
    for text in rejected:
        source.write_text(text, encoding="utf-8")
        result = subprocess.run([str(binary), "-A", "pbb16", "-f", str(source)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 1 or "PBB16:" not in result.stderr or result.stdout:
            raise RuntimeError(f"unsupported input not cleanly rejected: {text!r}\n{result}")

    # Failed compilation must not replace a previous successful build.
    output = OUT / "return42.hex"
    paths = (output, output.with_suffix(".asm"), output.with_suffix(".function.asm"))
    before = [path.read_bytes() for path in paths]
    result = subprocess.run([sys.executable, str(HERE / "pbb16cc.py"), str(source), "-o", str(output)],
                            capture_output=True, text=True, timeout=10)
    if result.returncode != 1 or before != [path.read_bytes() for path in paths]:
        raise RuntimeError("failed compilation replaced existing output")

    print(f"stage 1: PASS ({len(cases) + 2} simulations, {len(rejected)} rejected inputs, output preservation)")


if __name__ == "__main__":
    try:
        run_tests()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"stage 1: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
