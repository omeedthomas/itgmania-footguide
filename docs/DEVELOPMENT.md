# Developing FootGuide

## Repository layout

```
mod/                          everything that gets installed, laid out like the Simply Love folder
  Modules/FootGuide.lua         the module: chart loading, gameplay badges / side panel, Ctrl+F, trainer routing
  Modules/FootGuide/Solver.lua  the footing solver (pure Lua 5.1, no game dependencies)
  Modules/FootGuide/Trainer.lua the trainer screen's actors and logic
  Scripts/FootGuide-Settings.lua per-player mode + the Player Options row
install.ps1, uninstall.ps1    Windows installer / uninstaller
tools/theme-patch.ps1         the file list and the metrics.ini / en.ini edits, shared by both scripts
tests/                        tests that run outside the game (see below)
docs/                         this file
```

## How it hooks into Simply Love

- **Modules.** Simply Love loads every `*.lua` in its `Modules/` folder at startup. Each one returns a table of `ScreenName -> ActorFrame`, and those actors are drawn on top of that screen and receive a `ModuleCommand` whenever it appears. `FootGuide.lua` adds actors for `ScreenSelectMusic` (Ctrl+F), `ScreenGameplay` (badges / side panel) and `ScreenFootGuideTrainer`. Files inside `Modules/FootGuide/` aren't loaded automatically; `FootGuide.lua` loads them with `loadfile`.
- **Scripts.** `Scripts/FootGuide-Settings.lua` is loaded by the theme at startup. It defines the global `FootGuideSettings`, which both the module and `metrics.ini` use.
- **Player Options row.** `metrics.ini` lists the row in `[ScreenPlayerOptions] LineNames` and defines it as `LineFootGuide="lua,FootGuideSettings.OptionRow()"`.
- **Trainer screen.** `[ScreenFootGuideTrainer]` in `metrics.ini` is a bare `ScreenWithMenuElements`; all its content comes from the module. To get there, `FootGuide.lua` wraps Simply Love's `Branch.GameplayScreen` and `Branch.AfterSelectMusic`. When any player's mode is Trainer, those return `ScreenFootGuideTrainer` instead of `ScreenGameplay`.

## The solver

`Solver.lua` exposes:

- `ExtractNoteData(text, filetype, stepsType, difficulty, description, normalize)`: finds one chart in `.sm` / `.ssc` text.
- `ParseNotes(noteData, numCols)`: returns `{col, beat, kind, endBeat}`.
- `BuildRows(notes)`: groups notes (which need `.time` / `.endTime`) into rows, and works out which columns are held during each row.
- `Solve(rows, layoutName, yield)`: returns per-row `{notes = {col, foot}, L, R, movedL, movedR, tech}` plus totals.

It's a dynamic-programming search (beam width 48) over states of the form *(left foot placement, right foot placement, which foot moved last)*. A placement is a single panel, a bracket (two panels within 1.5 panel-widths), or "float" (pushed off a panel by a footswitch). Costs live in `Solver.Weights`:

| Cost | Default | Charged for |
|---|---|---|
| `DOUBLESTEP` | 1000 | the same foot twice in a row on different panels; free while the other foot holds, and scaled down after long gaps |
| `SPIN` | 600 | the left foot two or more panels right of the right foot |
| `SLOW_FOOTSWITCH` / `FOOTSWITCH` | 400 / 100 | stepping onto the other foot's panel, slow (>= 0.2s) / fast |
| `HOLD_TAP` | 400 | tapping with a foot that's holding |
| `SPREAD` | 150 | legs spread more than 2.6 panels (doubles) |
| `FAST_JACK` / `JACK` | 70 / 20 | the same foot on the same panel consecutively, fast / slow |
| `CROSSOVER` | 40 | per panel-width of crossing, per row spent crossed |
| `BRACKET` | 30 | a bracket |
| `STACKED` | 15 | feet vertically aligned (Up + Down) |
| `DISTANCE` | 10 | per panel-width of foot travel |

The weights were tuned with `tests/compare.lua`. It compares the solver's crossover, footswitch, bracket and doublestep counts against the `#TECHCOUNTS` that ITGmania stores in its song cache, and those come from ITGmania's own C++ StepParity solver.

## Engine details worth knowing

- **Input events.** `event.button` is the physical button (pad panels are `"Left"`, `"Down"`, ...). `event.GameButton` is its menu meaning (`"MenuUp"`, `"Start"`, `"Back"`, ...). Return `true` from an input callback when you have handled the input yourself.
- **Back on a ScreenWithMenuElements** does nothing by default; the trainer starts the transition itself, back to `ScreenPlayerOptions` for the same song (`SetNextScreenName("ScreenPlayerOptions"):StartTransitioningScreen("SM_GoToNextScreen")`).
- **Badges** are positioned with `ArrowEffects.GetYOffset / GetXPos / GetYPos / GetAlpha`, composed with the transforms of `PlayerP1` and its `NoteField` child. Mini comes from the NoteField's zoom. The code checks at runtime whether ArrowEffects columns are 1-based or 0-based.
- **Music in the trainer** uses `SOUND:PlayMusicPart(path, start, length, fadeIn, fadeOut, loop, applyRate)` and `SOUND:StopMusic()`, with its own clock (`GetTimeSinceStart()` × music rate).

## Tests

The Lua runs under [fengari](https://github.com/fengari-lua/fengari), a Lua VM in JavaScript, so no game or native Lua is needed. The code sticks to the subset of Lua shared by 5.1 (ITGmania) and 5.3 (fengari).

```bash
npm install

# Synthetic patterns with known footing: crossovers, footswitches, jacks, holds, brackets...
npm test

# The whole mod (settings row, gameplay badges, side panel, Ctrl+F, trainer in both modes)
# in a fake StepMania environment, on a real chart from your library.
# Paths to songs are relative to the first argument.
node tests/run.js tests/module_smoke.lua "C:/Games/ITGmania" "/Songs/Pack/Song/Song.ssc" StepsType_Dance_Single Difficulty_Hard
node tests/run.js tests/module_smoke.lua "C:/Games/ITGmania" "/Songs/Pack/Song/Song.ssc" StepsType_Dance_Double Difficulty_Hard "Mirror, Reverse"

# Compare against ITGmania's own technique counts. The arguments are: the song cache,
# the folders that contain Songs/ (separated by ;), max songs, "verbose" or "",
# weight overrides, and "use every Nth song".
node tests/run.js tests/compare.lua "%APPDATA%/ITGmania/Cache/Songs" "C:/Games/ITGmania;%APPDATA%/ITGmania" 100000 "" "" 20
node tests/run.js tests/compare.lua "<cache>" "<roots>" 100000 "" "CROSSOVER=60,BRACKET=40" 20   # try other weights
```

In the smoke test, `module_smoke.lua` replaces the engine with small stubs: actors that record calls, a fake NoteField with `ArrowEffects`, fake input events, and a fake music player. If you use a new engine API, add a stub there.

## Ideas

- **Loop and ramp in Practice mode:** loop a section, speed it up after each clean pass, and slow it down after misses.
- **A pattern sheet** before the song: the whole chart with L/R written on every arrow.
- **Fading guidance:** badges fade out the more times you've seen a pattern.
- **More languages** for the option row.
