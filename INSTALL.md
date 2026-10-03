# Installing FootGuide

FootGuide adds a few files to your **Simply Love** theme folder and makes four small edits to two of Simply Love's text files. Those edits add the "Foot Guide" row to Player Options and register the trainer screen. Nothing of Simply Love's is replaced, and both installing and uninstalling can be done by script or by hand.

- [Requirements](#requirements)
- [1. Find your Simply Love folder](#1-find-your-simply-love-folder)
- [2a. Install on Windows (script)](#2a-install-on-windows-script)
- [2b. Install by hand (any OS)](#2b-install-by-hand-any-os)
- [3. Check that it worked](#3-check-that-it-worked)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)

## Requirements

- ITGmania with the Simply Love theme. Tested on ITGmania 1.1.0 and Simply Love 5.7.0.
- Download this repository: the green **Code** button, then **Download ZIP**, then extract it. Or `git clone` it.

## 1. Find your Simply Love folder

It's the `Simply Love` folder inside a `Themes` folder, and it already contains `metrics.ini`, `Modules`, `Scripts` and `Languages`. Usually it's in your ITGmania installation folder (next to `Songs` and `Program`):

| OS | Typical location |
|---|---|
| Windows | `C:\Games\ITGmania\Themes\Simply Love` |
| macOS | `Themes/Simply Love` inside your ITGmania folder (for example `/Applications/ITGmania`) |
| Linux | `Themes/Simply Love` inside your ITGmania folder (for example `~/itgmania` or `/opt/itgmania`) |

Some setups keep themes in ITGmania's user data folder instead:

| OS | User data folder |
|---|---|
| Windows | `%APPDATA%\ITGmania` |
| macOS | `~/Library/Application Support/ITGmania` |
| Linux | `~/.itgmania` |

Use whichever `Themes/Simply Love` actually exists on your system.

## 2a. Install on Windows (script)

Open PowerShell in the folder you downloaded and run the installer. Pass your ITGmania folder, the one that **contains** `Themes`:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -ITGmania "C:\Games\ITGmania"
```

If your Simply Love folder has a different name, add `-Theme "Simply Love (something)"`.

The script:
1. Copies the files from `mod\` into the Simply Love folder.
2. Saves `metrics.ini.footguide-backup` and `Languages\en.ini.footguide-backup`. It only does this the first time, so the backups are your untouched originals.
3. Applies the edits from step 2b below. It's safe to re-run, including over an older FootGuide version.

Then restart ITGmania.

## 2b. Install by hand (any OS)

Close ITGmania first. Use a plain-text editor, such as Notepad, TextEdit in plain-text mode, VS Code or nano. Make a copy of `metrics.ini` and `Languages/en.ini` first if you want backups.

### Copy the files

Copy everything inside this repository's `mod` folder into your Simply Love folder, merging with the folders already there. You should end up with:

```
Simply Love/
├── Modules/
│   ├── FootGuide.lua
│   └── FootGuide/
│       ├── Solver.lua
│       └── Trainer.lua
└── Scripts/
    └── FootGuide-Settings.lua
```

### Edit `metrics.ini` (three edits)

**Edit 1: add the row to Player Options.** In the `[ScreenPlayerOptions]` section, find the `LineNames=` list. It contains this text:

```
MusicRate,Stepchart,ScreenAfterPlayerOptions
```

Add `FootGuide` so it reads:

```
MusicRate,Stepchart,FootGuide,ScreenAfterPlayerOptions
```

**Edit 2: define the row.** A little further down in the same section, find this line:

```ini
LineStepchart="lua,CustomOptionRow('Stepchart')"
```

Add this new line directly below it:

```ini
LineFootGuide="lua,FootGuideSettings.OptionRow()"
```

**Edit 3: add the trainer screen.** Add this section at the end of the file, or anywhere between two other sections:

```ini
# --- FootGuide trainer (added by FootGuide install.ps1) ---
[ScreenFootGuideTrainer]
Fallback="ScreenWithMenuElements"
PrevScreen=SelectMusicOrCourse()
NextScreen=SelectMusicOrCourse()
HeaderOnCommand=visible,false
FooterOnCommand=visible,false
ShowCreditDisplay=false
TimerSeconds=-1
# --- end FootGuide trainer ---
```

### Edit `Languages/en.ini` (two lines)

These are the row's name and the help text shown at the bottom of Player Options.

Under the `[OptionTitles]` section, add (for example right after `Stepchart=Stepchart`):

```ini
FootGuide=Foot Guide
```

Under the `[OptionExplanations]` section, add (for example right after the `Stepchart=` line):

```ini
FootGuide=On Notes: L/R on every arrow. Tricky Only: just around crossovers, footswitches and brackets. Side Panel: pad diagram beside the notes. Trainer: practice step by step instead of playing.
```

If you play ITGmania in another language and the row shows up without its name or help text, add the same two lines to that language's file too (for example `Languages/de.ini`), translated if you like.

Start ITGmania.

## 3. Check that it worked

1. Pick a song and press **Start** again to open **Player Options**.
2. On the first page, below **Music Rate** and **Stepchart**, there should be a **Foot Guide** row with **Off / On Notes / Tricky Only / Side Panel / Trainer**.
3. Choose **On Notes** and play. L/R badges should ride on your arrows.

## Updating

Download the new version, then do one of the following:

- **Windows:** run `install.ps1` again. It replaces FootGuide's files and refreshes its edits.
- **By hand:** copy the `mod` files over the old ones. Redo the text edits only if the release notes say they changed.

**After updating Simply Love itself** (for example with `git pull` or a new ITGmania release), the update may overwrite `metrics.ini` and `en.ini`, and the Foot Guide row will disappear. Re-run `install.ps1`, or redo the edits by hand.

## Uninstalling

**Windows:**

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -ITGmania "C:\Games\ITGmania"
```

This removes FootGuide's files and takes its edits back out of `metrics.ini` and `en.ini`, leaving them exactly as they were.

**By hand:**
1. Delete `Modules/FootGuide.lua`, `Modules/FootGuide/` and `Scripts/FootGuide-Settings.lua`.
2. Undo the edits above, or restore your backups of `metrics.ini` and `en.ini`.

Your saved settings live in `Save/FootGuide.txt` in ITGmania's data folder. Delete that file too if you want them gone.

## Troubleshooting

| Problem | What to check |
|---|---|
| No **Foot Guide** row in Player Options | The `metrics.ini` edits 1 and 2 are missing. This often happens after a Simply Love update; re-run the installer. The installer prints a warning if it couldn't find where to make an edit. |
| The row is there but says `FootGuide` with no help text | The `en.ini` lines are missing. |
| A Lua error mentioning FootGuide | Check that all four files from `mod` were copied, including `Scripts/FootGuide-Settings.lua`. The full error is in `Logs/log.txt` in ITGmania's data folder. |
| "Foot Guide: Not available with this turn mod" | Shuffle and the Left, Right and Backwards turns rearrange the chart unpredictably. Use no turn, or Mirror. |
| "Foot Guide: can't draw on this notefield ... using the side panel" | You're using a tilted perspective (Hallway, Distant and so on). Switch to Overhead to get badges on the notes. |
| Badges don't line up with the arrows | Please open an issue with your speed mod, Mini, perspective and a screenshot. |
| Choosing **Trainer** keeps sending me to the trainer | That's the setting: Trainer replaces playing until you change it. Set Foot Guide to another mode on Player Options to play normally. Trainer mode isn't saved when you close the game. |
| Chart says "Only dance singles/doubles are supported" | FootGuide works with dance single and dance double charts only. |
