# FootGuide

**Learn foot patterns in ITGmania.** FootGuide is a mod for the [Simply Love](https://github.com/itgmania/itgmania/tree/release/Themes/Simply%20Love) theme in [ITGmania](https://www.itgmania.com/). It works out the best way to foot every step of a chart (which foot hits which arrow) and shows it to you while you play, or walks you through the hard parts in a practice trainer.

## Why it helps

Reading arrows and hitting them on time is only half of dance games. The other half is **footing**: which foot takes each arrow. Bad footing is what turns a playable chart into a mess of doublesteps, spins and missed notes. Good players do it without thinking, but nobody tells you how. The game only knows *which arrow* you pressed, never *which foot* you used.

FootGuide fills that gap:

- **It finds the footing.** For any dance single or double chart, it searches every way of placing your feet and picks the one that flows best. It avoids doublesteps, keeps crossovers to where they're needed, and handles holds, jumps, brackets and footswitches. This is the same idea ITGmania uses internally to count crossovers and footswitches. FootGuide's results were tuned to agree with ITGmania's own counts on hundreds of charts.
- **It shows you while you play,** without cluttering the screen: a small **L** or **R** rides on each arrow in your own notefield. A "tricky only" mode marks just the hard spots.
- **It teaches the hard parts.** The trainer finds the trickiest sections of a chart. It animates each move on a big pad and explains footswitches, crossovers and brackets in plain words. Then it lets you drill them with the song playing and pausing whenever you haven't taken the next step yet.

## What you get

Pick a mode for each player on the **Player Options** screen (press Start again after choosing a song). The **Foot Guide** row is on the first page:

| Mode | What it does |
|---|---|
| **Off** | Nothing. This is the default. |
| **On Notes** | An **L** (blue) or **R** (orange) badge on every arrow in your notefield. Tricky steps get a yellow ring and a tag: `XO` crossover, `FS` footswitch, `BR` bracket, `SPIN`, and `DS` (unavoidable doublestep). |
| **Tricky Only** | The same badges, but only on tricky steps and the two steps leading into each. Use this once the basics are automatic. |
| **Side Panel** | A dance-pad diagram showing where your feet should be and how your body is turned, plus a scrolling L/R lane, beside the notefield. |
| **Trainer** | Practise instead of playing (see below). |

The badges follow your speed mod, Mini, Reverse, notefield offset and Hidden/Sudden. Each player's choice is remembered. With a keyboard, **Ctrl+F** turns the guide on and off for everyone.

### The trainer

1. **Pick a section.** The trainer lists the whole chart, then its trickiest 2-measure stretches, labelled with what's in them (for example "Measures 37-38: 3 crossovers, 1 footswitch").
2. **Practise with the music.** The song plays at your chosen Music Rate and the arrows scroll up to a line. If an arrow reaches the line before you've stepped, the music **pauses and waits** while the pad demonstrates the move. Keep up, and it never stops. To go slower, lower the Music Rate on Player Options.
3. **Watch, then step.** A large pad demonstrates each move:
   - **The moving foot** slides along a dotted path to where it lands.
   - **Footswitches:** the foot already on the panel visibly lifts off as the other one lands.
   - **Jumps:** both feet move together.
   - **Brackets:** the foot sits heel-and-toe across two panels.
   - **The body:** a see-through body, seen from above, turns along with the step: legs from the hips to each foot, plus shoulders and a head with a small arrow showing which way you face. When your legs cross, the leg that goes **in front** is drawn brighter and on top, so you can tell a front crossover from a behind one, and a crossover from a spin. The body never twists further than real hips can.

   Plain-language tips explain what's going on, for example:
   - *"Footswitch: lift your RIGHT foot off DOWN as your LEFT foot lands on it."*
   - *"Crossover: turn your hips about 75 degrees to your right and bring your LEFT leg across in front of your RIGHT leg."*

   Press the wrong panel and it buzzes and counts a mistake.
4. **Repeat until clean.** The trainer counts your clean runs in a row. **Back** returns to the section list, and from there to Player Options for the same song, where you can start the trainer again or switch Foot Guide to another mode and play the song.

A good learning routine:
1. Learn a section in the trainer at a **low Music Rate**, letting it pause as often as you need.
2. Raise the rate until you get it clean without pauses.
3. Play the song with **Tricky Only**, at a lower Music Rate if needed.

## Requirements

- **ITGmania** with the **Simply Love** theme. Tested on ITGmania 1.1.0 with Simply Love 5.7.0. Other recent versions should work.
- **Dance single or double charts** (`.sm` or `.ssc`).

## Installation

**Windows:** download this repository (green **Code** button, then **Download ZIP**, then extract), open PowerShell in the folder, and run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -ITGmania "C:\Games\ITGmania"
```

Use your own ITGmania folder: the one that contains `Themes`. Then restart ITGmania.

**macOS, Linux, or manual install:** copy the `mod` folder's contents into your Simply Love folder and make four small text edits. See **[INSTALL.md](INSTALL.md)** for step-by-step instructions, uninstalling, updating and troubleshooting.

## Limitations

- **It can't see your feet.** Dance pads only report which panel was pressed. FootGuide shows you good footing to follow, and the trainer checks that you press the right *panels*, but nothing can check which *foot* you used.
- **"Best" footing is a model.** Some patterns have more than one good answer, such as jumping vs bracketing an adjacent jump. FootGuide picks one consistent style, close to how ITGmania counts techniques.
- **Unsupported options:**
  - Shuffle and the Left, Right and Backwards turn mods (the remapped chart can't be predicted). Mirror is supported.
  - Simply Love's tilted 3D perspectives, where the badges can't follow the arrows. FootGuide switches to the side panel automatically in that case.
  - Courses, in the trainer.
- **Mines are ignored.**

## How it works

FootGuide reads the chart from its simfile and uses ITGmania's timing data, so BPM changes, stops, warps and fakes are handled. It then runs a dynamic-programming search over every possible foot position. Each step adds a cost for things that are awkward:

- doublesteps
- spins
- slow footswitches
- tapping with a foot that's holding
- crossovers
- fast footswitches
- jacks
- brackets
- distance travelled

The cheapest path through the whole chart is the suggestion. The search takes a fraction of a second and runs over a few frames during the screen's intro, and results are cached.

Across about 200 charts, FootGuide's totals compared with ITGmania's own technique counts:

| | FootGuide | ITGmania |
|---|---|---|
| crossovers | 1169 | 1155 |
| doublesteps | 45 | 149 |
| footswitches | 173 | 320 |
| brackets | 435 | 612 |

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the details, the code layout and how to run the tests.

## Credits

- Built on Simply Love's **Modules** system and ITGmania's Lua API.
- The footing search follows the same approach as ITGmania's built-in StepParity technique counter.
- FootGuide is an independent fan project. It isn't affiliated with or endorsed by the ITGmania or Simply Love developers.

## License

[MIT](LICENSE) © 2026 omeedthomas
