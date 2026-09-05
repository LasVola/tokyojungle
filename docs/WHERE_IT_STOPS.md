# Where it stops — 2026-09-05

The README said the title "parks in its main loop waiting on a single counter
that nothing in the emulator writes". That was right, but under-specified. This
is the same wall, measured.

## It is a condvar deadlock, not a spin

The main thread is not polling. It is **asleep in `sys_cond_wait`** (lv2 syscall
107), which is why no amount of log reading shows it doing anything.

| thread | state |
|---|---|
| tid=0 (main) | `cond_wait(cond=3)`, infinite timeout, in `func_00236C14` |
| tid=4 (`sgsfile-req-th`) | `cond_wait(cond=1)`, idle |
| signals, whole run | exactly one — `cond_signal(cond=2)` from tid=4 |

**Nothing ever signals cond 3.** The file-request worker did its one piece of
work, signalled cond 2, and went back to sleep on cond 1. Both parties are now
waiting and neither will wake the other.

## The object, and the counter

`func_00236C14` is the wait loop:

```c
r31 = r30 + 0x27C;              /* the condvar          */
loc_00236C50:
    r3 = r31;
    call func_0023070C();       /* sys_cond_wait        */
    r0 = vm_read32(r30 + 0x278);/* the counter it wants */
    r9 = sraw(r0, 0x1F);        /* test its sign        */
    ... loop back to loc_00236C50
```

At runtime `r31 = 0x024F4A54`, so the object is `r30 = 0x024F47D8`, with the
counter at **`0x024F4A50`** and the condvar at `0x024F4A54`.

`YDKJ_WWATCH=0x024F4A50` (a generic write watch despite the name — it lives in
`runtime/ppu/ppu_loader.cpp`) catches **22 writes, every one a zero**, at
consecutive addresses `…A50/A58/A60/A68/A80/A88` with the return address
advancing 0x21 each time: one unrolled clear loop at init. After that the
counter is never written again by anybody.

The object belongs to the file-request subsystem — `sgsfile-req-th` is created
with `arg=0x24F4520`, and `0x024F47D8` is 0x2B8 into that same structure.

## Ruled out

- **Outstanding requests.** `TJ_POLLWATCH=0x198` reads `[r31+0x198] = 0`
  throughout, so `func_00213A14`'s "wait for requests to drain" is satisfied.
- **VBLANK.** `TJ_TIMEWATCH` shows `vbobj=0x00C0410C`, `vb+0x14` climbing
  2854 → 3717 over the run. Our vblank driver runs and the guest's vblank
  callback is invoked (`func=0x001F2F30`, its argument incrementing each call).
- **A missing `/dev_hdd0`.** 339 failed `stat('/dev_hdd0')` per run, fixed by
  pointing `PS3_HDD0_ROOT` at `gamedata/dev_hdd0` (drops to 206). A real bug,
  and **not this one** — the wall is bit-identical with it fixed.
- **The game clock.** `gameclock[0x00C04A68]` is 0 and never advances, but that
  is a *consequence*: the main thread that would advance it is asleep.

## Narrowed further, same day — it is a missing COMPLETION, not a missing signal

Four measurements, in order:

**1. Only one function can release the main thread.** `func_002369EC` is the
sole code in the binary that both decrements the counter and signals the
condvar:

```c
r9 = vm_read32(r31 + 0x278);   /* the counter          */
vm_write32(r31 + 0x278, r9);   /* decremented, stored  */
r3 = r31 + 0x27C;              /* ...then signal this  */
```

**2. It is never invoked.** It is reachable only as a tail call from
`func_002369C0` (the lifter emits `g_trampoline_fn = func_002369EC; return;`).
`func_002369C0` has no direct callers; it is address-taken through an OPD at
guest `0x00350530`. `PS3_CALLTRACE_TO=0x002369C0` reports **zero calls** in a
45-second run — with the trace verified working (80 lines with the filter off).

**3. It is not a lost wakeup.** `PS3_COND_SPURIOUS_MS=200` turns the infinite
wait into a 200 ms one, so the main thread re-tests its predicate five times a
second. **It is still stuck after 60 s** — 27 STUCK reports. A spurious wakeup
is legal for a condvar, so this cannot invent progress; the fact that it does
not help proves the predicate is *genuinely unsatisfied*. The counter really is
still positive, and no signal would have helped.

**4. The trampoline is not being dropped.** The runtime drains `g_trampoline_fn`
on the indirect-call path and in every guest-call entry point, so the tail call
would run if the parent ran. The parent does not run.

So the chain is intact and simply never entered. What is missing is whatever
should *invoke* `func_002369C0`.

### The one lead into it

`func_002369C0`'s descriptor (`0x00350530`) is referenced exactly once in the
whole image, as data at guest **`0x0035B6B8`**, in a table whose neighbours are
plain code addresses (`0x002A1210`, `0x002A1240`, `0x002A1250`, …) rather than
descriptors. Mixed entry kinds mean this is probably not a vtable. Identifying
that table, and who reads it, is the next step.

## What to chase next

Find the producer that should increment `[0x024F47D8+0x278]` and signal cond 3.
It is not `sgsfile-req-th` (idle on cond 1) and not the vblank path (running).
The two candidates are a request that is never *submitted* — so no worker ever
has reason to complete it — or a completion path that runs on a thread we never
start.

## Reproducing

```bash
PS3_VERBOSE=0 PS3_VFS_ROOT=input PS3_HDD0_ROOT="$PWD/gamedata/dev_hdd0" \
RSX_LIVE_DRAW=1 TJ_TIMEWATCH=1 TJ_POLLWATCH=0x198 \
  ./build-master/tokyojungle.exe input/USRDIR/EBOOT.elf
```

Measure with `PS3_VERBOSE=0`: the per-event log is heavy enough to change what
the title does, not just how fast.

Built against **ps3recomp master** (not the shared working tree) — 156 objects,
links clean, and the NID table must be regenerated from the same tree the
runtime library is built from.
