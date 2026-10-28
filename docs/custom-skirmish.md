# Custom skirmish on existing maps

Choose **Skirmish**, select a map and press **Play**. A native macOS setup dialog opens before the match starts.
Choose exactly one human position and at least one opposing computer. Each existing map position can be closed,
controlled by the human, or controlled by the computer; choose its civilization and one of four teams, or No team.
The menu's difficulty is the initial value for the match-wide AI difficulty selector.

Other settings: normal/explored/all-visible fog, original stockpiles or 500/2000 of each of the six resources,
and conquest (all cities lost) or the map's existing victory settings. Starting teams are allied; other players
start at war. The engine's existing diplomacy behavior still applies during play.

## Scope and limitations

This is a configurable **scenario-based** match, not a fresh random-map start. It retains the selected map's terrain,
starting positions, armies, buildings, technologies and ages. Changing civilization changes the player tribe used
by the engine; preplaced unique units and already researched technologies are retained from the map. Existing
engine gaps in nation bonuses, combat and victory rules still apply. The map's scenario scripts are disabled so
objectives cannot spawn removed players or overwrite the custom configuration; AI production scripts still load.
The original Tutorials and Scenarios launch paths are unchanged.

You may enable/disable the map's existing positions, but cannot add positions absent from it. Map size, generation
seed, random terrain, fresh starts, per-bot difficulty, age selection and save/load are follow-up work.
Nothing writes to the Steam installation.

## Implementation

`engine/sim/skirmish.*` validates and transforms a copy of the parsed Scenario. It preserves slot IDs (including
non-contiguous slots), removes objects from closed seats, replaces diplomacy, and supplies player/team counts and
visibility to GameInfo before load. Both the renderer and simulation consume the same configured Scenario.
`apps/map-mac/skirmish_setup.mm` supplies the native dialog. Custom setup is cleared after loading and before any
ordinary scenario launch; custom simulation errors fail the launch instead of silently showing a static map.

## Validation

Run `bash tests/run-skirmish.sh` on Linux or macOS. Synthetic fixtures cover closed seats, civilization and human
selection, original stockpiles/technologies, diplomacy, team counts, conquest settings and invalid configurations.
These tests need no proprietary game data. GitHub Actions also compiles the complete macOS app.

Manual checks on a Mac with the purchased game data are still required:

1. Start Skirmish, cancel setup, then launch a tutorial: verify its original objectives and controls.
2. Choose a map with multiple positions; use a different human position/civilization, close a bot and start.
   Verify the HUD/control belongs to the chosen position and the closed position's units and cities are absent.
3. Start with two allied positions and one enemy; verify alliance/visibility and enemy combat.
4. Check the six resource amounts and fog choices; leave and start another match with different settings.
5. Finish a conquest match; verify the result with the actual enabled nation count.
6. Compare changed-civilization production, graphics and researched tech availability against the original game.

No gameplay or UI validation is claimed by the data-free configuration tests or by a successful compilation.
