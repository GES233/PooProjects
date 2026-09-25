#!/usr/bin/env python3
"""PBB16 C -> M2-Planet target -> startup + assembly -> memh."""
import argparse
from pathlib import Path
import subprocess
import sys

from build import HERE, SOURCES, VENDOR, build

sys.path.insert(0, str(HERE.parent / "asm"))
from pbb16asm import assemble, emit_memh


def compiler_binary():
    binary = HERE / "build" / ("m2-pbb16.exe" if sys.platform == "win32" else "m2-pbb16")
    inputs = [VENDOR / source for source in SOURCES]
    inputs += list(VENDOR.glob("*.h"))
    inputs += [HERE / "pbb16_target.c", HERE / "build.py"]
    if not binary.exists() or any(path.stat().st_mtime_ns > binary.stat().st_mtime_ns
                                  for path in inputs):
        return build()
    return binary


def compile_file(source, output, binary=None):
    """Return generated paths; validate everything before publishing outputs."""
    source, output = Path(source).resolve(), Path(output).resolve()
    if output.suffix.lower() != ".hex":
        raise ValueError("output must end in .hex (also emits .asm and .function.asm)")
    assembly_path = output.with_suffix(".asm")
    function_path = output.with_suffix(".function.asm")
    if source in (output, assembly_path, function_path):
        raise ValueError("input and output paths must be different")
    result = subprocess.run([str(binary or compiler_binary()), "-A", "pbb16", "-f", str(source)],
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "M2-Planet compilation failed")
    startup = (HERE / "runtime" / "crt0.asm").read_text(encoding="utf-8")
    assembly = startup + "\n" + result.stdout
    memory, errors = assemble(assembly)
    if errors:
        raise ValueError("\n".join(f"assembly:{error.line_no}: {error.msg}" for error in errors))
    if not memory or min(memory) != 0 or max(memory) >= 0xE000:
        raise ValueError("program must fit below the reserved stack area 0xE000")
    output.parent.mkdir(parents=True, exist_ok=True)
    function_path.write_text(result.stdout, encoding="utf-8")
    assembly_path.write_text(assembly, encoding="utf-8")
    output.write_text(emit_memh(memory), encoding="ascii")
    return function_path, assembly_path, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("-o", "--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        for path in compile_file(args.input, args.output):
            print(path)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Compilation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
