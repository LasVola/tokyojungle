# Tokyo Jungle Recompiled

![Tokyo Jungle running natively, the title screen](assets/title-screen.gif)

**A native PC port of Tokyo Jungle (PS3, 2012), made by static recompilation. No emulator.**

Tokyo Jungle was a digital-only PS3 exclusive whose studios are gone, and the PS3 store is closing.
This project turns the game's own PS3 code into a Windows program using
[ps3recomp](https://github.com/sp00nznet/ps3recomp). You supply your own copy of the game.

## Status: Playable

- **Survival mode works start to finish.** A full **102-year run** (about 2 hours) was played with no crash or freeze.
- **60 FPS**, including big fights. In the October 17 play test every second with 800+ draws stayed at 60
  (82 s of play: average 59.9 FPS, one second at 52).
- **2K mode:** renders at 2560x1440 (2x the PS3's 1280x720) for sharp grass and edges. 720p is still the default.
- **PC controls:** keyboard, mouse buttons and Xbox controllers, all rebindable in game. Menus show PC key prompts.
- **Still to check:** Story mode, save and reload across sessions, and local 2-player.

![The game's Stats screen after the run: Max years survived 102](assets/stats-102-years.jpg)

![Grass at the PS3's 720p (left) and in 2K mode (right)](assets/grass-720p-vs-2k.png)

*Left: the PS3's 720p. Right: 2K mode.*

## Controls

Press **F1** in game (or **Back + Start** on a controller) to change any key or button.
Each row shows what the action does. Changes save to `controls.ini` and work right away.

![The in-game Controls screen](assets/controls-screen.jpg)

Button prompts in the game's menus show your PC keys instead of PS3 buttons, and follow your bindings:

![PS3 button prompts (top) and the PC key prompts that replace them (bottom)](assets/pc-key-prompts.png)

| Action | Keyboard | Controller |
|--------|----------|------------|
| Move | W A S D | Left stick |
| Dodge | Arrow keys | Right stick |
| Jump | Space or Z | A |
| Eat / mark / carry | F | B |
| Claw attack | E | X |
| Pack: fight / decoy | V | Y |
| Creep / Bite | Left Ctrl / Left Shift | LB / RB |
| Roar | Caps Lock | Right stick click |
| Pack commands | 1 | LT |
| Pause, map / Info | Enter / Backspace | Start / Back |
| Items, menus | Numpad 8 / 2 / 4 / 6 | D-pad |

To quit, close the window. A save in progress finishes first.

## Easy build (Windows, automatic)

Put three things in one folder:

- [`BUILD.bat`](BUILD.bat) from this repository
- your extracted game folder (any name; it must contain `USRDIR\EBOOT.BIN` and `PARAM.SFO`)
- your license file `UP9000-NPUA80523_00-TOKYOJUNGLE00001.rap`

Double-click `BUILD.bat`. It installs what is missing with winget (Git, Python 3.11, CMake, Ninja,
LLVM, Visual Studio 2022 Build Tools, FFmpeg), downloads ps3recomp and applies the patches,
decrypts the game with your license through RPCS3 (an existing install is used, otherwise the
portable build is downloaded from the official RPCS3 releases and checked by SHA-256), generates
and compiles the code, and leaves `TokyoJungle.exe` in the folder. The first build takes
30-60 minutes; everything is logged to `build.log`.

`TokyoJungle.exe` asks for 1280x720 or 2560x1440 and window or full screen, and remembers the
choice (hold Shift while starting it to change it again). Movies need FFmpeg next to the game,
which the build copies in. The `.build` folder can be deleted afterwards.

Extra steps this build performs that the manual steps below do not cover:

- `patches/ps3recomp/tj-build-fixes.patch`: ps3recomp fixes from after the pinned commit
  (find_functions call-target pass; SPU lifter `bi $rN` classification, non-r0 link returns and
  `orbi`/`xorhi`/`xorbi` decoding, without which the player model renders as a spike;
  `find_spu_functions --raw`), plus the first connected XInput pad as player 1 and full screen on
  any monitor.
- The 18 SPU images are inside `EBOOT.ELF`; `scripts/tj_extract_spu_images.py` cuts them out by
  fingerprint and `scripts/tj_lift_spu.py` lifts them.
- `scripts/tj_split_fixups.py` replaces `gen_stubs.py` for the lifter's split output.
- `scripts/fix_import_slots.py` takes import names the NID database lacks from `src/main.cpp`
  (without `cellSailPlayerInitialize2` the movies show a white screen).
- `tj.edat` is replaced by its decrypted contents (the original is kept as `tj.edat.original`).

## Build and run

You need Windows, CMake, Ninja, LLVM (clang-cl), Visual Studio 2022 Build Tools, Python 3.10+,
and your own legally owned copy of Tokyo Jungle (NPUA80523).

```bash
git clone https://github.com/LasVola/tokyojungle.git
git clone https://github.com/sp00nznet/ps3recomp.git
cd ps3recomp && git checkout d7fff845aca42b5083791801a01d150f5f0ec18c
git apply ../tokyojungle/patches/ps3recomp/ps3recomp-tokyojungle-2026-10-17.patch
cd ../tokyojungle
pip install -r requirements.txt
cp /path/to/your/EBOOT.ELF /path/to/your/PARAM.SFO input/
python scripts/analyze.py && python scripts/gen_stubs.py && python scripts/post_lift.py
python -I scripts/fuse_spu_loops.py --apply   # optional: faster geometry jobs
cmake -B build-clang -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl
cmake --build build-clang
```

Run it with the tested settings (720p, 60 FPS):

```powershell
powershell -File scripts\launch_tokyojungle.ps1 -Run -Recommended -GameData <your extracted game folder>
```

2K mode (2560x1440, windowed, paced to the monitor's refresh):

```powershell
powershell -File scripts\launch_tokyojungle.ps1 -Run -Recommended -RenderScale 2 -DisplayVBlank -PresentPhase -GameData <your extracted game folder>
```

Which game files this was built and tested with (SHA-256, and the Redump disc it came from):
[docs/GAME_INPUT_HASHES.md](docs/GAME_INPUT_HASHES.md).

## More

- [docs/TESTING.md](docs/TESTING.md): play-test log and frame-pacing numbers
- [docs/HISTORY-2026-09.md](docs/HISTORY-2026-09.md): earlier development notes
- [docs/ABOUT.md](docs/ABOUT.md): how the recompilation works, and why this game

| Region | ID | Format |
|--------|----|--------|
| NA (Digital) | NPUA80523 | PSN (tested) |
| JP (Disc) | BCAS20219 | Blu-ray |
| EU (Digital) | NPEA00421 | PSN |

## Credits and legal

- Original port and ps3recomp: [sp00nznet](https://github.com/sp00nznet).
- This fork: renderer, 60 FPS and 2K work, pacing, stability and controls (August–October 2026), play-tested by LasVola.

The code here is MIT licensed ([LICENSE](LICENSE)). No game data is included; you must use your own copy.
**Tokyo Jungle** is a trademark of Sony Interactive Entertainment. This project is not affiliated with
Sony, Japan Studio or Crispy's.

**Let's keep Tokyo Jungle alive.**
