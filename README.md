# OpenRiseOfNations

**An open-source, native macOS engine for *Rise of Nations: Extended Edition*.**

OpenRiseOfNations is a from-scratch reimplementation of the game engine, in the spirit of
[OpenRA](https://www.openra.net/) and [OpenMW](https://openmw.org/). It runs natively on Apple Silicon and Intel Macs
(Metal + AppKit) and loads the art, maps, rules and scripts from **your own copy of the game**. It ships no game files:
no art, no sounds, no maps, and none of the original program code. (The one exception is the main-menu logo, a fan
adaptation of the *Extended Edition* logo.)

> **Status: early but playable.** You can load the tutorials and the stock scenarios, select and command units,
> gather resources, build a city, train an army and fight a computer opponent who builds, expands and attacks.
> Plenty is still missing. See [What works](#what-works) and [Help wanted](#help-wanted).

---

## Fork: custom skirmish setup

This fork adds a native setup dialog after choosing a Skirmish map: civilization, human/computer/closed positions,
teams, global AI difficulty, visibility, stockpiles and conquest/map victory settings. It uses the map's existing
positions and starting armies/technologies; it does not generate random maps. See [scope and testing](docs/custom-skirmish.md).

Build this fork to use the feature; the upstream 0.1.1 DMG does not include it.

## Contents

- [Quick start (download the app)](#quick-start-download-the-app)
- [Getting the game files onto a Mac](#getting-the-game-files-onto-a-mac)
- [Controls](#controls)
- [What works](#what-works)
- [How this was built](#how-this-was-built)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [Help wanted](#help-wanted)
- [Legal](#legal)

---

## Quick start (download the app)

1. **Own the game.** You need *Rise of Nations: Extended Edition* (for example
   [on Steam](https://store.steampowered.com/app/287450/Rise_of_Nations_Extended_Edition/)).
2. **Put the game files on your Mac**: see the next section.
3. **Download** `OpenRiseOfNations-<version>.dmg` from the Releases page, open it and drag **OpenRiseOfNations** into
   **Applications**.
4. **First launch.** The app isn't notarised by Apple yet, so macOS will warn you the first time. Right-click (or
   Control-click) the app in Applications and choose **Open**, then **Open** again. Alternatively, go to
   *System Settings → Privacy & Security* and click **Open Anyway**.
5. **Pick a mode.** The app opens on the game's own Main Menu (drawn with the menu art, backdrops, fonts and music
   of your install): **Tutorials** (start here), **Skirmish** (ready-made maps against computer opponents, with an AI
   difficulty setting) and **Scenarios** (chess exercises and campaign battle maps). It finds the game folder in
   `~/Games/RiseOfNations` (or a Steam / CrossOver folder) on its own and asks for it only when it can't; **Change…**
   on the Main Menu points it at another folder that contains `Data` and `scenario`. In a game, `Esc` (with nothing
   selected) or `F10` opens the game menu with **Return to Main Menu**; the game-over screen offers it too.
   **Multiplayer** is not available yet. The menus work with the mouse or the keyboard (arrows, Return, Esc).

Requirements: macOS 12 Monterey or newer, any Mac with Metal (all Apple Silicon Macs and most Intel Macs from 2012 on).

## Getting the game files onto a Mac

The engine reads the files of the **Windows** version of the game. There are two easy ways to get them.

**A. Download them with SteamCMD** (no Windows PC needed):

```bash
brew install --cask steamcmd
steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir ~/Games/RiseOfNations \
         +login YOUR_STEAM_USERNAME +app_update 287450 validate +quit
```

SteamCMD asks for your password and Steam Guard code. The download is about 2.6 GB. The app finds
`~/Games/RiseOfNations` automatically.

**B. Copy them from a Windows PC.** Copy the whole game folder, usually
`C:\Program Files (x86)\Steam\steamapps\common\Rise of Nations`, to your Mac (for example to `~/Games/RiseOfNations`).

The engine never modifies these files.

## Controls

| Action | Input |
|---|---|
| Select | Left-click; drag a box (Shift adds, Ctrl/⌘ toggles, double-click selects all of that type on screen) |
| Move, attack, set rally point | Right-click |
| Scroll | Move the mouse to the screen edge, use the arrow keys, two-finger scroll, or right-drag |
| Zoom | Mouse wheel / pinch, or `+` / `-` |
| Control groups | Ctrl+0…9 to store, 0…9 to recall (twice to centre) |
| Minimap | Click or drag to look, right-click to order |
| Build / train / research | The command buttons at the bottom left |
| Pause · fog of war · HUD · bloom | `P` · `F` · `H` · `B` |
| Cancel / clear selection · game menu (resume, main menu, quit) | `Esc` · `F10` (`Esc` with nothing selected) |
| Quit | `⌘Q` |

Power users can also start the app from the terminal with a scenario and options:

```bash
/Applications/OpenRiseOfNations.app/Contents/MacOS/OpenRiseOfNations ~/Games/RiseOfNations scenario/Tutorial2/tut2.scx --difficulty 4
```

Without a scenario it opens the Main Menu; `--menu tutorials` (or `skirmish`, `scenarios`) opens a list directly. Set
`RON_MUTE=1` to start without sound.

## What works

| Area | State |
|---|---|
| **Rendering** | Terrain and transitions, water, rivers, mountains, forests, every building and unit with its animations and team colours, the original lighting, HDR tone mapping and bloom, fog of war, construction sites with scaffolding, projectiles, corpses |
| **Interface** | The original HUD layout and skins per nation and age: resource bar, minimap, selection panel, command card (build, train, research, rally points), cursors, objectives, messages, tutorial highlights |
| **Simulation** | Movement and path-finding, formations and group moves, collision, fog of war and line of sight, diplomacy, combat (damage, projectiles, buildings that shoot, deaths), city capture and elimination, victory conditions |
| **Economy and production** | Gathering (farms, woodcutters, mines, oil), income and caps, markets, tribute, construction, training queues, research, ages, cities and territory |
| **Computer opponent** | Economy, building placement, research, ages, new cities, armies that muster and attack, diplomacy |
| **Scripts** | A compatible compiler and virtual machine for the game's BigHugeScript; the tutorials and scenarios run their triggers and objectives |
| **Audio** | Scenario voice-overs, effects and music |
| **Not yet** | Random maps and the skirmish setup screen, the Conquer the World campaign map, multiplayer, saves and replays, garrisons, heroes and spells, transports and aircraft, healing and attrition, many smaller details |

The simulation is written to be **bit-identical** with the original (the game uses deterministic lockstep for
multiplayer), but so far it has only been checked against reference tools derived from the original code, not yet
against real recorded games. See [Help wanted](#help-wanted).

## How this was built

The game ships with full debug symbols for its executable. That made it possible to study the original program
with [Ghidra](https://ghidra-sre.org/) and write down how each system works, without copying its code:

1. **Specifications first.** Each subsystem (terrain, rendering, movement, combat, economy, production, AI, scripting,
   the interface, …) was reverse-engineered and described in a written specification in [`docs/`](docs/), in our own
   words, citing the original functions by name and address as evidence.
2. **Reference tools.** Most specs come with a small JavaScript reference implementation in [`re/tools/`](re/tools/)
   that reads the game's data (damage tables, costs, gather rates, the script grammar, …).
3. **A new implementation in C++17**, written from the specs and checked against the reference tools, often byte for
   byte. For example, the damage table matches on all 169,312 attacker/target pairs, and the rules tables match the
   original's own memory image from a recorded game.
4. **Verified by looking at it.** The renderer was compared with the original by reading snapshots.

No decompiled code, art, sound or other game data is included in this repository. The development was done with
heavy use of AI coding agents (Anthropic's Claude Code), directed and reviewed by the maintainer.

Good starting points for reading: [`docs/systems-map.md`](docs/systems-map.md) (how the original is organised),
[`docs/STATUS.md`](docs/STATUS.md) (where things stand and what's next), and
[`docs/sim-implementation.md`](docs/sim-implementation.md) (what is ported, file by file).

## Building from source

You only need Apple's Command Line Tools (no full Xcode, no other dependencies):

```bash
xcode-select --install                       # once
git clone https://github.com/ben-wright-1/OpenRiseOfNations.git
cd OpenRiseOfNations
bash build-mac.sh                            # about a minute
./build/ronmap ~/Games/RiseOfNations scenario/Tutorial1/tut1.scx
```

Package the app and the disk image (universal Apple Silicon + Intel build):

```bash
bash package-mac.sh                          # -> build/OpenRiseOfNations.app and build/OpenRiseOfNations-<version>.dmg
```

`build-mac.sh` also builds command-line tools that are useful for development and testing:

| Tool | What it does |
|---|---|
| `ron-sim` | Runs the simulation headless with scripted commands; prints per-frame state digests and checks determinism |
| `ron-check` | Parses and poses every unit model and animation in the game data |
| `ron-rules` | Builds the rules tables and compares them with a recorded game's memory image |
| `ron-world` | Builds the simulation's world grid for a scenario |
| `ron-combat-check`, `ron-prod-check`, `ron-econ-check` | Compare damage, cost and income calculations with the JS reference tools |
| `ron-script` | Parses, compiles and disassembles the game's BigHugeScript files |
| `ron-ui-check` | Checks the interface layout reader against the JS reference |
| `ronviewer` | A unit and animation viewer |

Snapshots are the easiest way to check rendering changes: `./build/ronmap <game dir> <scenario> --snapshot out.png`,
and `./build/ronmap <game dir> --menu skirmish --snapshot out.png` for the menus.
`bash re/tools/sim-all.sh ~/Games/RiseOfNations 300` runs every stock scenario headless and checks determinism.

## Project layout

| Path | Contents |
|---|---|
| `engine/assets` | Portable readers for the game's formats: chunk files, `.bh3` models, `.bha` animations, `.tga`, XML data, scenarios, interface layouts, fonts |
| `engine/render` | Platform-independent rendering logic: render states, terrain and dressing meshes, farms, fog overlay, lighting |
| `engine/sim` | The deterministic simulation: rules, world, units, orders, path-finding, fog, combat, economy, production, AI, script host |
| `engine/script` | The BigHugeScript compiler and virtual machine |
| `platform/metal`, `platform/audio` | Metal renderer, UI layer, AVFoundation audio |
| `apps/` | The game app (`map-mac`), the viewer and the command-line tools |
| `docs/` | The specifications |
| `re/` | Reverse-engineering tooling: Ghidra scripts, job files and the JS reference tools (decompiler output stays local) |

## Help wanted

This is a big project and contributions of every size are welcome. Some ideas:

- **Recorded games and saves.** The single most useful thing for correctness: replays (`.rcx`) and saves from the
  Windows game, especially multiplayer replays, which carry checksums every turn. They let us check the simulation
  frame by frame.
- **Side-by-side comparisons.** If you know the original game well, play the same scenario in both and report
  anything that looks, sounds or behaves differently (screenshots help a lot).
- **Missing systems:** random map generation and the skirmish setup screen, the Conquer the World campaign, garrisons,
  heroes and spells, transports, aircraft and missiles, healing and attrition, saves and replays, multiplayer
  networking, menus and options.
- **Engine and platform work:** performance, a proper app bundle and settings, controller and accessibility support,
  notarised builds, Linux/Windows ports of the platform layer (the engine itself is portable C++).
- **Testing:** more automated checks, especially comparisons against the original game.
- **Documentation:** clearer explanations of the specs, diagrams, a contributor guide.

Open an issue to discuss what you'd like to work on, or just send a pull request. Please don't commit any files from
the game, decompiled code or other extracted material: describe behaviour in your own words in `docs/`, as the existing
specs do.

## Legal

OpenRiseOfNations is free software under the **GNU General Public License v3.0** (see [`LICENSE`](LICENSE)).

This is an unofficial fan project. It is **not affiliated with, endorsed by, or sponsored by** Microsoft, Big Huge
Games, SkyBox Labs or any of their partners. *Rise of Nations* and *Rise of Nations: Extended Edition* are trademarks
of their respective owners. You need a legally obtained copy of *Rise of Nations: Extended Edition* to use this
engine; no part of the original game is distributed here. The main-menu logo (`apps/map-mac/resources/menu-logo.png`) is
a fan adaptation of the *Extended Edition* logo and is not covered by the GPL; its rights belong to the original owners.
