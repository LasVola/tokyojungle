#!/usr/bin/env python3
"""Extract the 18 SPU images that src/gen/spu_workloads.c registers.

They are not captured at run time: every one is stored inside EBOOT.ELF. Each
slice is checked against the FNV-1a-64 fingerprint the registry expects, so a
different EBOOT fails loudly instead of producing wrong code.

Output: generated/spu_images/spujob_<FP>_<size>.bin (the names the tests and
tj_lift_spu.py use).
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ELF = ROOT / "input" / "EBOOT.ELF"
OUT = ROOT / "generated" / "spu_images"

# name -> (file offset in EBOOT.ELF, size)
IMAGES = {
    "animationjob16": (0x29E900, 40896), "geometryjob17": (0x2A8900, 48032),
    "socjob13": (0x2B4500, 6352),        "survivaljob18": (0x2B5E00, 4544),
    "task7000": (0x2B7000, 10708),       "task9A00": (0x2B9A00, 33876),
    "socjob": (0x2C3600, 64912),         "socjob5": (0x2D3400, 13840),
    "socjob7": (0x2D6A80, 17424),        "socjob9": (0x2DAF00, 72464),
    "socjob3": (0x2ECA80, 34704),        "socjob6": (0x2F5280, 19488),
    "socjob8": (0x2F9F00, 24720),        "socjob11": (0x300000, 25232),
    "socjob4": (0x306300, 9488),         "socjob12": (0x308880, 46928),
    "socjob10": (0x314000, 20624),       "socjob2": (0x319100, 53408),
}


def fnv1a64(data):
    # Same constants as runtime/spu/spu_workload.c (its offset basis is
    # 1469598103934665603, one digit short of the textbook FNV basis; the
    # registry fingerprints were computed with it).
    h = 1469598103934665603
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def main():
    registry = (ROOT / "src" / "gen" / "spu_workloads.c").read_text()
    expected = {name.lower(): int(fp, 16) for name, fp in
                re.findall(r"#define TJ_(\w+?)_FP\s+0x([0-9A-Fa-f]+)ULL", registry)}
    elf = ELF.read_bytes()
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (offset, size) in IMAGES.items():
        data = elf[offset:offset + size]
        fp = fnv1a64(data)
        if fp != expected[name.lower()]:
            sys.exit(f"{name}: fingerprint {fp:016X} != expected "
                     f"{expected[name.lower()]:016X} (different EBOOT?)")
        (OUT / f"spujob_{fp:016X}_{size}.bin").write_bytes(data)
    print(f"{len(IMAGES)} SPU images extracted to {OUT}")


if __name__ == "__main__":
    main()
