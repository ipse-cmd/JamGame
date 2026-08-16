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

## G1 — Minimal adversarial multiplayer (2026-08-16)

The gate: *can Jammin's future-buffered commit model survive host/client latency
while keeping UI responsive and audio locally scheduled?* The wire carries musical
decisions only — edit commands up, replicated commit-model state (with the
server-assigned boundary + version) down. Never audio triggers.

Setup: two instances on one machine (CLI host `--host --lagsim`, editor-run client),
ENet port 7777, explicit RPCs on `JamNetSession`. Roles: host=DRUMS+CHORDS,
client=BASS, gated client-side AND server-side. Clock sync: 6 pings, min-RTT sample,
RTT/2-compensated `transport.start_at()` (the M-PL0 move).

1. **G1.0–G1.4**: join + clock lock at RTT 8 ms; `server_loop == local_loop`
   immediately; full state sync on join; roles replicated.
2. **G1.2 strict validation**: 3 hostile commands (role violation, out-of-range step,
   extra payload field) → all rejected server-side, zero state disturbed, no repair.
3. **G1.5/G1.6**: client edit burst → pending ghost immediately (local prediction),
   server assigned boundary N+1, both machines promoted at the same loop:
   versions `[0,1,0]` == `[0,1,0]`, each machine scheduling its own audio (0 late).
4. **G1.7/G1.8 adversarial**: full-duplex lag sim 60±20 ms + 2% modeled loss on BOTH
   peers (RTT ~150 ms) + main-thread hitching (5–25 ms/frame). Order-sensitive burst
   (`clear` + 8 places + 2 retunes) arrived intact: **content matched intent exactly**,
   versions and loops agreed across two boundaries, rejects 0.

Two real findings from the adversarial pass:
- **Lag simulator must be FIFO.** Independently-delayed packets reorder commands
  (`clear` overtaking `place` mangled a line to 1 note). Real ENet reliable channels
  are ordered — loss causes head-of-line delay, not reordering. Fixed; state still
  *converged* even under reordering (server-authoritative echo), but musical intent
  requires ordering.
- **Lookahead must exceed step spacing + worst hitch.** At 112 BPM a sixteenth is
  ~134 ms; the 150 ms lookahead left ~16 ms headroom and 25 ms stalls produced 3 late
  events. Raised to 250 ms → 0 further lates over 15 s of hitching.

Verdict: the future-buffered protocol maps to Godot cleanly. Network jitter and
audio jitter are separate problems by construction — a command can arrive 150 ms
late and its audio still starts on the exact sample, because only *state* crossed
the network. Migration decision formally closed.

## How to rebuild the extension

```
cd native
python -m SCons platform=windows target=template_debug arch=x86_64 -j8
```

Requires VS 2022 C++ tools + `pip install scons`. godot-cpp is a shallow clone of
`godot-4.5-stable` (compatible with the 4.6 runtime, `compatibility_minimum = 4.5`).
