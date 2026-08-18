# V2 bass lanes — pre-registered experiment (2026-08-17)

Defined BEFORE implementation so the richer vocabulary is measured, not
admired. V2 expands the bass ring from 5 chord-relative lanes to the full
diatonic ladder:

    lane 0..6 = chord root + 0..6 SCALE STEPS (R 2 3 4 5 6 7, diatonic —
                the key's scale context decides major/minor color)
    lane 7    = O = chord root + 12 semitones

Corpus justification: 26% of 53k real jazz bass notes are exactly the
x2/x4/x6 color classes the V1 lanes cannot express.

## Held fixed (the clean-test contract)

Candidate generator logic (no 2/4/6-specific candidates — the new tones enter
only through the EXISTING retune/recolor tone pool), style profile, interaction
prior, intent policy, weights, session setup. The frozen RuleBassPolicy is
index-REMAPPED (same sounding behavior, POLICY_VERSION bump) so the baseline
is unchanged musically.

## Measured (tools/corpus/v2_metrics.py, from ordinary session logs)

1. **Selection rate** — fraction of placed notes on 2/4/6 lanes.
2. **Rhythmic placement** — beat/offbeat distribution of 2/4/6 vs stable tones
   (corpus expectation: color tones lean offbeat/passing).
3. **Harmonic context** — chord degrees active when 2/4/6 are placed.
4. **Style attribution** — fraction of 2/4/6 placements in style-flipped
   decisions, and the degree_fit sign on the winning candidate (the corpus
   x2/x4/x6 distributions are now live in the prior).
5. **Survival** — dwell (windows until edited away) of lines containing 2/4/6
   vs pure-V1 lines; REVERT rate before/after.

## Success criterion (pre-registered)

NOT "the bot uses 2/4/6 often." Success =
- selective use in contexts the corpus supports (offbeat-leaning, minority
  share comparable to the corpus's ~26%, not dominant),
- style prior demonstrably involved in their selection,
- **no increase in revert/edit-away rate** (color that survives),
- and the ear test: perceived color without perceived busyness.

Failure modes that would send us back: 2/4/6 dominating (typicality cap
mis-tuned), coloring on downbeats over stable chords (context-blind), or
raised correction rates (the jam rejecting the color).
