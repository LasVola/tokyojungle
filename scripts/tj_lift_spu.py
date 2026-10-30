#!/usr/bin/env python3
"""Lift the SPU images in generated/spu_images into generated/spu_lifted/<name>/.

Function bounds come from find_spu_functions.py (--raw for SPURS job blobs,
ELF mode for the two task ELFs); code comes from spu_lifter.py with the
tj_<name> symbol prefix that src/gen/spu_workloads.c links against. Both tools
are the ones in ../ps3recomp/tools (with patches/ps3recomp/tj-build-fixes.patch).
"""
from pathlib import Path
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT.parent / "ps3recomp" / "tools"
IMAGES = ROOT / "generated" / "spu_images"
OUT = ROOT / "generated" / "spu_lifted"
WORK = ROOT / "generated" / "spu_work"


def run(args):
    result = subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        print(result.stdout[-2000:], result.stderr[-2000:])
        sys.exit(f"failed: {Path(args[0]).name}")
    return result.stdout


def main():
    registry = (ROOT / "src" / "gen" / "spu_workloads.c").read_text()
    names = {fp.upper(): name for name, fp in
             re.findall(r"#define TJ_(\w+?)_FP\s+0x([0-9A-Fa-f]+)ULL", registry)}
    WORK.mkdir(parents=True, exist_ok=True)
    for image in sorted(IMAGES.glob("spujob_*.bin")):
        raw_name = names[image.stem.split("_")[1].upper()]
        name = "task9A00" if raw_name == "TASK9A00" else raw_name.lower()
        dest = OUT / name
        dest.mkdir(parents=True, exist_ok=True)
        funcs = dest / "functions.json"
        if image.read_bytes()[:4] == b"\x7fELF":
            code = WORK / f"{name}.text.bin"
            log = run([TOOLS / "find_spu_functions.py", image, "--out", funcs, "--code-out", code])
            match = re.search(r"base[^0-9a-fA-Fx]*(0x[0-9A-Fa-f]+)", log)
            lift_in, base = code, (match.group(1) if match else "0")
        else:
            run([TOOLS / "find_spu_functions.py", image, "--raw", "--base", "0", "--out", funcs])
            lift_in, base = image, "0"
        run([TOOLS / "spu_lifter.py", lift_in, "--base", base, "--functions", funcs,
             "--symbol-prefix", f"tj_{name}", "--output", dest])
        # The lifter includes the runtime headers by a path relative to its own
        # tree; CMake puts runtime/spu on the include path instead.
        for source in dest.glob("*.[ch]"):
            text = source.read_text()
            fixed = text.replace('"../../runtime/spu/', '"')
            if fixed != text:
                source.write_text(fixed)
        count = len(json.loads(funcs.read_text()))
        print(f"{name:15s} base={base} functions={count}")


if __name__ == "__main__":
    main()
