#!/usr/bin/env python3
"""Build the pinned M2-Planet + PBB16 target with a host C compiler."""
import argparse
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
VENDOR = HERE / "vendor" / "M2-Planet"
SOURCES = ["cc.c", "cc_reader.c", "cc_strings.c", "cc_types.c", "cc_core.c",
           "cc_macro.c", "cc_globals.c", "cc_emit.c", "M2libc/bootstrappable.c"]


def build(cc="gcc"):
    output = HERE / "build" / ("m2-pbb16.exe" if sys.platform == "win32" else "m2-pbb16")
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [cc, "-std=c99", "-O2", "-Wall", "-Wextra", "-Wno-unused-parameter",
               "-fwrapv", "-I", str(VENDOR), "-o", str(output)]
    command += [str(VENDOR / source) for source in SOURCES]
    command.append(str(HERE / "pbb16_target.c"))
    subprocess.run(command, check=True)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="gcc", help="host C compiler executable")
    args = parser.parse_args()
    try:
        print(build(args.cc))
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Build failed: {error}", file=sys.stderr)
        sys.exit(1)
