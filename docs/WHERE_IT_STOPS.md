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
