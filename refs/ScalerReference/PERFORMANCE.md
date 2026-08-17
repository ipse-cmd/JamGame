# Performance, humanization & motion — how Scaler 3 plays a chord progression

Companion to [FINDINGS.md](FINDINGS.md) (harmony) and [DESIGN.md](DESIGN.md) (game design).
`FINDINGS.md` covers *what notes* a chord contains. This covers *how they get played*:
rhythm, voicing motion, arpeggiation, strumming, dynamics and micro-timing.

> **Where this came from.** The chord/scale banks were loose JSON blobs in the binary
> around the 36 MB mark. The performance library is *not* there — it's a complete ZIP
> archive appended into the binary's data section at offset `35,543,888`, holding
> **1274 pattern JSON files** under `ExpressionsData/`. That's why the first pass missed it.
> `tools/extract_expressions.py` carves it out and normalizes it.

---

## ⚖️ Fair-use line — stricter here than for chords

Chord and scale formulas are facts; you can reimplement them freely. **These patterns are not.**
Each one is an authored piece of MIDI performance — someone's playing, quantized and edited.

- **Do** study the *model* (index-based patterns, the transform stack, the micro-timing budget).
  The architecture is the valuable part, and it is not protectable.
- **Do** use the banks as a dev reference and to test your own engine.
- **Don't** ship `expressions.json` — or patterns derived by lightly editing it — in a released game.
  Author your own patterns against the same schema. The schema is yours to use; the content isn't.

---

## 1. The core idea: patterns are chord-relative, not pitch-based

This is the single most important thing to steal.

A performance pattern **never stores pitches as musical content**. It stores an *index* into
the chord's note ladder. Every one of the 37,790 events in the library satisfies:

```
event.noteNumber == metaData.allNotesNumber[event.noteIndex]     # 37790 / 37790
```

So `noteNumber` is pure redundancy — a snapshot of what the pattern sounded like on the
chord it was authored against. **`noteIndex` is the actual content.** That's what makes one
pattern work on every chord in every progression: you swap the ladder, the pattern is unchanged.

```
noteIndex:   0    1    2    3    4    5    6   ...
Cmaj7  ->   C3   E3   G3   B3   C4   E4   G4  ...
Fmin9  ->   F3   Ab3  C4   Eb4  G4   F4  Ab4  ...   <- same pattern, new chord, no edits
```

`noteIndex` runs **0..29** in the shipped library. The ladder is longer than the chord: it's the
chord tones stacked upward across octaves (and extensions), so index 7 on a 4-note chord means
"second octave, 4th voice". Your engine needs a **ladder builder** — a function from
`(chord, voicingProfile, range) -> [pitch]` — and every pattern plays through it.

Scaler exposes that ladder builder as the **Voicing Profile** (see `banks/transforms.json`):
`Open Voicing`, `Drop 2/3/4`, `Guitar Voicing`, `Grouping C2-B3`, `Avoid Lows`, `Dynamic +1 Oct`, …
Same pattern + different profile = same rhythm and contour, completely different texture.
**This is the cheapest source of variety in the entire system.**

### Schema (`banks/expressions.json`)

```jsonc
{
  "name": "Dynamic Performance 7",
  "id": "Dynamic-Performance-7",
  "folder": "Performances", "subfolder": "Dynamic",
  "timeSignature": [4, 4],
  "lengthBeats": 16.0, "bars": 4.0,
  "poolSize": 5,                  // ladder length this was authored against
  "refPitches": [48,60,63,67,72], // that ladder, informational only
  "maxNoteIndex": 4,
  "events": [ [positionBeats, noteIndex, velocity, durationBeats], ... ]
}
```

