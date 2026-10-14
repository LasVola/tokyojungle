# ps3recomp changes used by this port

`ps3recomp-tokyojungle-2026-10-14.patch` holds every runtime change this port
needs, as one patch against
[sp00nznet/ps3recomp](https://github.com/sp00nznet/ps3recomp) commit
`d7fff845aca42b5083791801a01d150f5f0ec18c`.

```bash
git clone https://github.com/sp00nznet/ps3recomp.git
cd ps3recomp
git checkout d7fff845aca42b5083791801a01d150f5f0ec18c
git apply ../tokyojungle/patches/ps3recomp/ps3recomp-tokyojungle-2026-10-14.patch
```

Keep `ps3recomp/` next to `tokyojungle/` (the CMake build looks for it there).

Main areas (133 files):

- **RSX → Direct3D 12 renderer** (`libs/video/rsx_d3d12_backend.c`, `cellGcmSys.c`):
  - full geometry/texture/render-target path;
  - prefix replay with GPU ownership and early texture-label publication;
  - 384 texture slots, a 4096-entry vertex-shader cache and an on-disk shader cache;
  - background shader compiling, multi-threaded vertex conversion and a host FXAA present pass;
  - a libgcm-style FIFO ring recycle and an Alt-key menu-loop fix.
- **SPURS / SPU** (`libs/spurs`, `runtime/spu`): job chains, job guards, workload dispatch and the reservation and main-write gates.
- **System** (`libs/system`, `runtime/syscalls`, `runtime/ppu`):
  - save data, with an in-flight guard so a window close never cuts a save;
  - EDAT (klicensee) reads for the title's own `tj.edat`;
  - fonts, PAMF movies, pad input, and cached hot-path environment lookups.
- **Tests**: native unit tests under `libs/video/tests`, `runtime/*/tests` and `tests/`.
