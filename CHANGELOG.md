# Changelog

## 1.0.1

- **Trainer:** Back on the section list now returns to **Player Options** for the same song instead of song select. From there, Start goes back into the trainer, or you can change Foot Guide to another mode and play the song.
- **Updating from 1.0.0:** re-run `install.ps1`. If you installed by hand, change the two `PrevScreen` / `NextScreen` lines in the `[ScreenFootGuideTrainer]` section of `metrics.ini` to `"ScreenPlayerOptions"` (see INSTALL.md).

## 1.0.0

First public release.

- **Footing solver:** a dynamic-programming search over foot positions for dance single and double. It handles holds, jumps, brackets, footswitches, crossovers and spins, and it's tuned against ITGmania's own technique counts.
- **Foot Guide row** on Player Options, chosen per player and saved:
  - **On Notes:** L/R badges on every arrow in the real notefield. They follow speed mods, Mini, Reverse, notefield offset and Hidden/Sudden.
  - **Tricky Only:** badges only around crossovers, footswitches, brackets, spins and doublesteps.
  - **Side Panel:** a pad diagram and a scrolling L/R lane beside the notefield.
  - **Trainer:** a practice screen instead of the song.
- **Trainer:**
  - Sections are picked automatically from the chart's trickiest measures.
  - Each move is demonstrated with animation (moving foot, dotted path, footswitch hand-off) and explained in plain words.
  - **Step by step** mode waits for each correct press.
  - **With music** mode plays the song and pauses only when you're late.
  - Counts mistakes and clean runs in a row.
- **Ctrl+F** keyboard toggle.
- **Windows installer and uninstaller,** plus manual install steps for any OS.
