# FINDINGS — what's inside Scaler 3, the theory behind it, and how it maps to our files

The single source-of-truth doc. Three layers:
1. **Extraction findings** — what was actually found in the app and how.
2. **The theory** — the chord/scale logic those findings encode.
3. **File map** — exactly which file holds what, and how they join together.

See `DESIGN.md` for *how to build a game on top of this*; this doc is *what we have and why*.

---

## Part 1 — Extraction findings

### Where the data lives
Scaler 3 ships its theory database as **plain JSON embedded inside the app binary**:

```
Scaler 3.app/Contents/MacOS/Scaler 3      (~98 MB Mach-O executable)
```

It is **not** in `Resources/` and **not** in `~/Library/Application Support/`
(that folder only held a leftover Scaler **2** license + settings). The JSON blobs sit in
the binary as **NUL-terminated (`\x00`) UTF-8 strings**, which is what made clean carving possible.

### How it was extracted
- `tools/extract.py` — reads the binary, splits the data region on `\x00`, and keeps every
  chunk that parses as JSON. Classifies each blob by its key signature.
- `tools/normalize.py` — converts interval strings (`"1","b3","5"`) into **semitone offsets**
  (`[0,3,7]`) using a degree→semitone table, and flattens mood/style strings into arrays.

### What was found (9 JSON blobs)
Everything appears **twice** in the binary (two identical copies, at byte offsets ~37 M and
~87 M). We used the first copy. Blobs recovered:

| Blob | Count | Became |
|---|---|---|
| Chord types | **255** | `banks/chords.json` |
| Scales | **77** | `banks/scales.json` |
| Genre/tuning presets | 34 | `banks/guitar_tunings.json` |
| Guitar voicings | 63 | `banks/guitar_voicings.json` |
| Voicing templates | — | `banks/voicing_templates.json` |
| Notes (pitch classes) | 12 | `banks/notes.json` |
| Library entries | **1887** | `banks/library_tags.json` |
| Audio-sample metadata | 50 | *(dropped — just filenames)* |

### Key finding about the 1887-entry library
It contains **only metadata/tags** — `Type, Name, Genre, Feel/Mood, Function, Complexity,
Key Feel, Tempo`. The **actual chord/MIDI content is NOT in the binary**; it ships in
separate pack files. So the "library" is curation, not theory. Treat it as inspiration for
your own taxonomy, not as data to copy. (Distinct values are summarized in `banks/taxonomy.json`:
45 genres, 12 functions, 50 feel tags, 12 set-types.)

---

## Part 2 — The theory (what the numbers mean)

### Pitch classes (notes)
12 semitones, `C=0 … B=11`. Everything else is built from offsets against a root.
`banks/notes.json` carries names + enharmonic spellings (`flatName`/`sharpName`).

### Chords — `banks/chords.json` (255)
A chord = a set of **semitone offsets from its root**. Stored both as the original
interval `formula` and as normalized `semitones`.

```json
"maj7": { "formula": ["1","3","5","7"], "semitones": [0,4,7,11],
          "symbol": "M7", "isMinor": false, "uuid": "..." }
```

Conversion table used (major-scale reference + accidentals `b`=−1, `#`=+1):
`1→0 2→2 3→4 4→5 5→7 6→9 7→11`, extensions `9→14 11→17 13→21`.
Validated: `maj [0,4,7]`, `min [0,3,7]`, `7 [0,4,7,10]`, `min7 [0,3,7,10]`, `9 [0,4,7,10,14]`.

**Breakdown of the 255:**
- By note count: 3 dyads, 16 triads, 42 sevenths, 60 with 5 notes, 54 with 6, 79 with 7, 1 with 8.
- `isMinor` flag: 173 non-minor / 82 minor (useful as a quick bright/dark proxy).
- Extensions (9/11/13) are kept **above the octave** (14/17/21) so voicing spreads correctly.

### Scales — `banks/scales.json` (77)
A scale = semitone offsets within one octave, plus **mode relationships** and **mood tags**.

