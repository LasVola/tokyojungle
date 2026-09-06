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

## 2026-09-05 — past the SAIL wait and the sound bank; stops at the SGX tick

Two fixes this session, both verified:

1. **cellSail never invoked the guest event callback** (ps3recomp PR #133).
   `cellSailPlayerInitialize2` registers a handler; we stored it and never
   called it. The boot thread polled `[0x00B589F0]` every 1 ms forever.
   The event is `{be32 major; be32 minor}` in one register — read off the
   title's own handler `func_0018195C`, not guessed: major=2 (CALL_COMPLETED)
   with minor = the call id (1 BOOT, 2 OPEN_STREAM, 10 START, 11 STOP).

2. **VFS root doubling.** cellFs mappings are joined under `s_root_path`, so
   `"/dev_hdd0/game/NPUA80523/" -> "input/"` became `input\input\USRDIR\...`
   under `PS3_VFS_ROOT=input`. `static.sgd` never loaded →
   `sgxResClose unknown ID (0)` → `SGX system terminate`. Mapped to the root
   instead. SGX terminate 1 → 0.

The title now clears both, reaches `cellSaveDataAutoLoad2`, and keeps its
engine up.

### Where it stops now

Main thread waits in `func_002139CC` until the SGX tick at **`0x00C04A68`**
(`[[r2+0x1860]+0x18]`) passes 3. Measured: `pending=0`, `deadline=0`,
`now=0` — the tick is written twice at construction (memset + `func_00207BD8`)
and never again.

Chain, all measured rather than inferred:

- the tick is `func_0020A958` (`[obj+0x18]++`), reached only by falling
  through `func_0020B20C`;
- whose only call site is `func_0020B4A8` at `0x20EACC`, in the audio
  thread's outer loop `func_0020E93C`;
- the audio thread enters `func_0020E93C` once, descends into
  `func_0020EFD0`, and never returns to that call — `[clockobj+4]` walks
  `-1 → 1 → 2 → 3` and stops at 3 (phase 4 = "returned" never happens);
- inside `func_0020EFD0` it cycles `loc_0020F108 ↔ loc_0020F1F0` (~19,760
  each), and the "job completed" block `loc_0020F170` is **never** entered.

Why: it receives the SPURS job-chain completion event, then indexes
`jc + 0x2B8 + data2*0x80` and requires `[entry+0x34] != 0`. Measured at the
branch: `rc=0`, `data2=0`, `base=0x0292E900` (the job chain), `[entry+0x34]=0`,
and a scan of all 16 slots finds none with a non-zero `+0x34`.

So the next gate is **SPURS job-chain completion reporting**: our SPU jobs run
and report "job complete", but nothing writes the per-job completion
descriptor or puts a meaningful `data2` in the completion event.

Forcing the tick from outside confirms this is the only thing holding the
boot thread — the drain loop exits immediately and the main thread moves on to
`func_0021FD64`. Still 0 draws, so there is at least one more gate behind it.

### Upstream of the SGX tick: the audio graph is silent

Continuing down the chain above, the SPU side turns out to be **working**, and
the real gap is further up.

The audio job does real work — `SPU_DMALOG` shows it GET its command block from
its user-data pointer (`0x02933400`), stream in ~82 KB in 16 KB chunks, and PUT
it all back. (An earlier "the job never touches its user data" reading was
wrong: `SPU_WATCHEA` only matches PUT *destinations*, so GETs never registered.)

But the buffer it processes is **entirely zero** — 20480/20480 words — so the
job is faithfully processing silence, and never writes the completion word the
PPU waits on. It issues no DMA into the chain/descriptor region at all.

Why the buffer is silent, from the title's own stdout:

    *** sgxbus.c(934)  : failed to regist module
    *** sgxbus.c(1634) : unknown module name (tverb)

Both `.sgd` banks now load correctly (`static.sgd` 8,995,536 bytes, `SGXD`
magic, and `tj_bus.sgd` 2048 bytes), so this is not the file fix regressing.
Probing the registration function `func_00202214` shows eleven modules
attempted, in order:

    user dmix thru amp filter comp lverb delay umix lverbx tverb

`tverb` is the last one and the one that fails. Ruled out by measurement:

- **not allocation** — every module including `tverb` gets a buffer
  (`user 0x0297EBA0 … lverbx 0x0297FD10 tverb 0x0297FDE0`);
- **not an unresolved indirect call** — none logged in the whole run.

`func_00202214` succeeds only when `func_00201D38` returns a count equal to an
expected count in r30; for `tverb` it comes back short. `func_00201D38` (319
lifted lines) dispatches through per-module OPDs and stores results into
`[r9+0x1C]`, `[r9+0x20]`, … so one of those per-module entries is returning
failure for `tverb` specifically.

That is the next thing to chase: **why `tverb` alone fails to register**. It is
plausibly the whole chain — no `tverb` -> `sgxbus` cannot build the effect graph
-> no audio work queued -> silent buffer -> no completion -> audio lap never
finishes -> SGX tick frozen -> boot thread blocked. That last link is NOT yet
proven, so treat it as the leading hypothesis rather than a diagnosis.

### Correction and the real audio-init failure: only one bus is created

The `tverb` registration failure above is **timing-dependent, and usually does
not happen**. Instrumenting the registration path directly:

- all eleven modules allocate fine (`user 0x0297EBA0 … tverb 0x0297FDE0`);
- all eleven pass `func_00201D38` — probing both call sites shows the returned
  count equal to the expected count every time (`ret=76 want=76`, … 22 of 22);
- the "failed to regist module" print site (`func_00202214`'s `loc_00202378`,
  identified by its `r5=0x3A6`=934 line-number argument) **never executes** in a
  normal run.

The message only appeared in a run that also had `PS3_FSLOG=1`, i.e. under
different stdout timing. Treat audio init as **racy**; that is itself a finding.

The stable failure, reproduced on every clean run, is one line further on:

    *** sgxbus.c(1641) : out of range bus (1,1)

`func_00200470`, `loc_00200D78` (`r5=0x669`=1641). The two numbers are the
requested bus index (r7) and the bus count (`[r22+0x48]`). Measured: **want=1,
count=1** — the title asks for bus index 1 and only one bus exists.

`r22` is a STACK address (`0xD00FF6BC`), so the count is a parse result, and a
write-watch shows it written exactly **once, as 1** — it is not a running tally
of successful creations.

That is wrong against the data: `tj_bus.sgd` (2048 bytes, `SGXD`, read in full)
defines four buses — the strings are `buss_1 buss_2 buss_3 buss_4`, plus
`Tverb UMix_ambi UMix_Music Tverb1 tverb umix` and preset text
(`preset=SMALL_HALL-S`, `dry=70`, …). Its header fields read as LITTLE-endian
(`+04 = 0x7F6 = 2038`, `+08 = 0x800 = 2048`, `+14 = 0x488` for the `BUSS`
chunk), which is worth checking against how the title parses them.

So the open question is now narrow and data-backed: **why does parsing a
four-bus `tj_bus.sgd` yield a bus count of 1?** Resolve the writer of
`[r22+0x48]` (the write32 write-watch prints only host RVAs — it needs the
guest-fn resolution the write64 path already has, see ps3recomp #132) and
compare what it reads out of the file against the layout above.

### The bus count comes from the SGXD resource system, not a text parse

With write32 backtraces now resolving to guest functions (ps3recomp #134), the
writer of the bus count is named directly:

    [WWATCH] write32 0xD00FF704 = 0x00000001 bt: func_01180600 func_00214B38
             func_002012E0 func_00201448 func_001BCA6C func_001EFF74 ...

`func_00214B38` (436 lifted lines) writes it, called twice from
`func_002012E0` (at 0x00201324 and 0x00201368). Its arguments are NOT a
string/format pair — measured:

    @0x00201324 r3=0000003E r4=0 r5=0        r6=0 r7=D00FF9C8
    @0x00201368 r3=0000003E r4=0 r5=D00FF640 r6=0 r7=D00FF9C8

so it is a resource query — type id `0x3E` (62), result written into the
caller's stack buffer — against the SGXD data already loaded from
`static.sgd`/`tj_bus.sgd`, i.e. part of the same `sgxres` system that produced
the earlier `sgxres.c(167) : sgxResClose unknown ID (0)`.

Next step for whoever picks this up: work out what resource type `0x3E` is and
why querying it over a four-bus `tj_bus.sgd` returns 1. `func_002012E0`'s second
call passes an extra stack pointer (`r5`), so comparing the two calls is
probably the fastest way in.

### Root of the audio failure: every DSP module declares zero I/O buses

Tracing the `out of range bus (1,1)` check to its operands (probe at the error
label, not between the `if` and its `goto` -- an earlier probe placed there made
the branch unconditional and had to be redone):

    [TJCHK] r7=1 r28=0x0297FDE0 [r28+0x28]=0 [r28+0x2C]=0
            r22=0xD00FF6BC [r22+0x48]=1 [r22+0x5C]=0

`r28` is the **module** object (`0x0297FDE0` is exactly `tverb`'s allocation),
not the bus table -- the bounds are the module's own input/output bus counts at
`+0x28`/`+0x2C`, and both are 0. Dumping all eleven registered modules:

    user    @0x0297EBA0 +0x28=4 +0x2C=4
    dmix    @0x0297ECA0 +0x28=0 +0x2C=0
    thru    @0x0297F160 +0x28=0 +0x2C=0
    amp     @0x0297F1C0 +0x28=0 +0x2C=0
    filter  @0x0297F3A0 +0x28=0 +0x2C=0
    comp    @0x0297F620 +0x28=0 +0x2C=0
    lverb   @0x0297F7C0 +0x28=0 +0x2C=0
    delay   @0x0297F890 +0x28=0 +0x2C=0
    umix    @0x0297FA00 +0x28=0 +0x2C=0
    lverbx  @0x0297FD10 +0x28=0 +0x2C=0
    tverb   @0x0297FDE0 +0x28=0 +0x2C=0

So this is **systematic across every SPU DSP module**, not a `tverb` quirk.
`user` is the only one with real counts, and it is registered through a
different class (`func_001FEDF4`) than the DSP modules (`func_002065E4`).

A write-watch over a module descriptor shows those two words are only ever
ZEROED -- once by the memset and once by `func_00201D38` through an indirect
memcpy (`func_01180600`, a PRX-region helper). Nothing ever populates them.

Ruled out along the way:

- not the `.sgd` data -- both banks load and verify (`SGXD`, full length);
- not the module SPU binaries -- their heads are raw SPU code, no metadata
  fields at those offsets;
- not a lifter jump-table gap -- the DSP module handler `func_002065E4` is a
  9-case jump-table dispatcher and a probe on its `default:` records **zero**
  misses.

Two failure texts alternate run to run (`sgxbus.c(934) : failed to regist
module` vs `sgxbus.c(1641) : out of range bus`) but the run never succeeds: 6/6
sampled runs fail, so treat them as two surfacings of this one root, not a race
that can be won.

**The question to answer next:** where is a DSP module's input/output bus count
supposed to come from? `func_002065E4` (the DSP module class entry) receives
commands through its jump table; one of those commands, or the `func_00201D38`
copy source, should carry the I/O counts. Finding the producer of `user`'s 4/4
via `func_001FEDF4` and comparing is probably the fastest route in.

`TJ_CLOCK_TICK=<ms>` (added to src/dispatch_glue.cpp) fakes the SGX audio tick
so the render path can be worked on without waiting for audio. With it, the boot
thread unblocks and runs a real loop, but the title still opens only the two
sound banks and never loads a graphics asset -- so audio is genuinely the gate,
not a parallel dead end.

### Mechanism found: the module I/O counts are answered BY THE SPU

`func_00201D38` fills the module descriptor by calling the module class entry
repeatedly with a QUERY ID in r5, storing each result in a successive field:

    r5=2 -> module+0x1C   r5=3 -> +0x20   r5=4 -> +0x24
    r5=5 -> module+0x28 (input bus count)
    r5=6 -> module+0x2C (output bus count)

For DSP modules that entry is `func_002065E4`, a bounds-checked jump table
(`if (r5 > 8) return;` then `target = table[r5*4] + base`). The table resolves
correctly -- read from the ELF at `[TOC+0x1880] = 0x00206614`:

    table[5] = +196 -> 0x002066D8   (query 5)
    table[6] = +160 -> 0x002066B4   (query 6)

Both are lifted cases and a probe on the `default:` records zero misses, so
dispatch is fine. Each handler tail-calls

    func_002065D8([sgxobj+0x70], desc, 0, 0x105 / 0x106)

and `[sgxobj+0x70]` measures as **0x0292E900 -- the SPURS audio job chain**
(`[+0x74]` is the audio buffer 0x029338E0). So the PPU asks the **SPU** how many
buses a DSP module has, by submitting a job, and reads the answer out of the
completion event.

That is the same `jc_signal_done` path in libs/spurs/cellSpurs.c whose own
comment says a synthetic payload "means the caller reads back zero for whatever
it asked" -- it computes the SPU's outbound mailbox into `d2`/`d3` and then
pushes a hardcoded 0. Confirmed experimentally: setting `SPURS_EVENT_D3=<n>`
changes the failure (`sgxbus.c(1641)` becomes `sgxbus.c(934)`), so **data3 is
the answer channel**.

**Attempted and REVERTED**: wiring `g_spurs_job_mbox` into the event.
- Putting it in **data2 corrupts memory** -- the audio consumer treats data2 as
  a job index (`(data2 << 7) + 0x2B8` into the chain, then dereferenced), and
  the `[TOC+0x1860]` SGX pointer came back `0xFFFF0000`.
- With data2 left 0 and only data3 carrying it, some runs got further (no
  sgxbus error, reaching `cellSaveDataAutoLoad2` + trophy setup) but others
  still corrupted, and no run ever produced a draw or advanced the SGX tick.

The mailbox holds LS addresses (0x400, 0x2000, 0x14860, …), not query answers,
so feeding it back is wrong. A correct fix needs the SPU side to actually
service commands **0x105/0x106** and post the real count. That is the next
piece of work, and it is SPU-side, not PPU-side.

### The SPU DOES answer the query -- we throw the answer away

Correlating each job's command with the mailbox it posts (`SPURS_JOB_CMD=1`,
reading the command out of the job's own command block at `desc+0x4C`):

    cmd=0x0102 -> mbox=0x00014860      cmd=0x0104 -> mbox=0x000083C0
    cmd=0x0105 -> mbox=0x00000001      cmd=0x0106 -> mbox=0x00000001
    cmd=0x0200 -> mbox=0x00000000      cmd=0x2100 -> mbox=0x00000000

**Commands 0x105 and 0x106 -- the input and output bus counts -- are answered
correctly by the SPU: both come back 1.** The command reaches the SPU (dumping
the command block at submit time shows `0102`, `0104`, `0105`, `0106`, `2100`,
`3100` …), the job runs it, and posts the answer in its outbound mailbox.

`jc_signal_done` then discards it and pushes a hardcoded 0, exactly as its own
comment warns. So the answer exists and never reaches the PPU.

**Attempted fix, and why it was REVERTED.** Forwarding `g_spurs_job_mbox` as the
event's data3 (data2 left 0, and gated to command range 0x0100-0x01FF so audio
jobs are unaffected) does work as far as it goes:

- the `sgxbus` error clears in 3 of 4 runs, against 0 of 6 at baseline;
- those runs reach `cellSaveDataAutoLoad2` and `cellFsStat`, which baseline
  runs never reach;
- no `SGX system terminate`.

But it also makes the title write `0xFFFF000000000000` over its own TOC at
`0x0035AA80` (the `[TOC+0x1860]` SGX object pointer), via `func_0023F3F4` --
which is **memcpy** (an 8-bytes-at-a-time copy loop, `dst=r3 src=r4 len=r5`)
called from the registration path with the TOC slot as its destination. A
write-watch confirms the write does not happen at baseline
(`SPURS_EVENT_D3=0` reproduces baseline without a rebuild: zero writes).

The cause is that the gate is too broad. Commands 0x102/0x103/0x104 are in the
same range but their answers are **LS addresses** (0x83C0, 0xB4D0, 0x14860),
not counts -- `func_00201D38` stores query results into `module+0x1C/+0x20/
+0x24` and one of those becomes a memcpy destination. Only 0x105/0x106 return
counts.

So the remaining work is to establish, per command, what the answer means --
which of the 0x1xx queries return counts and which return LS-relative pointers
that must be translated (or not forwarded at all) -- rather than forwarding the
mailbox wholesale. That is a small, well-bounded piece of work now that the
mechanism and the measurement technique are both established.

### Correction: forwarding the answer does not work, and the "clean" runs are corrupt

Narrowing the forwarding gate to ONLY the two count commands (0x105/0x106),
leaving every other command pushing 0, does **not** stop the corruption:

    run1 err=(none)          clockobj=0xFFFF0018   draws=0
    run2 err=(none)          clockobj=0xFFFF0018   draws=0
    run3 err=sgxbus.c(934)   clockobj=0x00C04A68   draws=0
    run4 err=sgxbus.c(934)   clockobj=0x00C04A68   draws=0

Read that the right way round: the runs with **no error message are the ones
whose TOC has been clobbered** (`[TOC+0x1860]` reads 0xFFFF0000). The absence of
`sgxbus.c(...)` there is a symptom of the title running off the rails, not of
the audio graph building. Every run whose TOC is intact still fails exactly as
baseline does. The earlier reading of "3 of 4 runs clear the error" as progress
was wrong.

Note also that a count of 1 would not satisfy the check anyway: the failing
comparison is requested index 1 against the count, and 1 vs 1 is still out of
range. So either the counts should be larger than 1 for these modules, or the
answer is not meant to travel this way at all.

That makes the plain "forward the mailbox as data3" theory wrong, despite
`SPURS_EVENT_D3` demonstrably changing behaviour. Something else consumes the
value first. The next thing to check is whether the answer is supposed to be
written into the JOB DESCRIPTOR instead -- specifically `job_desc+0x6C`, the
word the audio loop tests at `loc_0020F108` before it will process a completion
(see the earlier section) -- with data3 carrying something else entirely.

### Ruled out: the job never writes its descriptor, for ANY command

Per-command diff of the job descriptor between guest memory and the LS copy the
job just ran against (`SPURS_JOB_DESCBACK=1`, printing the command from the
job's own command block):

    [descback] job=0x0292EB80 cmd=0x0102: (no change)
    [descback] job=0x0292EB80 cmd=0x0104: (no change)
    [descback] job=0x0292EB80 cmd=0x0200: (no change)
    [descback] job=0x0292EB80 cmd=0x3100: (no change)
    [descback] job=0x0292EB80 cmd=0x2100: (no change)
                     ... 30 samples, every one "(no change)"

So `job_desc+0x6C` is not written by the SPU under any command, and it is not
written by the title (a write-watch shows it only ever zeroed). By elimination
the writer is the SPURS **kernel** -- which is the part we emulate on the host.

That is where this stops for now, and it stops on a judgement call rather than a
missing measurement: the PPU loads that word and immediately dereferences it
(`r10 = [entry+0x34]` then `r0 = [r10+0]`), so it is a POINTER to a completion
structure whose layout is not established anywhere in this investigation.
Supplying one means inventing both the value and the structure behind it, and
three successive theories on this blocker (tverb, the SPU_WATCHEA artifact, and
the data3 forward) each looked right and each had to be retracted after
measurement. Guessing a pointer here would most likely produce a fourth.

What a next attempt should establish FIRST, before writing any code:

1. what structure `[job_desc+0x6C]` points to on hardware -- an RPCS3 trace of
   this title's audio bring-up would settle it directly (see
   [[ydkj-rpcs3-memory-dumper]] for the oracle approach used on YDKJ);
2. whether `cellSpursJobGuardNotify`'s return value participates -- the audio
   loop calls it immediately before each receive at `loc_0020F108` and branches
   on it, and our HLE always returns 0.

### Correction again, and a second bug behind the first

Two things were wrong in the section above and are now settled by measurement.

**1. `job_desc+0x6C` is NOT the blocker.** Reading the loop-back block
`loc_0020F1F0`, which every iteration passes through:

    r0 = r30 + 1;                    /* r30 = data2 from the event = job index */
    r9 = vm_read32(r28 + 0x4284);    /* number of jobs */
    if (r0 < r9) goto loc_0020F108;  /* more to come -> wait again */
    r31 = vm_read32(r1 + 0xBC);      /* THE ANSWER: data3, low half */

Measured: `data2=0`, `jobcount=1`, so `1 < 1` is false and the block **exits**
every time. `func_0020EFD0` is therefore *called* ~19,757 times, not spinning --
each call receives one completion and returns the answer read from data3. The
`[entry+0x34] == 0` branch is an ordinary "this slot has no handler" skip, not a
wall. That kills the descriptor-write-back theory entirely.

So the query genuinely does return whatever we put in data3, and we put 0.

**2. Answering the query exposes a second, independent bug.** With
`SPURS_EVENT_D3=1` (or 2, or the real mailbox -- all behave the same, so the
value is not the issue) the title proceeds and then destroys itself:

    [TJBAD] memcpy INTO TOC/OPD: dst=0x00340000 src=0x053000A0 len=65536 lr=0x0023F1D0
    [TJBAD] memcpy INTO TOC/OPD: dst=0x00350000 src=0x053000A0 len=65536 lr=0x0023F1D0

`func_0023F3F4` is memcpy; `func_0023F09C` (its caller at 0x0023F1D0) is an
**fread** -- it copies out of the stdio buffer at 0x053000A0 into a destination
pointer `r27` that ADVANCES through the copy loop. Two consecutive 64 KB chunks
land on 0x00340000 (the import/OPD table) and 0x00350000 (the TOC), which is
what makes `[TOC+0x1860]` read 0xFFFF0000 afterwards.

The destination is not bad at entry -- a probe on `func_0023F09C` for a
destination inside the image never fires -- so a large read is overrunning its
buffer rather than starting in the wrong place. This is on a code path the
title only reaches once audio init succeeds, which is why it has never been
seen before.

That is the next thing to chase: which read, and why its destination walks into
the image. It is independent of the SPURS work and probably an allocator or a
size/count mismatch.

### The corruption is an fread into NULL

Instrumenting `func_0023F09C` (the fread) at entry, on the run where it fires:

    [TJFR] read dst=0x00000000 size=1 n=23204496 FILE=0x05300000
           pos[+0x48]=87031875 end[+0x60]=87031875 buf[+0x10]=0x05300043

`fread(NULL, 1, 23204496, f)` -- a **22 MB read into a NULL destination**. The
copy loop advances its destination (`r27 += chunk`), so it starts at 0 and walks
up through memory in 64 KB chunks, which is exactly how it arrives at
0x00340000 (the import/OPD table) and 0x00350000 (the TOC). Nothing is wrong
with the memcpy or the stdio state; the caller handed it a null buffer.

That is an unchecked allocation failure: something asks for ~22 MB, gets NULL,
does not test it, and reads into it. The bump heap starts at 0x02000000 and the
two sound banks already sit at 0x03010000 and 0x038A42D0.

The path is intermittent -- it fires in roughly one run in six -- so catching
the allocation itself needs a probe that survives several attempts. That is the
concrete next step: find the ~22 MB (0x1621BD0) allocation, see why it returns
NULL, and give it room.

Summary of the two independent things standing between here and audio coming
up, both now identified rather than suspected:

1. `jc_signal_done` pushes a hardcoded 0 where the completion event should
   carry the SPU's answer in data3 (the SPU answers correctly -- 0x105/0x106
   both return 1).
2. A ~22 MB allocation returns NULL and the title freads into it, smearing 64 KB
   chunks over its own OPD table and TOC.

Fixing (1) alone is not enough and is actively harmful, because it is what
exposes (2).

### Correction: nothing fails to allocate -- the fake answer is what makes the garbage

The "unchecked 22 MB allocation failure" reading in the previous section is
wrong. TJ overrides the title's malloc/memalign/realloc onto the HLE bump
allocator (src/tj_crt_overrides.cpp -> src/import_resolver.h), which spans
0x02000000-0x08000000 (96 MB), logs every allocation of 1 MB or more, and prints
`[HLE] ERROR: heap exhausted!` when it runs dry. Across five captured runs:

- `heap exhausted` occurrences: **0**
- largest allocation logged: **0xB4 (180 bytes)**

So the ~22 MB allocation is never even attempted. Nothing returns NULL; the
caller simply passes a null buffer and a nonsense count, because it is running
on a half-initialised structure.

That reframes the whole `SPURS_EVENT_D3` result. Feeding the query a fabricated
answer does not "expose a second bug" -- it walks the title into a code path
its state was never prepared for, and the garbage `fread(NULL, 1, 23204496)` is
the consequence. Any non-zero answer (1, 2, or the SPU mailbox) behaves the
same, which fits: the value is not right, it is merely non-zero.

Note also that the SPU's mailbox answer of 1 cannot be right on its own terms --
the failing check is requested bus index 1 against the count, and 1 vs 1 is
still out of range.

**So the honest position is:** the title reads its DSP modules' bus counts out
of the completion event's data3, we push 0 there, and *what the correct value
is* is not established. Determining it means understanding what the DSP module
SPU binaries actually compute for commands 0x105/0x106, or reading the answer
off real hardware. Guessing has now been tried five times and produced five
retractions; the next attempt should start from an oracle (an RPCS3 trace of
this title's audio bring-up) rather than from inference.

### The oracle is not available yet: RPCS3 gets LESS far than we do

The recommendation above was to settle the correct bus-count answer against real
hardware behaviour rather than by inference. RPCS3 is installed
(D:/recomp/tools/rpcs3, portable layout, firmware present) so this was tried.

Booting the title's ELF works once the title id is mapped -- RPCS3 maps an ELF's
parent as /dev_hdd0/game/<its own dir>/, so it must be reached through
dev_hdd0/game/NPUA80523:

    mklink /J D:\recomp\tools\rpcs3\dev_hdd0\game\NPUA80523 ^
              G:\recomp\ps3games\tokyojungle\input

(That junction was created for this experiment and REMOVED afterwards; recreate
it with the line above.)

With the mapping right, RPCS3 runs the title but its TTY produces only the boot
line -- no `=== SGX system initialize ===`, which our recomp does reach. The log
says why:

    sys_fs_stat failed with CELL_ENOENT
        "/dev_hdd0/game/NPUA80523/USRDIR/data/tj.edat"   (JNP::NPDRMOpenThread)
    cellSaveDataAutoLoad2 failed with 0x8002b401 CELL_SAVEDATA_ERROR_CBRESULT

**`tj.edat` does not exist anywhere in the extraction.** `input/USRDIR` holds
2.4 GB against a 2.577 GB source package (which is present, alongside the
title's .rap), so roughly 170 MB is missing -- consistent with an extractor that
decrypted the EDATs to plain files and dropped the .edat wrappers. Our runtime
stubs the NPDRM path so it never notices; RPCS3 does not, and stops there.

So the oracle route needs the package extracted properly (with the .rap) before
RPCS3 can be used to answer what the DSP bus counts should be. That is a
prerequisite for the next attempt, not an optional extra -- inference has a 0/6
record on this blocker.

### Correction: the count check PASSES with the SPU's answer -- the fix is right

An earlier note here claimed "a count of 1 would not satisfy the check anyway,
since 1 vs 1 is still out of range". That was the comparison read backwards.
The actual test in `func_00200470` is

    r0 = [r28+0x28];                       /* the module's bus count */
    cmp(a = r0, b = r7);                   /* r7 = the requested bus */
    if (a < b) goto loc_00200D78;          /* ERROR when count < requested */

so it errors on `0 < 1` (what we produce today) and **passes** on `1 < 1`
(what the SPU actually answers). Forwarding the answer is therefore correct, and
"any non-zero value behaves the same" is exactly what should be expected, not
evidence against it -- any count >= 1 clears a request for bus 1.

That fix is now ps3recomp #135, off by default behind `SPURS_ANSWER_QUERIES=1`.

### The gate behind it

With the query answered, the title advances into `func_00184FC4`, which is a
plain load-whole-file:

    f = fopen(...);  if (!f) return;
    fseek(f, 0, SEEK_END);  size = ftell(f);  fseek(f, 0, SEEK_SET);
    dst = [[TOC-0xB60]];                     /* a GLOBAL buffer pointer */
    fread(dst, 1, size, f);                  /* size measured: 23,204,496 */
    fclose(f);
    *out_size = size;

`[[TOC-0xB60]]` resolves to `[0x00BCB7D0 + 0]`, and that word is **NULL**. A
write-watch over the object shows its neighbours initialised (+4 = 6, +8 = 5,
+0xC counting 0..4) and +0 never written by anything except the corruption
itself. `func_00184FC4` is the ONLY function in the lifted image that references
`TOC-0xB60`, and it only reads it.

Since the fread destination advances through the copy loop, a NULL start walks
from address 0 upward in 64 KB chunks and lands on the OPD table (0x00340000)
and the TOC (0x00350000) -- which is the `0xFFFF0000` corruption reported
earlier in this document.

23,204,496 is in the range of this title's `.pam` movies (`load_short.pam`
15.5 MB, `load_rebirth.pam` 20.8 MB, `load_long.pam` 26 MB), so this is very
likely the load/attract movie being read whole.

**Next: find what allocates that buffer and stores it at `[0x00BCB7D0]`.** It is
not the language-selection path (`func_001F06DC` writes a language CODE, 0xE, to
a different object's +0). Reached only with `SPURS_ANSWER_QUERIES=1`.

### The NULL buffer: a SPURS init that bails with CELL_ESTAT

The buffer `func_00184FC4` reads into is allocated and stored by
`func_00086178`. Near its end:

    func_0024DCEC(...);                 /* memalign -> r3 */
    r9 = vm_read32(r2 - 0x6730);        /* = 0x00BCB7D0, the same object */
    vm_write32(r9 + 0x0, r3);           /* <-- stores the buffer */

`func_00086178` has no callers and no word references: it is a fall-through,
entered by `func_0008613C` tail-transferring into it. It is a SPURS bring-up --
`sys_ppu_thread_get_id`, `func_002479F0`, `_cellSpursAttributeInitialize`,
`cellSpursAttributeEnableSpuPrintfIfAvailable`,
`cellSpursInitializeWithAttribute`, `_cellSpursEventFlagInitialize`,
`cellSpursEventFlagAttachLv2EventQueue` -- and every step branches to one shared
error exit, so any failure skips the allocation entirely.

Measured (probes inserted BEFORE each `if`, never between an `if` and its
`goto`):

- **without** `SPURS_ANSWER_QUERIES=1`: `func_0008613C`/`func_00086178` are
  never entered at all;
- **with** it: both are entered and the init **bails at step 1 with
  r3 = 0x8001000F = CELL_ESTAT**.

Step 1 is the check straight after `func_002479F0`, whose only calls are
`sys_ppu_thread_once`, `sys_lwmutex_lock`, `sys_ppu_thread_create`,
**`_sys_spu_printf_initialize`** and `sys_lwmutex_unlock`. `CELL_ESTAT` is not a
literal anywhere in `func_002479F0`, so it is propagated from one of those.
`_sys_spu_printf_initialize` has no implementation in the runtime at all (it
falls to the unresolved-NID handler, which returns 0), and the SPURS attribute
call right after it is specifically
`cellSpursAttributeEnableSpuPrintfIfAvailable` -- so the SPU printf service is
the obvious suspect, but which of the five actually returns ESTAT is NOT yet
established.

**Next: find which call in `func_002479F0` returns CELL_ESTAT.** Note the path
is intermittent (it fires in roughly one run in three even with the knob on), so
allow several runs per probe. This is a genuinely small question now: five
candidate calls, one error code, and a probe pattern that works.

### RESOLVED: sys_ppu_thread_once was unimplemented -- audio now comes up

The `CELL_ESTAT` traced to `sys_ppu_thread_once`, which had **no implementation
in the runtime at all**. It fell through to the unresolved-NID handler, which
returns `CELL_OK` -- the worst possible answer for this primitive, because the
caller is told its one-time initialiser ran when it never did. The SPURS
bring-up was therefore abandoned at its first state check, and with it the
`memalign` that fills the buffer pointer at `[0x00BCB7D0]`, which is why the
later load read into NULL.

Implemented in ps3recomp #136, with proper blocking semantics: three states in
the guest word (0 not run, 2 running, 1 done) so a second caller WAITS rather
than sailing past while the initialiser is still in flight. That distinction
matters -- the non-blocking first cut left the success rate at 3 in 6; blocking
took it to 5 in 6.

**Results.** With no env knobs at all:

- audio actually initialises. The title goes from opening **2** files for the
  whole run to **7**: `static.sgd`, `tj_bus.sgd`, and its `17_tj_menu1`,
  `19_tj_menu3`, `39_tj_ranking`, `20_tj_result`, `05_tj_stage02` sound banks;
- `sgxbus.c` errors clear in 4 of 6 runs (0 of 6 before);
- the TOC corruption is **gone** -- a write-watch on `0x0035AA80` records zero
  hits, including on runs that get all the way through;
- the tick path executes for the first time: `func_0020E93C`, `func_0020B4A8`
  and `func_0020A958` all run, where the latter two had never been entered.

Because the corruption is gone, ps3recomp #135's `SPURS_ANSWER_QUERIES` gate was
removed -- answering the query is now the default.

### Where it stops now

`func_0020A958` is entered **once**, so the SGX tick is incremented at most
once and the main thread still waits in `func_002139CC` for it to pass 3. The
audio thread's outer loop `func_0020E93C` runs a single lap and then stays down
inside the write loop, so the tick cannot reach 4.

Two things to chase from here:

1. **why `func_0020E93C`'s outer loop does not iterate.** It reaches
   `func_0020B4A8` (the tick) now, so this is much closer than it was -- the
   loop runs once instead of never.
2. **the remaining 1-in-3 race**: some runs still fail at `sgxbus.c(934)` with
   the once-initialiser never running at all, which suggests a second ordering
   problem earlier than the one `sys_ppu_thread_once` fixed.

### FIRST PIXELS: the title renders

Three more things, and the title draws for the first time.

**1. The bump heap ran dry.** Once audio came up the title allocates far more,
and the 96 MB never-reused bump heap hit its ceiling:

    [HLE] ERROR: heap exhausted! (requested 65536 bytes)   x37, then a stall

Raised to 192 MB (0x02000000-0x0E000000). The log went from frozen at 1122
lines to growing steadily.

**2. A SPURS event flag that nothing set.** With the heap fixed the boot thread
reached `cellSpursEventFlagWait` on flag `0x005F7600`, pattern 0x0001, "waiting
for an SPU workload to cellSpursEventFlagSet it" -- the same shape as YDKJ's
known blocker. `SPURS_EF_FORCE=1` got past it and produced the session's first
DRAW, confirming it was the gate; `SPURS_EF_FORCE=<n>` was added so the fake
does not cost ten seconds a wait (32 draws in 29 s instead of 7 in 130 s).

**3. The reason nothing set it: a dispatch MISS.** 218 per run --

    [spurs-job] dispatch MISS fp=0x78FEA84E1C23BB5C size=6352

exactly one image, and it is the workload that sets that flag. Captured with
`SPU_DUMP_MISS`, lifted (`find_spu_functions.py` then `spu_lifter.py`, 114
functions, 87 % coverage) and registered as image 13 in
`src/gen/spu_workloads.c`.

**Current state -- no env knobs at all, 8 runs:**

    6/8 reach audio init (7 files loaded), draws=1, dispatch MISS=0,
    heap exhausted=0

So the fake is no longer needed: the real SPU workload runs, the event flag is
set for real, and the title renders. This is the first rendering Tokyo Jungle
has done in this port.

### Still to do

Attract mode is NOT reached. The title draws once and settles rather than
running a frame loop -- `flips` stays at 8. Two things to chase:

1. **why it stops after the first draw.** With `SPURS_EF_FORCE=3` it managed 32
   draws and 12 clears before plateauing, so more of the pipeline works than one
   draw suggests; something is gating the frame loop rather than rendering
   itself.
2. **the remaining 2-in-8 race** where audio init does not happen at all and the
   run only opens 2 files. `sys_ppu_thread_once`'s blocking semantics took this
   from 6-in-6 failing to about 2-in-8; whatever is left is a second ordering
   problem earlier in the sequence.

### After first pixels: the FIFO walker derails

With the SPU workload registered the event-flag gate is gone for real -- a good
run now records **zero** `EventFlagWait BLOCKED`. The title draws, then settles.

Where it waits now: the main thread loops in `func_001F8C4C`, which calls
`cellGcmGetControlRegister` and then spins on `[ctrl+8]` -- the **ref** register
-- waiting for the RSX to reach a fence. That wait never clears because the FIFO
walker loses its place:

    [cellGcmSys] FIFO resync 0x01D00160 -> put 0x000019F0

`0x01D00160` is not a plausible get offset. The cause is visible in the
neighbouring reports:

    unknown method 0x0398 = 0x3F800000     <- float 1.0f
    unknown method 0x0394 = 0x00000000
    unknown method 0x0194 = 0xFEED0000
    unknown method 0x1D88 = 0x000012D0

`0x3F800000` is 1.0f, which is exactly the signature this file already
documents: the walker mis-counted a method batch a few dwords back and is now
decoding VERTEX DATA as commands. The resync recovers the FIFO but discards
everything between, so the fence the title is waiting on is never published.

**Next: find the method whose argument count is wrong.** The walker keeps a
64-entry trace of consumed words for exactly this (`s_tr_off`/`s_tr_w` in
libs/video/cellGcmSys.c, dumped on a bad branch) -- that dump names the command
that consumed the wrong count. This is RSX command-decode work and is
independent of everything above.

### The RSX fence never clears because `get` is outside the ring

Chasing the ref wait further. The title maps its FIFO ring:

    MapEaIoAddress(ea=0x02300000, io=0x0E000000, size=0x100000)

so the ring is IO `0x0E000000..0x0E100000`. But the walker gets stuck at

    [cellGcmSys] FIFO resync 0x01D00160 -> put 0x000019F0

and IO `0x01D00160` is **not inside that mapping**. `get` has left the ring, so
it can never reach `put`, no fences are published, and the main thread's spin on
`[ctrl+8]` never ends. This is the failure `cellGcmSys.c` already documents for
this exact title -- it previously left the ring for IO `0x00F00000`.

Note the resync that fires is the **stuck-get** one ("get has not moved across
several passes"), not the unmapped-JUMP one, so the bad-branch reporter never
runs. `gcm_fifo_dump_around` was only wired to the JUMP path; it is now wired to
the stuck path as well.

That dump comes back EMPTY, which is itself the finding: the trace ring holds
the words the walker consumed, and it has none. **The walker never consumed a
single word in these runs** -- `get` is already outside the ring before any
command is decoded, rather than being walked out of it by a mis-counted batch.

So the question is narrower than "which method has the wrong argument count":
**how does `get` come to be 0x01D00160 before any FIFO word is consumed?** Worth
checking what seeds `get` at init against what the title expects, and whether
anything writes the control block's `get` field behind the walker's back.

### Correction: it is the JUMP-PARK resync, not stuck-get

The walker resyncs from four places and all four printed the same line, so the
resync could not be attributed. Naming them (ps3recomp: unmapped-JUMP /
jump-park / unmapped-CALL / stuck-get) settles it:

    [cellGcmSys] FIFO resync (jump-park) 0x01D00160 -> put 0x000019F0

Not stuck-get, and not a mis-counted method batch either -- both earlier
readings here were wrong. With the decode dump wired to that path, the words
around 0x01D00160 are real commands, not vertex data:

    [FIFODUMP] -20 io=01D00110 w=0010A400
    [FIFODUMP] -15 io=01D00124 w=000408E4
    [FIFODUMP] -14 io=01D00128 w=00AE0401
    [FIFODUMP] -13 io=01D0012C w=00041710

So the walker is not lost. It followed a JUMP to a **park** -- the title parks
the FIFO by jumping to a block it patches later -- and the title has not patched
that block yet. Our walker waits a few passes and then resyncs to `put`, which
discards everything between and with it the fence the main thread is spinning
on, so `[ctrl+8]` never clears.

That resync is a deliberate trade (the comment in cellGcmSys.c explains that
waiting for a patch that never comes froze the FIFO for the rest of the run in
another title), but for this title it is the wrong half of the trade.

**Next: work out when this title patches its park.** The two candidates are that
we resync too eagerly (the patch is coming, just later than our pass budget), or
that the patch is written somewhere our walker does not re-read. A write-watch
on the park address while the title runs distinguishes them: if the word at
0x01D00160 is rewritten after we have already resynced, it is the former.

### Only one fence is ever published

`GCM_REFLOG=1` on a good run:

    [refq] drained fence 0x0 at getoff=000009A0     -- and that is the only one

One fence, value 0, for the whole run. The main thread's wait
(`func_001F8C4C`, spinning while `[ctrl+8] != 0`) is a wait for the ref register
to reach a value, and with a single fence drained there is nothing further for
it to observe.

So the chain to the current stall is: the walker follows a JUMP to a park the
title has not patched, resyncs to `put` and discards that segment, and from
there only one SET_REFERENCE is ever drained. The title keeps submitting work
(draws do land) but its fences do not reach the ref register, so the frame loop
never advances past the first one.

**This is RSX FIFO/fence work and is the last identified thing between here and
a running frame loop.** Concretely, in order:

1. establish whether the park at 0x01D00160 is ever patched (write-watch it) --
   that decides whether the jump-park resync is too eager for this title;
2. account for the fences: the title issues more SET_REFERENCE than the one that
   is drained, so find where the rest are lost -- the resync discarding a
   segment is the obvious suspect.

### The park is never patched -- the resync is not too eager

Tested directly: gave the jump-park path a grace period (only resync if the same
park is still standing after N passes, default ~2 s) instead of resyncing on the
first pass that sees `put` elsewhere.

    PARK GRACE ON: draws=1 clears=5 flips=8 fences=1 resync=1

Identical to without it. The title never patches that park, so waiting longer
buys nothing and the resync-to-put is the right call. Reverted -- the value was
the disproof, not the change.

That leaves the second candidate: **the fences are lost, and not because we gave
up on the park too early.** One `SET_REFERENCE` is drained per run
(`refq drained fence 0x0 at getoff=000009A0`) while the title clearly submits
more. Worth noting for whoever picks this up: `put` sits at 0x000019F0 and the
park is at 0x01D00160, which is not inside the ring the title mapped
(`ea=0x02300000 -> io=0x0E000000`, 1 MB) -- so the walker crossed into a
different IO region to get there. Establishing which region 0x01D00160 belongs
to, and why a JUMP led out of the ring into it, is the next concrete step.

### `get` is at the park before anything is decoded

`GCM_RECDBG=1` on a good run logs exactly one JUMP for the whole run, and it is
the park itself:

    [JMP] 01D00160 -> 01D00160 (put=000019F0)

and **no recycle events at all** (`[REC>]`/`[REC<]` never appear). So the walker
did not travel to 0x01D00160 by following commands -- consistent with the trace
ring being empty. `s_fifo_getoff` is already sitting on that park the first time
the walker looks, while `put` is at 0x000019F0 in a different region.

That rules out the two readings this document previously offered (a mis-counted
method batch walking the decoder into data, and the walker being stuck after
travelling there). The question is now specifically:

**why does the walker's `get` start at 0x01D00160 rather than at the title's
command buffer?** `s_fifo_getoff` initialises to 0, so something sets it, and it
is not the recycle path (which never runs here). Candidates worth checking in
order: what `cellGcmInitBody` seeds for this title's buffer, whether the title
issues a JUMP during init that we take before the trace starts recording, and
whether `put`/`get` in the control block are being read from the right places
given the title maps a second ring (`ea=0x02300000 -> io=0x0E000000`) that
neither `get` nor `put` currently points into.

### It is cellGcmFinish waiting for a fence that is in the OTHER ring

The wait decoded exactly. `func_001F8C4C` is `cellGcmFinish`:

    r0 = [ctrl + 8];                 /* ref */
    if (r31 == r0) return;           /* already there */
    do { usleep(30); r29 = [ctrl+8]; } while (r31 != r29);

so it spins until `ref` equals the reference value the title set. Measured:

    [TJW] WANT ref==0x00000001 but ref=0x00000000 put=0x000019F0 get=0x000019F0

The title is waiting for **ref == 1**. We publish **0**, and `GCM_REFLOG` shows
exactly one fence drained for the whole run -- value `0x0`, at `getoff=0x9A0`.

The `NV406E_SET_REFERENCE` handler itself is fine (`rsx_commands.c` sets
`g_rsx_last_reference = data` for method 0x0050), and the walker pushes it
correctly, so `data` really was 0. And the walker is not behind: `GCM_DRAINDBG`
shows it settle at `getoff == put == 0x19F0` and stay there, fully drained and
idle.

**So the title's `SET_REFERENCE(1)` is not in the range the walker consumes at
all.** That fits the other loose end recorded above: the title maps a SECOND
ring --

    MapEaIoAddress(ea=0x02300000, io=0x0E000000, size=0x100000)

-- which neither `get` nor `put` ever points into. The walker follows one
command stream; the fence the title is waiting on is in the other.

**Next: find how the title switches to the io=0x0E000000 ring and why the walker
never follows.** Either it issues a JUMP/CALL into it that we mis-handle, or it
drives that ring through a second control block we are not reading. Both are
checkable: log every JUMP/CALL target against the two ring ranges
(`GCM_RECDBG=1` already prints `[JMP]`), and check whether anything writes a
`put` other than the one at `GCM_CONTROL_GUEST_ADDR`.

### FIXED: the resync was swallowing the fence

Scanning the ring for `NV406E_SET_REFERENCE` settled it. There are TWO:

    io=000009A0 w=00040050 count=1 arg=00000000
    io=000019E8 w=00040050 count=1 arg=00000001

The walker parked before the second, and the resync to `put=0x19F0` stepped
straight over it -- so `ref` stayed 0 while the title spun for `ref==1`.

A resync jumping `get` to `put` is right for liveness, and losing the draws in
between is survivable. Losing a FENCE is not: nothing will ever publish that
value again and the title deadlocks with the FIFO idle. Fixed in ps3recomp #137
by sweeping the skipped range and queueing any fences before jumping. The sweep
must start from the last offset consumed BELOW put -- where the walker gave up
may be a park in another IO region, which says nothing about ring progress
(getting that wrong rescued nothing on the first attempt).

**Result, no diagnostic knobs, 6 runs:**

    4/6 good: files=7  draws=32  clears=12  rescued=8
    2/6 race: files=2  draws=0

Draws went 1 -> 32 and clears 5 -> 12, and the 32 draws that previously needed
`SPURS_EF_FORCE=3` now happen on their own.

### Where it stops now

Still no page flips (`flips` stays at 8), so the frame loop is not running. The
main thread now alternates between `func_001F8C4C` (cellGcmFinish, ~150 sleeps
per sample) and `func_001818EC` (the SAIL ready-flag poll) -- so it is getting
through work and coming back to a fence wait, rather than being stuck in one
place.

Two things left, in order:

1. **more fences are still being missed.** The rescue recovers 8 per run and the
   title still lands back in cellGcmFinish. Same technique applies: scan the
   ring for SET_REFERENCE, compare against what `GCM_REFLOG` publishes, and find
   which ones are lost and where.
2. **the 2-in-6 audio-init race** (files=2, no draws at all), unchanged from
   before -- an ordering problem earlier than the one `sys_ppu_thread_once`
   fixed.

### State after the fence fix: fences flow, one flip, waiting on SAIL START

With #137 in, a good run drains **353 fences** and their values count up
monotonically (…0xF8, 0xF9, 0xFA … 0xFF), so the fence pipeline is genuinely
working now rather than publishing a single stuck value.

But the title issues each flip call exactly **once** --
`cellGcmSetFlipMode`, `cellGcmSetFlipHandler`, `cellGcmSetFlipCommand`,
`cellGcmResetFlipStatus`, `cellGcmGetFlipStatus` -- so it is not running a
present loop. It is looping on something else and periodically returning to two
places: `func_001F8C4C` (cellGcmFinish) and `func_001818EC`, the SAIL poll.

That SAIL poll is waiting on **mask 0x100**, and from the handler decoded at the
top of this document that bit is set by `major=2, minor=10` -- CALL_COMPLETED for
**START**. The title has called `cellSailPlayerBoot` and nothing since: no
`OpenStream`, no `Start`. So it is waiting for a start it has not requested,
which means something between Boot and Start is still not happening.

This matters for the goal specifically: Tokyo Jungle's attract sequence is a
movie, so SAIL is not incidental here -- it is the thing that has to work.

Order to attack from here:

1. **why the title never progresses Boot -> OpenStream -> Start.** It has the
   graphics and sound adapters set and the player booted; find what it checks
   between those and the OpenStream call.
2. **more missed fences** -- the main thread still returns to cellGcmFinish.
   `GCM_SCANREF=1` lists SET_REFERENCE in the ring, `GCM_REFLOG=1` lists what is
   published; diff them.
3. **the 2-in-6 audio-init race** (files=2, no draws), unchanged.

### Tested: the SAIL START bit is NOT the only gate

The post-Boot path does run -- `func_00183CA0`, `func_00183C48` and
`func_001F6EDC` are all entered -- so the title is not stuck before the point
where it would ask SAIL to start. It simply never asks.

Faking the answer (report CALL_COMPLETED for START right after Boot) was tried
as a diagnostic and does NOT unlock the frame loop:

    AUTOSTART: draws=32 clears=12 files=7   flips: 9, and static across 75 s

Same 32 draws and 12 clears as without it, and flips stay put. So the
START-completed bit is something the title waits on, but supplying it is not
sufficient -- reverted, the value was the negative result.

That means the missing piece is upstream of Start: the title has its adapters
set and its player booted, and something it checks before calling OpenStream is
not satisfied. Worth noting `cellSailPlayerOpenStream` is still a stub in the
runtime that opens nothing, so even reaching it would not play anything yet.

### The movie path is never entered -- it is a scene-machine state, not a missing call

Walked the call chain for `cellSailPlayerOpenStream` (import stub
`func_0025ED20`, slot 0x3425E4) and `cellSailPlayerStart` (`func_0025EEE0`,
slot 0x34261C):

    OpenStream <- func_00182EFC <- func_0018380C <- { func_0018E7AC,
                  func_001E7404, func_001EF94C, func_001EFB80 }
    Start      <- func_00182198, func_00183194

Probed every one of them. **None of the direct callers run**, and of the four
one level up only `func_001E7404` is entered. It never calls `func_0018380C`.

The call site is `loc_001EA940` inside `func_001E7404`, which is **6,916 lifted
lines** -- the title's scene/state machine -- and the call looks like "play movie
N":

    r3 = [TOC+0x12D4];  r4 = 0;  r5 = 5;  f1 = f2 = f3 = [TOC+0x564]
    func_0018380C(...)

So this is not a missing call or a bad gate on the SAIL side. **The title's scene
machine has not advanced to the state that plays the attract movie.** That is
the thing to chase, and it is a different kind of problem from everything above:
work out which state `func_001E7404` is sitting in and what transition it is
waiting for, rather than looking for another broken HLE.

Everything downstream is ready for it: the audio engine comes up, SPU workloads
dispatch, fences flow (353 per run, monotonic), and the title renders 32 draws.

### PINPOINTED: stuck in scene state 10, sub-state 0xC8

`func_001E7404` is the title's scene machine (6,916 lifted lines, 573 blocks).
Block-profiling it and reading the dispatch:

    loc_001E7864:  switch (r28)          /* the scene state */
        10 -> loc_001E7E08
        20 -> loc_001E8118
         0 -> falls through
    loc_001E7E08:  switch ([r31+0x30])   /* the sub-state within state 10 */
        0 / 1 / 0xA / 0xB / 0x64 / 0xC8

Measured, with a counter at `[r31+0x34]` ticking inside each:

    dispatch #1   state=0   [r31+0x30]=0x00
    dispatch #21  state=0   [r31+0x30]=0x65
    dispatch #61  state=10  [r31+0x30]=0x00
    dispatch #81  state=10  [r31+0x30]=0xC8   <-- and it stays here

So the machine DOES advance -- 0 -> 10, and through the sub-states to 0xC8 --
and then sits there for as long as you let it (verified static over 135 s).

Sub-state 0xC8 is `loc_001E94FC`, and it is a single gate:

    r5 = [r31+0x34];                      /* the tick counter */
    r3 = func_001D0738(r26, 0xC8, r5);
    if (r3 == 0) goto loc_001E8868;       /* not finished -- stay */
    [r31+0x34] = 0; [r31+0x30] = 1;       /* finished -- advance */

**`func_001D0738(obj, 0xC8, counter)` never returns non-zero.** It is 716 lifted
lines of float work -- fades, positioning, layout -- i.e. a screen that reports
"still running" every tick and never reports done.

That is the single thing between here and the scene machine moving on toward the
state that plays the attract movie. Everything under it is working: audio comes
up, SPU workloads dispatch, fences flow (353/run, monotonic), 32 draws and 12
clears render per run.

**Next: why `func_001D0738` never completes for screen 0xC8.** It is a bounded
question -- one function, one screen id -- and the same block-profiling approach
used on the scene machine applies directly to it.

### The exact mechanism: the screen timer resets at 60 and can never reach 2999

`func_001D0738` is a screen driver. Its completion test, at `loc_001D107C`:

    cmp(r5, 0xBB7);          /* r5 = the tick counter passed in */
    r3 = 1;
    if (r5 > 0xBB7) return r3;   /* > 2999 -> screen is done */

so state 10 / sub-state 200 finishes once its counter passes **2999**. And in
the scene machine, `loc_001E8868` (the "still running" path) does increment it:

    [r31+0x34] = [r31+0x34] + 1;

Logging the call and the counter together:

    func_001D0738 -> 0  (counter 0,   substate 200)
    func_001D0738 -> 0  (counter 60,  substate 200)
    func_001D0738 -> 0  (counter 0,   substate 200)   <-- reset
    func_001D0738 -> 0  (counter 60,  substate 200)

**The counter climbs to 60 and is then reset to 0, over and over.** It never
gets past 60, so a screen that needs 2999 can never finish and the scene machine
can never move on toward the attract movie.

60 ticks is one second at 60 Hz, so something is restarting this screen once a
second. The only place in the scene machine that zeroes `[r31+0x34]` is the
completion path at `loc_001E94FC` -- which is not being taken, since the gate
returns 0 every time. So the reset comes from somewhere else.

**Next, and this is now a very small question: find what writes 0 to
`[r31+0x34]` (r31 = 0x00BC9BD0, so the address is 0x00BC9C04) every 60 ticks.**
A write-watch on that word names it directly -- `YDKJ_WWATCH=0x00BC9C04`, and
write32 backtraces resolve to guest functions since ps3recomp #134.

### The resetter is the scene machine itself

Write-watching the timer word (`0x00BC9C04`) names it, now that write32
backtraces resolve to guest functions (ps3recomp #134):

    write32 0x00BC9C04 = 0 bt: func_011801F4 func_001E1898 func_001EF6D0 ...   (init)
    write32 0x00BC9C04 = 0 bt: func_011801F4 func_001E7404 func_001F0BC0 ...   (repeating)

So `func_001E7404` -- the scene machine -- zeroes its own screen timer roughly
once a second, which is why the timer cycles 0..60 and the screen that needs
2999 never finishes.

`func_001E7404` has **271** separate `[r31+0x34] = ...` sites, so picking the
one that fires needs instrumentation rather than reading: tag each write with an
index and log which index actually runs. The block profile is already the right
tool for that (the state machine has 573 blocks and profiling it is what found
sub-state 200 in the first place).

Worth considering while doing that: the timer cycling 0..60 and back looks like
the machine leaving sub-state 200 and re-entering it every second, rather than a
stray write. If so the question becomes what transition takes it out and back --
and that may well be the same missing input/event that keeps flips at 9.

### Correction: it is NOT stuck at sub-state 200 -- it advances, and stops at 1

Two readings above were wrong and are corrected here.

Tagging all 263 `[r31+0x34] = ...` sites in the scene machine and logging which
one clears a counted-up timer gives exactly one hit:

    [RST] site 57 zeroes the timer (was 83)

and site 57 is the **success** path inside `loc_001E94FC` itself:

    if (r3 == 0) goto loc_001E8868;   /* still running */
    [r31+0x34] = 0;  [r31+0x30] = 1;  /* DONE -> advance */

So `func_001D0738(obj, 0xC8, ...)` **does** complete, at ~83 ticks, and the
machine **does** advance. The earlier "the timer resets at 60 and never reaches
2999" reading came from a probe that only fired while the sub-state was already
200, so it could only ever show 200.

Tracing sub-state CHANGES instead gives the real sequence:

    state 10 sub-state -> 0 -> 200 -> 1        and then nothing, for 36 s

**The machine advances 0 -> 200 -> 1 and stops at sub-state 1**, which is
`loc_001E8B7C`:

    r5 = [r31+0x34];
    r3 = func_001D0738(r26, 1, r5);       /* the same driver, SCREEN ID 1 */
    if (r3 == 0) goto loc_001E9320;       /* still running */
    [r31+0x30] = 0x64;  [r31+0x34] = 0;   /* done -> sub-state 100 */

So the current blocker is precise: **`func_001D0738(obj, 1, counter)` never
returns non-zero.** Screen id 1, not 0xC8, and its completion condition will be
a different branch of that 716-line driver than the `> 2999` one used by 0xC8.

Next: block-profile `func_001D0738` while it is running screen 1 (the profiler
is 28 blocks there, and the id arrives in r4) and find that screen's completion
test the same way `loc_001D107C` was found for 0xC8.

### Sub-state 1 is the title screen: it polls the pad and counts toward a timeout

`loc_001E8B7C` (sub-state 1) runs the same screen driver with **screen id 1**,
and its still-running path `loc_001E9320` is a title/press-start screen:

    r0 = vm_read8(r24 + 0xE);          /* pad state byte */
    if (r0 != 0) goto loc_001E9824;    /* input held -> elsewhere */
    r9 = vm_read8(r24 + [TOC+0x8CC]);  /* another pad byte */
    if (r9 != 0) goto loc_001E9824;
    r7 = [r31+0x34];
    cmp(r7, 0x64A);                    /* 1610 */
    if (r7 == 0x64A) goto loc_001EB4F4;  /* timeout reached -> advance */
    loc_001E9354: [r31+0x34] = r7 + 1;   /* otherwise tick */

and screen 1's own completion inside the driver (`loc_001D0DA8`) is
`if (counter > 0x68F /* 1679 */)`.

**So this is the title screen waiting for either a button or a timeout -- and
the timeout is what leads onward.** Measured: the pad byte reads 0x00 (correct,
nothing held) and the counter DOES climb --

    [PAD] r24=0x00BCB7F4 [r24+0xE]=0x00 counter=0
    ... counter=40 ... 80 ... 120 ... 160        (~7 ticks/sec)

At that rate 1610 is about four minutes. But an eight-minute run with the
sub-state tracer never left sub-state 1, so the two measurements are in tension:
either the counter is being reset somewhere before it arrives, or it steps past
1610 without hitting it exactly (the test is EQUALITY, not >=, so a single
skipped value would miss it permanently).

**That is the open question, and it is a small one:** log `[r31+0x34]` on every
tick of sub-state 1 for four minutes and see whether it reaches 1610, resets, or
jumps over it. Note the run has to survive the audio-init race to get there
(roughly 4 in 6), which is what made this awkward to measure in one pass.

---

# The early-boot audio failure is two bugs, and only one was mine to blame

Roughly half of all runs die early: two or three files opened, no draws, and

```
*** sgxbus.c(934) : failed to regist module
*** sgxbus.c(1634) : unknown module name (tverb)
```

Chasing that turned up **two separate causes**, and it is worth keeping them
apart because the first one masqueraded as the second for several sessions.

## 1. A deterministic one: the VFS root (fixed)

With `PS3_VFS_ROOT` unset the cellFs root stays `"."`, so every asset open
resolves a level too high and misses outright:

```
[cellFs] Open: fopen('.\USRDIR\data\snd\static.sgd', 'rb') failed: No such file
```

Losing the sound bank makes SGX tear itself down and take the boot with it.
This is fully deterministic and is now gone: `src/main.cpp` derives the root
from the ELF path, so `input/USRDIR/EBOOT.elf` yields `input`, and the env var
still overrides. `PS3_HDD0_ROOT` is defaulted alongside it. Neither is
required any more; `RSX_LIVE_DRAW=1` still is, and stays explicit.

## 2. A real intermittent one: a short reply count (open)

The remaining failure is **not** environmental. With the full documented
environment, four consecutive runs of the identical command gave two passes and
two failures. An earlier draft of this section blamed the environment for both
bugs; that was wrong, and it was wrong because three unlucky runs of a coin
flip look exactly like a deterministic failure. Three samples cannot tell a
50% process from a broken one.

Probing the guest side pins it precisely. `func_00202214` registers each DSP
module by calling `func_00201D38`, then checks that the returned count equals
the module's expected size. Eight modules register in sequence; a passing run
matches on all eight, and a failing run comes up short on exactly one:

```
PASS  want=76 got=76   want=1216 got=1216  want=88 got=88   want=476 got=476
      want=628 got=628 want=408 got=408    want=200 got=200 want=364 got=364

FAIL  want=76 got=76   want=1216 got=1216  want=88 got=88   want=476 got=284
FAIL  ... seven matches ...                                  want=364 got=272
```

Which module falls short varies between runs, which is what makes it a race
rather than a parse bug. The reply values themselves are *not* the problem: the
SPU query answers logged at the completion-event boundary (`[QANS]`, commands
0x105/0x106) are byte-identical between a passing and a failing run, both
delivering a bus count of 1. So the answers are right and something downstream
of them stops early.

**Next:** instrument the two `func_00201770` call sites inside `func_00201D38`
(the per-query submit-and-wait, invoked with r7=7 and r7=8) and log which
iteration returns short. That names the query that loses its reply.

## The title-screen timeout does fire

Settled, with a probe at the tick site and a nine-minute run: the sub-state-1
counter reaches `0x64A` (1610) exactly — 19 samples logged in 1600..1620 — and
the scene machine advances **1 → 100**. Equality rather than `>=` was not the
problem, and nothing resets the counter. It takes ~8 minutes only because that
path ticks at ~3.3/sec rather than per-frame at 60.

Sub-state 100 dispatches to `loc_001E872C`, which calls the fade helper
`func_001D0738(obj, 100, timer)` every tick and advances only when it returns
non-zero. Reading that helper: for sub-state 100 it returns 1 **only on the
tick where `timer == 0`**, hiding layers 0xC3..0xC7 and 0xB0/0xB1 on the way
out; on every later tick it returns 0 immediately. On success the scene moves
to **screen 20, sub-state 10** — a different screen, which is the attract
candidate.

So the whole transition hinges on the first sub-state-100 tick seeing
`timer == 0`. Every site that sets sub-state 100 does zero the timer (the one
that appears not to, `loc_001EB7B0`, zeroes it at its jump target
`loc_001EB048`), yet the observed run sat at 100 indefinitely. A probe on the
return value of that call is in `generated/ppu_recomp_000.cpp` and is the next
measurement.
