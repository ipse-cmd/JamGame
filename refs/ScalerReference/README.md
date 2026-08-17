# Scaler Reference — data banks & design notes

Reference material extracted from **Scaler 3** to help plan and build your own
*chord-progression puzzle game*. This is a dev scratch/reference folder — not game code.

## ⚖️ What's fair to use

- **Music theory is not copyrightable.** Chord formulas, scale formulas, mode
  relationships, voice-leading, functional harmony — these are *facts*. Reimplement freely.
- **Use these files as reference / a seed bank** while you build your own engine.
- **Don't** copy Scaler's compiled code, ship their audio/packs, clone their UI/branding,
  or paste their curated *library* (`library_tags.json`) wholesale into a shipped product.
  Build your own taxonomy inspired by it instead.

## Banks (`./banks/`)

| File | What it is | Use in your game |
|---|---|---|
| `scales.json` / `.csv` | 77 scales: semitone sets, modes, parent, **mood tags** | Define playable keys; pick by target mood |
| `chords.json` / `.csv` | 255 chord types: semitone sets, symbols, isMinor | The chord vocabulary / "pieces" |
| `mood_to_scales.json` | reverse index: mood → scales that evoke it | Puzzle targets ("make it *Mysterious*") |
| `taxonomy.json` | distinct genres / functions / moods / complexity from Scaler's library | Inspiration for your own tag system |
| `guitar_voicings.json` | 63 chord shapes (frets/fingers), linked by `suffix_uuid` to chords | Only if you add a fretboard view |
| `guitar_tunings.json` | 34 tunings (open-string MIDI pitches) | Only if fretboard |
| `voicing_templates.json` | interval-offset voicing templates | How to spread chord notes across octaves |
| `notes.json` | 12 pitch classes + enharmonic names | Note naming / display |
| `library_tags.json` | 1887 library entries — **tags only, no chord content** | Reference for taxonomy only ⚠️ |

### Data conventions
- `semitones`: offsets from the root (0). Chords absolute, e.g. `maj = [0,4,7]`,
  `min7 = [0,3,7,10]`, `9 = [0,4,7,10,14]`. Extensions (9/11/13) kept above the octave.
- `scales` semitones are mod-12, e.g. `Major = [0,2,4,5,7,9,11]`.
- To voice a chord on root R: `pitch = R + offset` (then `% 12` for pitch class, or keep absolute for MIDI).

## Docs
- **`DESIGN.md`** — how a progression-builder works: diatonic chords, functional
  harmony, the suggestion algorithm, voice-leading, and puzzle-game design ideas.

## Reproduce
`tools/extract.py` carves the JSON blobs out of the app binary; `tools/normalize.py`
converts interval strings (`"b3"`) to semitone offsets. Both are macOS-friendly Python 3.