Positions and durations are normalized to **beats** (the source files mix `ticksPerBeat` 480 and 96 —
don't inherit that). Events are sorted by position. `banks/expressions.csv` is the same set as one
row per pattern for browsing/filtering.

---

## 2. What's in the library

| Folder | Patterns | Sub-cats | Avg bars | Avg notes | Notes/bar | Max index | Off-grid | Vel sd |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| Performances | 233 | 13 | 2.4 | 30 | 14.4 | 13 | 45% | 13.1 |
| Phrases | 282 | 12 | 3.9 | 40 | 11.9 | 29 | 46% | 12.7 |
| Melody | 299 | 60 | 4.5 | 22 | 6.6 | 15 | 11% | 9.1 |
| Bass | 234 | 15 | 3.5 | 23 | 7.0 | 11 | 19% | 4.8 |
| Rhythms | 102 | 7 | 2.1 | 57 | 25.2 | 5 | 10% | 10.9 |
| Sequences | 70 | 3 | 1.4 | 14 | 9.4 | 6 | 16% | 6.4 |
| StrummedSequences | 30 | 2 | 2.5 | 12 | 5.7 | 2 | 54% | 8.3 |
| Passages | 24 | 1 | 1.8 | 9 | 4.9 | 7 | 7% | 8.4 |

**1274 patterns, 37,790 events.** Time signatures: 4/4 (1180), 5/4 (29), 12/8 (20), 6/8 (16),
3/4 (11), 7/4 (10), 9/4 (8).

The **`maxNoteIndex` column is the type signature of each category.** Rhythms cap at 5 —
they're rhythmic cells that hit whatever's under them. Phrases reach 29 — they range across
four octaves of the ladder and behave like written parts. That single number tells you what a
category *is* far better than its name does.

Naming is Italian tempo/expression marks (`Adagio`, `Vivace`, `Espressivo`, `Con Fuoco`,
`Con Moto`, `Volante`, `Presto`) — a taxonomy by **feel**, not by genre or BPM. Worth copying:
it's a vocabulary a player can pick from without knowing theory.

Melody has 60 sub-categories in a deliberate grid — `Motif A..J`, `Theme A..J`, `Riff A..S`,
`Common A..J`, `Color A..J`, each holding exactly 5 variants. That's a **combinatorial bank**,
not a curated list: pick a letter for identity, pick a variant for the repeat. Ideal for a game
that needs "the same idea again, but different".

---

## 3. Humanization: measured, not guessed

The shipped patterns carry `position_offset` and `duration_offset` fields — and they are
**zero on all 37,790 events**. Those are runtime scratch fields for the Humanize transform.
The human feel that ships in the library is baked directly into `position` and `velocity`.

### 3a. Micro-timing budget

Classify every onset against the nearest musical grid (1/4, 1/8, 1/8T, 1/16, 1/16T, 1/32, 1/32T).
What's left over is deliberate push/pull:

| Folder | Off-grid | Mean nudge | p95 | Max | Early (rushed) |
|---|--:|--:|--:|--:|--:|
| Phrases | 40% | 0.018 beat (9.1 ms) | 0.042 | 0.042 | 54% |
| Performances | 44% | 0.016 beat (7.8 ms) | 0.038 | 0.042 | 46% |
| Bass | 20% | 0.015 beat (7.6 ms) | 0.040 | 0.042 | 38% |
| StrummedSequences | 48% | 0.007 beat (3.7 ms) | 0.025 | 0.035 | 21% |
| Melody | 11% | 0.009 beat (4.7 ms) | 0.031 | 0.042 | 25% |
| Rhythms | 9% | 0.004 beat (2.2 ms) | 0.031 | 0.031 | 30% |

*(ms figures at 120 BPM.)*

Two hard numbers to lift straight into your engine:

1. **The nudge is capped at exactly ±1/24 beat** (0.0417 beat, ~20.8 ms at 120 BPM) —
   that ceiling holds across every folder, so it's a deliberate authoring constraint, not noise.
   Half a 32nd-triplet. Beyond that it stops reading as feel and starts reading as a wrong note.
2. **Early/late is near 50/50 in the expressive categories** and skews *late* in the tight ones
   (Melody 25% early, StrummedSequences 21% early). Rushing is expressive; dragging is groove.

Note the split by role: **Rhythms and Melody are tight (9–11% off-grid), Performances and Phrases
are loose (44–46%)**. The parts that define the pulse stay locked; the parts that decorate float.
Applying one global humanize amount to every layer — the obvious first implementation — is
precisely what makes generated music sound synthetic.

### 3b. Rolled chords

Notes that nominally land together don't. Clustering onsets within a 1/16-beat window:
**509 of 1331 Performance clusters (38%) are spread rather than simultaneous**, mean spread
0.016 beat (~8 ms), max 0.060 beat. Phrases: 1026 of 2507 (41%), mean 0.021 beat.

So roughly 4 in 10 "chord hits" are actually rolled by a few milliseconds. Cheap to implement,
and it's most of the difference between "sampled piano" and "MIDI piano".

*(`StrummedSequences` show **zero** internal spread — their strum is applied at runtime by the
Strumming transform, so the pattern stays a clean grid. Two different mechanisms for the same
perceptual effect: baked roll for keys, runtime strum for guitar.)*

### 3c. Velocity

Velocity is the dynamics layer and it's category-typed:

| | mean | sd | range |
|---|--:|--:|---|
| Bass | 100.0 | 16.8 | 18–127 |
| Melody | 98.3 | 24.0 | 32–127 |
| StrummedSequences | 89.5 | 20.0 | 38–127 |
| Rhythms | 82.8 | 25.1 | 16–127 |
| Sequences | 81.7 | 21.9 | 1–127 |
| Passages | 76.6 | 15.7 | 32–116 |
| Performances | 75.0 | 21.9 | 1–127 |
| Phrases | 72.2 | 21.7 | 1–127 |

**Lead layers sit loud and narrow; accompaniment sits quiet and wide.** Bass mean 100 / sd 17
vs Performances mean 75 / sd 22. That's an automatic mix — the arrangement balances itself
because each role was authored into its own velocity band. If your game layers a bass pattern
under a performance pattern, you get a usable balance for free by respecting these bands.

### 3d. Swing is authored per-category, not a global knob

Where do off-beat eighths actually sit? (0.5 = straight, 0.667 = triplet swing)

| Sub-category | straight 8ths | swung 2:1 | median |
|---|--:|--:|--:|
| Triplet Feel | 0% | **100%** | 0.667 |
| Uptempo Swing | 22% | 28% | 0.652 |
| Jazz Swing Feel | 37% | 1% | **0.539** |
| Vivace | 49% | 2% | 0.627 |
| Moderato | 61% | 10% | 0.502 |
| Common Performances | 76% | 4% | 0.500 |
| Jazz Soft | 80% | 0% | 0.502 |

`Triplet Feel` is exactly 2:1 — mechanical, the equivalent of a swing slider at 100%.
But **`Jazz Swing Feel` sits at 0.539** — a light swing that no quantized swing setting produces,
and `Uptempo Swing` is a *mixture* of straight and swung notes inside single patterns.
They authored the ratio per pattern instead of exposing one global percentage. If you want jazz
that doesn't sound like a drum machine, that's the reason.

---

## 4. The transform stack

Baked patterns are only half the system. At playback a chain of transforms runs on top
(full parameter vocabulary in `banks/transforms.json`, recovered from the binary's string tables):

```
Articulations -> Motions -> Expressions -> Arpeggio -> Passages -> Strumming -> Bass Follow -> Divisi
```

Worth knowing:

- **Arpeggio** — 16 patterns beyond the obvious Up/Down: `Converge`, `Diverge`, `Converge/Diverge`,
  `Doubled Up`, `Thumb Up`, `Thumb Up/Down`, `Pinky Up`, `Spanish Tremolo`. The Thumb/Pinky ones
  pin the lowest/highest voice as a pedal while the rest cycle — that's a guitar/harp idiom and it
  sounds far better than plain Up/Down for very little code. Rates run 1/1 to 1/32 with dotted
  (`d`) and triplet (`t`) variants; note length is `Quarter`/`Half`/`Full` of the step.
- **Humanize** — runtime layer with `humanize_type` (`Swing`/`Quantize`/`Both`),
  `humanize_amount` (depth) and `humanize_timing` (`x0.5`/`x0.75`/`x1.5` rate multiplier).
  This is *on top of* the baked feel in §3, not a replacement for it.
- **Keys Lock** — `Scale Notes Mapped`, `Scale Notes Only`, `Scale White Keys`, `Chord Notes`,
  `Chord Extensions`, `Chord Scales`. This is the "you can't play a wrong note" mechanic, and the
  six modes are a difficulty ladder ready-made for a game: `Scale White Keys` for a beginner,
  `Chord Extensions` for an expert.
- **Rotate** — `rotate_resolution` (1 bar … 1/16 bar) + `rotate_increment` cycles a pattern's
  start point each repeat. One pattern, N variations, zero extra content. Very high value per line
  of code for a game that needs to stay fresh over a long session.

---

## 5. Implementation notes for the game

A minimal engine that reproduces most of the perceived quality:

```
render(pattern, chord, profile, bpm):
    ladder = buildLadder(chord, profile, range)      # §1 — the one piece you must build
    for [pos, idx, vel, dur] in pattern.events:
        pitch = ladder[min(idx, len(ladder)-1)]      # clamp, or wrap+octave
        emit(note = pitch,
             time = pos + nudge(),                   # §3a, cap |nudge| at 1/24 beat
             vel  = clamp(vel * roleGain, 1, 127),   # §3c bands
             dur  = dur)
```

Priority order, by audible payoff per unit of work:

1. **Index-based patterns + a ladder builder** (§1). Without this nothing else matters; with it,
   every pattern works on every chord.
2. **Velocity bands per role** (§3c). Free mix balance.
3. **Micro-timing within ±1/24 beat, tight on pulse layers, loose on decoration** (§3a).
4. **Rolled chords on ~40% of simultaneities** (§3b).
5. **Voicing profiles** (§1) — biggest variety-per-line-of-code in the system.
6. **Rotate** (§4) — second biggest.
7. Arpeggio patterns, Keys Lock difficulty modes.

Two design traps this data exposes:

- **Don't ship one global "humanize" slider.** Feel is per-role and partly per-pattern. One
  slider over everything is the sound of generated music.
- **Don't store pitches in patterns.** The moment a pattern knows a pitch it's welded to one chord.

## Files

| File | What |
|---|---|
| `banks/expressions.json` | 1274 normalized patterns, 37,790 events, beat-relative |
| `banks/expressions.csv` | one row per pattern — folder, bars, density, velocity, off-grid % |
| `banks/transforms.json` | runtime transform vocabulary (arp, humanize, voicing, keys lock) |
| `tools/extract_expressions.py` | carves the embedded ZIP out of the binary and rebuilds both banks |
