# Style-era design notes (3D/3E + renderer) — pinned before implementation

Decisions agreed 2026-08-17, recorded so the future implementation inherits
them. **None of this is built yet, deliberately**: the standing gate is the
3B-vs-baseline behavioral comparison from session logs. Style determines HOW
the bandmate acts only after causal signals prove they improve WHEN it acts.

## The pipeline each kind of knowledge belongs to

    3A  WHAT IS HAPPENING?            (JamAnalysis — built)
    3B  RESPOND / HOLD / VARY / ...?  (JamIntentPolicy — built, shadow-only)
    3C  WHAT ACTIONS SATISFY THAT INTENT?   (candidate generator)
    3D  HOW WOULD THIS STYLE REALIZE IT?    (style profiles)
    3E  WHICH CANDIDATE IS BEST?            (evaluator)
    Renderer  HOW SHOULD IT FEEL IN TIME?   (groove lens)

The Scaler / Grooves / corpus references belong to 3D/3E + renderer — never
to 3A/3B. Perception and intention stay style-free.

## Style knowledge has FOUR axes

    HARMONY (Scaler refs)   GROOVE (AGR + GMD)   CORPUS (MIDI datasets)
    what's available        how events sit        what musicians tend to do
                        INTERACTION (aligned multitracks + our session logs)
                        kick↔bass onsets, chordchange↔bass response,
                        fill↔phrase boundary, density coupling,
                        humanchange↔AI hold/respond

Our own decision logs are the best source for the last coupling; Slakh-class
aligned corpora for the first three.

## A genre is NOT one groove map

Never encode `TECHNO = Shake1`. The unit is **Style + Role + Context →
timing behavior**, and a style holds *distributions*, not presets:
groove-family distribution, amount distribution, role-specific behavior
(techno kick tight / hats maybe swung / bass tight-or-behind; jazz ride swing
≠ jazz bass feel ≠ comping placement), and variability. Otherwise every track
goes through the same "JAZZ HUMANIZE" knob — the Casio-preset effect.

## Reserved contract: JamStyleProfile

    JamStyleProfile
    ├── HarmonyProfile      scale/chord vocab, functional transitions,
    │                       extension tendencies, voice-leading preferences
    ├── BassProfile         degree tendencies, rhythmic vocab, repetition
    │                       tolerance, density, transition behavior
    ├── DrumProfile         kick/snare/hat relationships, fills, density,
    │                       groove-profile distribution
    ├── KeysProfile         voicing tendencies, rhythmic density,
    │                       inversion/motion, register behavior
    └── InteractionProfile  kick↔bass coupling, harmony↔bass response,
                            fill↔transition coupling, role-space behavior

NOT a hand-authored genre dictionary: the corpus converter estimates most
values empirically. Hand-authoring is limited to the schema.

## Groove lens (renderer): nominal shape + seeded variance

    scheduled offset = style groove offset(step)          [AGR-derived, deterministic]
                     + controlled performance deviation   [GMD-derived variance, SEEDED]

AGR/Stolperbeats data supplies the deterministic groove *shape* (four numbers:
down/e/and/a as fractions of a 16th). GMD supplies how consistently humans hit
that shape (variance). Any stochastic part must be seeded and deterministic —
derived like decision seeds from (session_seed, musical position) — so every
peer computes identical sample stamps.

### Measured humanization budgets (Scaler 3 performance library, 2026-08-17)

Hard numbers from 1,274 authored patterns / 37,790 events
(refs/ScalerReference/PERFORMANCE.md — study the model, never ship the
patterns):

- **Micro-timing cap: ±1/24 beat** (~21ms @120) — holds across every
  category; beyond it, feel reads as wrong notes.
- **Tightness is per-ROLE**: pulse layers 9-11% off-grid, decorative layers
  44-46%. Confirms the no-global-humanize-slider rule with data.
- **Rolled simultaneities**: ~40% of chord hits spread by ~8ms (max 0.06
  beat) — most of "sampled piano vs MIDI piano" for near-zero code. (Guitar
  strum is the same effect applied at runtime instead — two mechanisms, one
  percept.)
- **Velocity bands per role**: bass loud/narrow (100±17), lead loud/wide
  (98±24), comping quiet/wide (75±22) — respecting bands yields mix balance
  for free.
- **Swing is authored per-pattern, not a knob**: "Jazz Swing Feel" = 0.539 —
  CONVERGES with our GMD measurement (+8.2% of a 16th ≈ 0.52-0.54). Light
  jazz swing ≈ 0.54, not 0.667; "Uptempo Swing" mixes straight and swung
  notes inside single patterns.
- **Index-based patterns validated at scale**: noteIndex-into-chord-ladder on
  all 37,790 events (never pitches) — our chord-relative lanes are the same
  model; the keys role later needs the generalized ladder builder + voicing
  profiles (Scaler's cheapest variety lever, with Rotate second).

### Pinned technical constraints for the future lens

1. **`max_negative_groove_offset`** must be an explicit part of the lens
   contract, and scheduling lookahead must be at least that large. The Trip
   family contains NEGATIVE (rushed) offsets: a note nominally at bar 4 step 0
   must sound BEFORE the nominal boundary. Without this pin, positive swing
   works perfectly while rushed grooves silently submit late — the timing
   math being correct doesn't save you.
2. **Determinism invariant**: same pattern + same groove profile/version +
   same seed → identical sample stamps on every peer, *including events that
   cross bar/loop boundaries*. The future-buffered scheduler makes this easy
   to solve correctly — solve it there, not with per-peer randomness.

## Profile contract decisions (adopted 2026-08-17, implemented in tools/corpus)

- **Partial, role-specific profiles with provenance**: a style gets a role
  section only when a corpus supplied one — `{profile, source, n, confidence}`
  per role, absent otherwise. Never invent "roughly opposite numbers and call
  it techno" (the Casio-preset failure mode re-entering through data's back
  door).
- **Distributions, not means**: per-step onset histograms, timing-offset
  histograms per beat position (with n), tone-given-beat splits, interval and
  transition distributions. Two genres can share a mean and differ entirely
  in vocabulary. Profiles say "this is what we measured", never "this is what
  jazz is" — the swing-sign finding stays a measurement, not a rule.
- **Profiles are scoring PRIORS for the 3C candidate evaluator** (style
  likelihood alongside the interaction score), never note generators.
- **The separability gate** (passed 2026-08-17 before any gameplay use):
  held-out label-free GMD classification by nearest-profile likelihood — 51%
  over 7 styles vs 14% chance; funk 82 / latin 83 / hiphop 88; rock scatters
  (generic vocabulary), pop↔soul overlap. The Jammin representation preserves
  stylistic identity for vocabulary-distinct styles.
- **V2 bass lanes (2/4/6) have empirical justification**: 26% of real jazz
  bass notes are exactly the x2/x4/x6 color classes. After V2, STOP
  auto-expanding — remaining OOV notes have semantics (chromatic approach,
  enclosure, altered tones, passing, pedal) to analyze separately, not twelve
  pitch classes to add.

## Reference-ingestion freeze

Enough vocabulary exists (harmony banks, groove captures, corpora). No more
collection until the 3B gate is passed; then the first style artifact is the
`midi → JamminCorpusExample` converter into the one common representation
(chord-relative bass vs known chords, our feature/interpretation vocabulary).
