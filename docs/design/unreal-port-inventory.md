# Unreal Jammin → Godot port inventory (surveyed 2026-08-17)

What the original at `/media/ipsedesktop/ShareDrive1/GameDev/UnrealProjects/Jammin`
contains that the Godot port does NOT yet have. ~14.5k lines of C++ (64 green
automation tests) + ~11k lines of design docs. Authoritative status doc there:
`plans/Jammin_Implementation_Status.md` (trust it over the older
Implementation_Summary). DaisySP voices: PORTED 2026-08-17.

## Top port candidates (by value ÷ effort)

1. **Groove/swing layer** — 6 presets (Base/Shake/Shake-heavy/Push/Trip/Clave)
   as per-step timing offsets + velocity multipliers, applied as a RENDER-TIME
   LENS (never rewrites the pattern) through a fractional-pulse offset in the
   scheduler; TimingAmount 0.7 / VelocityAmount 0.2 blend knobs; room-wide
   replicated; user-verified "audibly distinct, switchable live". Pure math,
   2 tests, and our AGR/GMD work is its data. `Source/Jammin/*/Groove/*`,
   design §21 of DrumRole plan. **This is our future groove lens, already
   designed and proven once.**
2. **Phrase structure + phrase-gated fills** — loop=4 bars, phrase=4 loops;
   fills only SOUND on the phrase's final bar, queued fills auto-stretch to
   the turnaround. ~150 lines; turns "loop repeats" into "the jam has arrival
   points". `Timeline/JamPhrase.*`, fills in `JamDrumRoleComponent.cpp`.
3. **Harmony engine** — `FJamHarmonyLibrary`: SuggestNext (functional weight −
   voice-leading cost), chord identification, SnapPitchToKey, ScorePlacement;
   player-facing function labels (HOME/MOVE/TENSION/COLOR/SPICE); **Vibe
   system** (DarkRitual/BrightPop/DreamFloat/SpanishFire → key+scale bundle,
   replicated, cycled with V, live-retunes the bass ring room-wide). 5+4
   tests. Overlaps our Scaler-derived plans — port the ideas, reuse our banks.
4. **Front-end menu + connection-failure surfacing** — HOST/JOIN/SOLO menu;
   NetworkFailure/TravelFailure hooked so a failed join returns to the menu
   WITH the error (engine otherwise swallows it silently). Also: room reset
   (R), text chat with /join, room mixer (6 channels, drummer-adjusted,
   server-owned — bass defaulted 0.5 "because it drowned the kick").
5. **Free-placement event timeline** (chords/lead lanes in the original) —
   `FJamLoopTimeline`: whole-bar lock horizon, TWO density budgets (absolute
   + loop-aware), policy-aware dedup (one-shot vs looping), deterministic
   event ids, erase-own-before-lock. 17 tests — the most battle-tested code
   there; its bug history (`plans/ReviewCode1-3.txt`) is a ready-made test
   list. Value: when we outgrow ring-only editing (lead/melody role).

## Smaller items worth carrying

- Drum extras: capped version history (MaxVersions 4 — undo-ready),
  identical-pending-commits-nothing rule, `bMutedByModifier` ghost states,
  hit fields reserved for Probability/MicroTiming.
- Server-time clock authority + cross-machine phase lock (client holds
  transport and starts ON the replicated downbeat; ~10-20ms LAN agreement).
  Check our join path against this. Known gap there: long-session sample-clock
  drift re-anchoring (never built).
- Three-layer input (device → MusicAction intent → request; raw input never
  mints an event) + keyboard/gamepad parity enforced BY A TEST that inspects
  both mapping contexts.
- Config wisdom: audio buffers 1→2 (single buffer starves weak machines and
  drags tempo; +21ms inaudible since everything schedules ahead), heavyweight
  render pipeline off.
- Scoring: thin built version (harmony fit + density); the DESIGN (§11) is
  the valuable part — per-role observable-behavior rubrics ("score observable
  musical behavior, never good music directly"); the bass rubric reads like
  our evaluator's future terms. `RiskValue` is client-supplied there with a
  TODO admitting it should be server-computed — don't repeat.
- Room seed = bare kick pulse (not a full backbeat) so the drummer must
  contribute. Deliberate.

## Explicitly deferred there (never built)

Spice chords, vibe progressions, arranger, round recap, tutorial, per-voice
groove amounts, bass octave control, ring-content scoring, drift re-anchoring,
Mac build. The two parallel music systems (rings vs free events) were kept
deliberately separate (their §12) — carry that decision.
