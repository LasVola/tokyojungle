#!/usr/bin/env python3
"""gen_stubs.py steps that still matter, for the lifter's split output.

gen_stubs.py expects a single generated/ppu_recomp.c; the lifter now writes
ppu_recomp_000.cpp, ppu_recomp_001.cpp, ... This does the two steps the build
needs, on every shard:

1. Rewrite generated/ppu_recomp.h as the "patched header": include
   recomp_bridge.h (vm_base, VM helpers) and declare every func_* referenced.
2. Strip the lifter's "MSVC compatibility helpers" block (ppc_mulhd,
   ppc_mulhdu, __builtin_clz); recomp_bridge.h already defines them. The
   block has nested #if's, so the outer #ifdef/#endif pair is matched.

Idempotent.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
GEN = ROOT / "generated"
sys.path.insert(0, str(ROOT / "scripts"))
from gen_stubs import CRT_OVERRIDES  # noqa: E402

MARK = "/* MSVC compatibility helpers */\n"


def strip_preamble(path):
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    start = text.find(MARK)
    if start < 0:
        return 0
    lines = text[start + len(MARK):].split("\n")
    if not lines[0].startswith("#ifdef _MSC_VER"):
        raise RuntimeError(f"{path.name}: unexpected helper block")
    depth = 0
    for end, line in enumerate(lines):
        s = line.strip()
        if s.startswith("#if"):
            depth += 1
        elif s.startswith("#endif"):
            depth -= 1
            if depth == 0:
                break
    path.write_text(encoding="utf-8", errors="surrogateescape", data=text[:start] + "/* MSVC helpers stripped -- provided by recomp_bridge.h */\n"
                    + "\n".join(lines[end + 1:]))
    return 1


def main():
    shards = sorted(GEN.glob("ppu_recomp_*.cpp"))
    if not shards:
        sys.exit("no generated/ppu_recomp_*.cpp; run scripts/analyze.py first")
    referenced = set(CRT_OVERRIDES)
    for shard in shards:
        referenced |= set(re.findall(r"\b(func_[0-9A-Fa-f]+)\b", shard.read_text(encoding="utf-8", errors="surrogateescape")))
    decls = "\n".join(f"void {fn}(ppu_context* ctx);" for fn in sorted(referenced))
    (GEN / "ppu_recomp.h").write_text(
        '/* Patched header */\n#pragma once\n#include "recomp_bridge.h"\n\n'
        '#ifdef __cplusplus\nextern "C" {\n#endif\n\n' + decls +
        '\n\n#ifdef __cplusplus\n}\n#endif\n')
    stripped = sum(strip_preamble(s) for s in shards)
    print(f"ppu_recomp.h: {len(referenced)} declarations; helper blocks stripped: {stripped}")


if __name__ == "__main__":
    main()
