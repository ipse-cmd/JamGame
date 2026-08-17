# refs/ — external reference data for the style & harmony eras

Dev reference material, **not game code**. Two collections so far, covering two
of the three axes the style work needs (the third — corpus scale — is the
dataset downloads in ModelData/JamminCorpus):

| Collection | Axis | Source |
|---|---|---|
| `ScalerReference/` | **Harmony & vocabulary** | extracted from the Scaler 3 plugin binary |
| `Grooves/` + `agr_decode.py` | **Groove / microtiming** | Stolperbeats presets captured as Ableton `.agr` groove files |

Both are reference/seed banks: music-theory facts and timing measurements are
reimplementable; curated content (Scaler's library entries, Stolperbeats'
preset pack as such) should inspire our own, not ship verbatim.

---

## ScalerReference — theory banks (see its own README/FINDINGS/DESIGN)

Nine JSON blobs carved out of the Scaler 3 binary (NUL-terminated UTF-8 JSON,
duplicated at two byte offsets; first copy used). Highlights:

- **`banks/chords.json`** — 255 chord types as semitone-offset sets from the
  root (`maj7 = [0,4,7,11]`), with formula/symbol/isMinor. Extensions kept
  above the octave (9→14, 11→17, 13→21) so voicings spread correctly —
  matching JamGame's diatonic-third stacking convention.
- **`banks/scales.json`** — 77 scales as **modes of 15 parent scales**
  (parent + degree), each with curated **mood tags** (56 distinct words).
- **`banks/mood_to_scales.json`** — reverse index: mood → scales.
- **`banks/taxonomy.json`** — Scaler's tag vocabulary: 45 genres, 12
  functions, 50 feel tags, 12 set types.
- **`banks/library_tags.json`** — 1887 library entries, **tags only** (the
  actual phrase/performance MIDI ships in external packs — NOT extracted, so
  there is **no humanization data** here; Grooves + GMD cover that instead).
- Guitar layer (63 voicings, 34 tunings) + voicing templates + note names.
- **`DESIGN.md`** — the reimplementable logic: diatonic chord generation,
  T/S/D functional grammar, a tunable 7×7 **transition weight matrix**
  (V→I strongest, D↛S avoided), **voice-leading distance**, and a ranked
  suggestion algorithm.

### Where it plugs into the roadmap
1. `scales.json` → the G3 harmony expansion (`JamHarmony` beyond C major;
   `chord_tone_midi` generalizes over parent/degree modes).
2. Transition matrix + voice-leading distance → the **3C/3E candidate
   evaluator** (transitional harmonic scoring, smoothness).
3. Moods/taxonomy → the **3D style contract**'s data-backed vocabulary.
4. `chords.json` → chord-picker V2 flavors (radial second ring), server
   validation still the boundary.

---

## Grooves — Stolperbeats microtiming captures

25 presets (`Base`, `Push1–6`, `Shake1–6`, `Clave1–6`, `Trip1–6`) captured as
Ableton `.agr` groove files; `agr_decode.py` (gzip → XML → clustered hits)
emits per-hit JSON: step, position-in-beat, deviation in beats / ticks
(960 PPQN; a 16th = 240 ticks) / ms@120 / **% of a 16th**, velocity, stack.
`SWING_SUMMARY.txt` condenses each preset to median offsets for the four
beat positions (down / e / and / a).

The families form a compact groove taxonomy:

| Family | Shape |
|---|---|
| Base | straight (control) |
| Push 1–6 | uniform lay-back: ALL offbeat 16ths equally late (+26…+59 ticks) |
| Shake 1–6 | classic MPC 16th swing: only e + a late, the "and" straight |
| Clave 1–6 | asymmetric maps, downbeat itself shifts |
| Trip 1–6 | progressive triplet-ward warps, some rushed (negative) |

### Where it plugs into the roadmap
A groove profile here is just **four numbers** (down/e/and/a offsets as
fractions of a 16th) — exactly the shape of a future **deterministic
render-side groove lens**: every peer applies the same pure function of step
position to its scheduled `at_sample`, preserving the
peers-derive-identical-audio invariant with zero wire/op changes (same
pattern as the DrumRenderer modifier lenses). Style-era feature (3D+):
techno ≈ Base/light-Shake tightness, jazz ≈ heavier swing + GMD's measured
human looseness. Not built until the intent layer proves itself (the standing
gate: 3B vs baseline on session logs).
