# JamGame — Validation Record

Following the Jammin rule: every slice ends with validation. Unreal Jammin
(`E:\GameDev\UnrealProjects\Jammin`) is the reference implementation.

## G0 — GDScript vertical slice (2026-08-16)

- **59 headless unit tests green**: `godot_console --headless --path . --script res://tests/core_tests.gd`
  covers pattern-editor invariants, the full commit-model lifecycle (N+1 scheduling,
  coalescing, identical-pending drop, cancel, history cap), bass place/retune/remove,
  chord cycling, harmony math.
- **Live commit proof** (via godot-mcp): injected keys `4 → → Enter` opened a pending
  edit scheduled for loop N+1; after the boundary, hits 12→13, version 0→1, pending
  cleared. Screenshot-verified layout.

## G2 — Native scheduled audio core (2026-08-16)

The gate: *can GDScript submit future musical events to a GDExtension, and does the
extension produce invariant sample-offset timing despite arbitrary game-thread hitches?*

**YES.** Setup: `JamAudioStream`/`JamAudioStreamPlayback` GDExtension (godot-cpp
4.5-stable, MSVC). SPSC trigger queue, absolute-sample event stamps, `_mix()` places
onsets at exact block offsets. Transport is a 150 ms lookahead scheduler.

1. **Adversarial click train (G2.6/G2.7)**: 64 clicks queued at exactly 6000-sample
   spacing, then the main thread stalled 5–25 ms *every frame* (`hitch_mode`, F9).
   Result read from the (intended, actual) diagnostics ring:
   `clicks_launched: 64, placement_errors: 0, onset_delta_histogram: {6000: 63},
   late: 0, dropped: 0`. Sample-exact under sustained hitching.
2. **Live lookahead path under hitch**: 10 s of continuous 5–25 ms main-thread stalls
   during normal playback — 175 events scheduled and launched, `late: 0, dropped: 0`.
   The 150 ms lookahead absorbs hitches an order of magnitude larger than a frame.
3. **Full music route (G2.8)**: kick/snare/hat/perc/bass (choked mono)/chord plucks all
   flow through `schedule_trigger()`; commit boundaries applied in the schedule domain.

Verdict: Godot passes the migration's hardest technical gate. Remaining audio work
(DaisySP voices, per-voice synthesis, mixer replication) is engineering inside a
proven seam, not risk.

## How to rebuild the extension

```
cd native
python -m SCons platform=windows target=template_debug arch=x86_64 -j8
```

Requires VS 2022 C++ tools + `pip install scons`. godot-cpp is a shallow clone of
`godot-4.5-stable` (compatible with the 4.6 runtime, `compatibility_minimum = 4.5`).