```json
"Phrygian Dominant scale": {
  "semitones": [0,1,4,5,7,8,10], "formula": ["1","b2","3","4","5","b6","b7"],
  "parent": "HARMONIC MINOR", "degree": 5,        // = the 5th mode of harmonic minor
  "moods": ["World Music","Gypsy","Flamenco"],
  "altNames": ["Spanish Gypsy","Freygish"], "display": "Phrygian Dominant" }
```

- The 77 scales are organized as **modes of 15 parent scales** (MAJOR, MELODIC MINOR,
  HARMONIC MINOR/MAJOR, NEAPOLITAN, PERSIAN, HIRAJOSHI, KUMOI, pentatonic/hexatonic families…).
  `parent` + `degree` tell you each scale is "the *degree*-th mode of *parent*".
- Sizes: 12 pentatonic (5), 7 hexatonic (6), 58 heptatonic (7).
- `moods` is Scaler's curated emotional tagging — 56 distinct mood words. This is the
  bridge from theory → game feel.

### Mood mapping — `banks/mood_to_scales.json`
Reverse index built from the scale tags: **mood → scales that evoke it**. Top moods by
coverage: *World Music (32), Complex (13), Positive (12), Unstable (10), Mysterious (10),
Folk, Middle Eastern, Japanese, Latin, Arabic, Sad…* This is your ready-made bank of
puzzle targets ("make something *Mysterious*").

### Guitar layer (optional) — `banks/guitar_voicings.json` + `guitar_tunings.json`
- Voicings = physical shapes: `frets[]`, `fingers[]`, `barres[]`, `tonicString` per position.
- Tunings = `openStringMIDIPitchs` (e.g. standard = `[40,45,50,55,59,64]`).
- Only relevant if your game shows a fretboard.

---

## Part 3 — File map & how things join

```
ScalerReference/
├── README.md              index + IP boundaries + data conventions
├── DESIGN.md              how to BUILD the game (algorithm, puzzle mechanics)
├── FINDINGS.md            THIS FILE — what we have & why
├── banks/
│   ├── chords.json/.csv        255 chords  [name, uuid, semitones, formula, symbol, isMinor]
│   ├── scales.json/.csv        77 scales   [semitones, parent, degree, moods, altNames]
│   ├── mood_to_scales.json     56 moods → scale lists
│   ├── taxonomy.json           Scaler's genre/function/feel vocab (inspiration only)
│   ├── guitar_voicings.json    63 fret shapes  [suffix_uuid → chords.uuid]
│   ├── guitar_tunings.json     34 tunings
│   ├── voicing_templates.json  octave-spread interval templates
│   ├── notes.json              12 pitch classes + enharmonic names
│   └── library_tags.json       1887 tag-only entries  (⚠ curation, not theory)
└── tools/
    ├── extract.py              carve JSON blobs out of the binary
    └── normalize.py            interval strings → semitone offsets
```

### The joins (how files link)
- **chords ↔ voicings**: `guitar_voicings[].suffix_uuid` == `chords[].uuid`.
  e.g. uuid `0e11ef88-…` → chord `maj` → fret shape `[0,2,2,1,0,0]` (an open A-major shape).
- **scales → moods**: `scales[].moods[]` are the keys in `mood_to_scales.json` (reverse index).
- **scales → scales (modes)**: `scales[].parent` + `degree` group the 77 into 15 families;
  same-parent scales are rotations of one another.
- **chords ⇄ scales (derived, not stored)**: build diatonic chords by stacking thirds on a
  scale, then match the note-set back to `chords.json` by `semitones`. See `DESIGN.md` §3.
- **taxonomy / library_tags**: standalone reference for genre/mood vocabulary — *not* joined
  to the theory (their content lives in external packs we don't have).

### Quick "where do I look?" 
| I want… | File(s) |
|---|---|
| The chord vocabulary / pieces | `chords.json` |
| Which chords fit a key | derive from `scales.json` (DESIGN §3) |
| Playable keys + their feel | `scales.json`, `mood_to_scales.json` |
| Puzzle targets (moods) | `mood_to_scales.json` |
| Naming/spelling notes | `notes.json` |
| Fretboard shapes/tunings | `guitar_voicings.json`, `guitar_tunings.json` |
| Genre/feel tag ideas | `taxonomy.json` |
| The suggestion algorithm | `DESIGN.md` §4–5 |
| Re-extract from the app | `tools/` |
