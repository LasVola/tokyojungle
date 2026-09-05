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

---

# Update — the deadlock is fixed; the wall is now the game clock

Four bugs fixed, in the order each exposed the next. The title went from
**finished tearing itself down** to **running its main loop**.

## 1. The condvar deadlock — root cause

`/dev_hdd0` was not mapped to anything real, so the file request **failed**, so
its completion callback never ran, so the counter never decremented. Measured
with `PS3_COND_PEEK`, not inferred:

```
[PEEK] [0x024F4A50]=1  at cond_wait(cond=3)    one request outstanding
[PEEK] [0x024F4A50]=0  after the mapping fix   reached zero
```

The fix is host-side, not code: `/dev_hdd0/game/NPUA80523/USRDIR` must resolve
to the real `input/USRDIR`. A junction does it:

```powershell
New-Item -ItemType Junction `
  -Path   input\gamedata\dev_hdd0\game\NPUA80523\USRDIR `
  -Target input\USRDIR
```

## 2-4. Three runtime bugs behind it

- **`cellSpursShutdownJobChain` unimplemented** — returned whatever was in `r3`,
  so the caller read garbage for "did the shutdown take?"
- **SPURS queue cancellation was global** — `cellSpursFinalize` cancelled *every*
  attached queue. This title runs one SPURS for its data install and a second
  for audio; finalising the first killed the second's, which the title read as
  the SPU going silent (69 x `failed to recv data from SPU`).
- **`cellSail` player handles** — thirteen entry points validated a
  `CellSailPlayer*` **guest pointer** as an index (`handle >= CELL_SAIL_PLAYER_MAX`),
  which rejects every real call. `SetSoundAdapter` failing is what made the title
  close a resource it never opened, terminate its SGX sound system and block in
  `sys_ppu_thread_join` forever.

| | before | after |
|---|---|---|
| log | frozen at 1,297 lines | 5,755 and growing |
| SPU recv errors | 69 | 0 |
| queues cancelled | 2 | 0 |
| `SGX system terminate` | 1 | 0 |
| `sys_ppu_thread_join` parked | yes | 0 |

## Where it stops now

The main thread sits in `sys_timer_usleep` (syscall 141) in a poll loop, and
**the game clock never advances**:

```
gameclock[0x00C04A68]=0   vb+0x0=1  vb+0x8=0  vb+0x14=2942 (climbing)
```

The vblank object ticks correctly and the guest's own vblank callback
(`func_001F2F30`) runs every frame — verified against the disassembly, the lift
is faithful — but `[0x00C04A68]` is written exactly twice in a run, both zeros,
from init paths. Nothing advances it, and the main loop waits for it.

**Three functions write `+0x18` of the object at `[TOC+0x1860]`** (i.e. the
clock) and are the candidates for the missing producer:

| function | reachability |
|---|---|
| `func_0020677C` | **0 direct callers**, appears once in the image |
| `func_00207BD8` | 1 direct caller |
| `func_0020A958` | 1 direct caller — `func_0020B20C`; also calls a cond-signal wrapper, so it looks like the producer |

Next step is to establish whether `func_0020B20C`'s chain is entered at all.
Note draws/flips are still 2/8, so no geometry, and there are 41 unhandled
`[RSX] unknown method` entries (`0x1D88`, `0x1800`, `0x0398`, `0x0394`, `0x01B8`,
`0x01B4`) — but those are downstream of a main loop that is not yet ticking.

---

# The full chain, measured end to end

Traced by instrumenting every branch target and every call site along the path,
rebuilding between each step. Each link below was observed, not inferred.

```
main thread            sys_timer_usleep, polling the game clock at 0x00C04A68
   waits on            -> never advances (written twice per run, both zeros)

the clock is written by func_0020A958
   reached from        func_0020E8E0 -> func_0020E93C -> func_0020B4A8 -> func_0020A958
   func_0020E8E0's only reference is an OPD at 0x0034EE80, which the boot log
   shows is:  sys_ppu_thread_create tid=6 name="sgx-audio-thr"
   => THE GAME CLOCK IS ADVANCED BY THE AUDIO THREAD

the audio thread       enters func_0020E93C exactly once
   of its 27 branch targets, only 3 are ever hit, each once:
       loc_0020E9E0 -> loc_0020EA1C -> loc_0020EAA0
   of its 20 call sites, 4 fire:
       func_0025EB00 (cellAudioGetPortConfig) -> func_0025EB20
       -> func_0020DC90 -> func_0020B4A8            <- last
   inside func_0020A958 the last call is func_0020A8C8
   inside func_0020A8C8 all three calls fire, the last being func_0020EFD0

func_0020EFD0          LOOPS, calling import slot 0x003426AC =
                       cellSpursJobGuardNotify, and never returns
```

So the audio thread runs the clock-writing path **once**, descends into
`func_0020EFD0`, and stays there. Its cycle per iteration is

    CreateJobChainWithAttribute -> JobChainAttributeSetName ->
    JobGuardInitialize -> RunJobChain -> JobGuardNotify -> JoinJobChain

and it completes roughly **one iteration every five seconds** -- about 7 in a
35-second run, where audio would want ~60 a second. The guard is registered
(`JobGuardInitialize` runs) and `JobGuardNotify` reports "0 remaining", so the
guard is being satisfied; something else in the cycle is costing ~5 s, which
has the shape of a timeout being waited out rather than work being done.

**That is the frontier**: why `func_0020EFD0`'s SPURS job cycle runs at 0.2 Hz
and never returns to its caller. Everything above it in the chain is accounted
for.

## Method note

Instrumenting lifted C directly is the technique that worked, after three
attempts to read the answer out of the source went wrong (a "dead" r9 that was
an argument register, a "zero" counter from a truncated log, an "early exit"
that branches on CELL_OK). `generated/` is regenerable, so probes there cost
nothing permanent:

- probe every `loc_*:` label to find which paths execute
- probe every `ctx->lr = ...; func_*(ctx);` to find the last call made
- use `tools/callgraph.py --callees` to instrument a whole level at once and
  save rebuild cycles

Also implemented this round: `cellSailGraphicsAdapterInitialize` and
`cellSailGraphicsAdapterSetPreferredFormat` (both were UNIMPLEMENTED). They did
not move the clock -- only `sceNpScoreInit` remains unimplemented, and that is
online leaderboards.
