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

## Permanent adversarial integration suite (2026-08-16)

The G1/G2 experiments are now automated regression tests — run them after ANY
change to transport, networking, or the audio extension:

```
godot_console --path . res://tests/integration/integration_tests.tscn   (exit 0 = green)
```

Four tests (`tests/integration/integration_tests.gd`), ~25 s, needs a window
(audio tests require a real audio driver):

1. **AudioTimingUnderMainThreadHitches** — 32 pre-queued clicks at exact 3000-sample
   spacing stay sample-exact while the main thread stalls 5–25 ms every frame.
2. **NetworkDelayDoesNotAffectScheduledSamplePlacement** — submission times jittered
   by 120–300 ms (what network delay actually shifts) leave onset placement invariant.
3. **ReliableCommandsPreserveOrderUnderLatency** — order-sensitive burst (clear + 8
   places + 2 retunes) through the FIFO lag sim at 60±20 ms / 20% modeled loss
   arrives content-exact on the server AND survives the echo path. Guards the
   "consistency ≠ intent preservation" invariant.
4. **PeersPromoteSameVersionAtSameBoundary** — a real two-peer ENet session in one
   process (branch-scoped MultiplayerAPIs, 4x-speed transports, clock-synced):
   both peers promote the same version with identical content at the SAME loop.

The network tests run the real `JamNetSession` + commit models + `JamTrackOps`
(op semantics extracted from the room into the domain layer for exactly this
reason) against stub rooms — no UI involved.

**Mutation-verified**: reintroducing the non-FIFO lag simulator makes tests 3 and 4
fail with the mangled line visible (exit 2); restoring FIFO returns the suite to
green. The tests demonstrably catch the bug they memorialize.

Known modeled edge (deliberate): an edit inside the final ~RTT of a loop may slip
one boundary — Jammin's lock horizon exists for this and is not yet ported. Test 4
bursts just after a boundary to assert the common case, not that edge.

## Feature phase 1 — Real drum system (2026-08-16)

First vertical feature migration on the proven seams. Ported from the Unreal
reference (semantics read from `JamDrumModifiers.cpp` / `JamDrumTemplates.cpp`):

- **Modifiers (D3)**: `drum_renderer.gd` — exact port of the Drop → Intensify →
  Fill pipeline as a non-destructive render-time lens over the per-step hit set.
  Deterministic (no RNG) so peers derive identical feel from replicated state.
  Fill is phrase-gated (phrase = one 4-bar loop here); a fill pressed on the final
  bar auto-stretches to the next turnaround. Press rules in `drum_state.gd`
  (drop escalates light→heavy, intensify extends, fill doesn't stack).
- **Kit variants (D9)**: 3 synthesis presets per lane (Deep/Punch/Boom,
  Snap/Tight/Fat, Closed/Open/Crisp, Tom/Conga/Low Tom) — implemented as a
  thread-safe voice-table swap in the audio engine; the G2 trigger protocol is
  untouched.
- **Templates (D8)**: Backbeat / Four-on-floor / Boom bap / Half time, applied as
  a pending edit committing at the boundary (bass-lane hits omitted — bass is its
  own ring). Op flows through `JamTrackOps` like any pattern edit.
- **Lock horizon**: edits in the final 2 sixteenths of a loop (~268 ms > worst
  simulated RTT) schedule commit at N+2 — closes the boundary-slip edge test 4
  documents.
- **Replication**: modifiers/kit are live drum-role state (`state_drums`), not
  commit-gated; strict server validation extended to the 5 new ops. Keys: F/G/H
  fill/drop/intensify, K kit, T templates (host/join moved to F2/F3).

Seam rule held: modifiers transform hits (never touch audio), the network carries
ops/state (never triggers), the extension learned nothing.

Validation: **101 unit tests green** (modifier pipeline ported test-for-test from
the Unreal suite, templates, press rules, lock horizon); live proof via injected
keys (template pending→committed 12→20 hits v1, kit [2,0,0,0], 3 modifier events,
0 late); **4/4 integration tests green** after the net changes; MP proof: join
full-sync replaced local drum state with host's, 3 hostile ops (role-violating
kit/fill, template index 9) all rejected.

## AI player Phase 1A — rule bass policy + decision logging (2026-08-16)

First slice of the AI-player roadmap. Constraint fixed from day one: **an AI
player is indistinguishable from a hostile/untrusted peer** — it emits ordinary
`JamTrackOps` through normal validation; no privileged path.

- **`scripts/ai/rule_bass_policy.gd`**: pure `(observation, seed) → ops`.
  Deliberately simple, NO intent layer (that's Phase 3, verified against this
  baseline). Deterministic by construction: no wall clock, no global RNG.
  Rules: fresh line breathes ≥1 window; healthy+non-stale line HOLDs ~65%;
  density steered into [3,6]; stale (≥3 windows) forces one moved note;
  desired-line diff emitted as place/retune/remove ops. Candidate scoring:
  harmonic fit across all chord slots + kick alignment + spacing + downbeat
  root anchor; seeded rng tie-breaks only within the near-best band.
- **`scripts/ai/bot_observation.gd`**: THE observation constructor (BotPeer and
  the MCP manual-policy path must both use it). Future-facing: pendings that
  commit by the target loop are observed, later ones aren't.
- **`scripts/ai/decision_log.gd`**: append-only JSONL decision-WINDOW logging —
  zero-op HOLDs are first-class frames (else a learned player inherits
  pathological busyness). DecisionKey = {room_epoch, role, target_loop,
  state_version}; per-decision seed = splitmix64(session_seed, epoch, role,
  target_loop), so same state + same session seed → same ops on any peer at any
  transport speed. Sources (human/rule_bot/ml_bot) stay separated forever.

Validation: **134 unit tests green** (+33: determinism, guaranteed-hold window,
server-validation shape of every emitted op, stale mutation preserves density
while changing the line, density steering both directions, hold AND edit both
occur across seeds, chord-tone floor, seed derivation, JSONL round-trip incl.
zero-op frame). Behavior spot-check over 10 loops × 2 seeds: root anchored on
both kicks, third voice wandering chord tones (never the non-chord-tone
degree), ~35% holds, seeds phrase differently, fully reproducible.

Harness finding while validating: the integration suite silently required the
compositor to serve frames — an occluded window (or locked screen) blocks
vsync'd swaps at ~1.2 fps, wrecking wall-clock-paced submission and clock sync
while audio keeps mixing (13 clamped onsets, phantom "late" events). The suite
now disables vsync and caps at 120 fps; **4/4 integration tests green**
regardless of window visibility.

## AI player Phase 1B — BotPeer as an ordinary network participant (2026-08-16)

The 1A policy mounted as a real peer. `scripts/ai/bot_peer.gd` observes
replicated state, decides once per editable window, and submits through the
room's normal dispatch (local prediction + server validation) — the same path
as human input. `JamRoom.dispatch()` is now the public non-UI entry point;
`--bot` / `--bot-seed=N` launches the real rule bot with decision logging
(replacing the old timer stub).

- **Watermark**: at most one authored decision per (room_epoch, role,
  target_loop). `room_epoch` is new engine state — bumped by the server on
  every `host()`, replicated via snapshot — so a rehost/reset legitimately
  reopens windows instead of aliasing a previous room life.
- **windows_since_change** tracked off the replicated version counter: a
  version bump resets staleness AND emits a commit-resolution event joined to
  the originating DecisionFrame by decision key.
- **Op sequence IDs**: client-assigned, recorded in frames (log-side only —
  the wire protocol is untouched; the server-rejection join lands later).

Validation: **147 unit tests green** (+13: one decision per window regardless
of observation count, epoch bump reopens the watermark, role gate silences the
bot entirely, bot never dispatches outside its role, guaranteed breathe-HOLD
after a committed change, frame count == decision count, HOLDs == zero-op
frames, commit events present). **5/5 integration tests green** — new gate
`BotPeerPlaysBassAsOrdinaryPeer`: the bot mounted on the REAL client peer under
the impaired link (60±20 ms, 20% modeled loss) decided 7 windows with zero
duplicate authorship, ≥1 edit and ≥1 deliberate hold, a squatter bot pointed
at the host's drums never acted, the server rejected nothing, both peers
converged on the same committed line and version, and the JSONL log carried
exactly one frame per window with HOLDs as zero-op frames.

## AI player Phase 1C — external-process bot is the same player (2026-08-16)

Deliberately boring: same BotPeer code + different process boundary = same
behavior. New gate `ExternalBotProcessIsTheSamePlayer`: a REAL game instance
(`--join --bot-seed=777 --bpm=448`) spawned as a separate OS process joins the
test host over actual ENet, takes the BASS seat, and authors windows (holds AND
edits) that the host commits at sane density. The strongest assertion is the
**replay**: every logged frame's observation + seed, run back through the
policy in the test process, reproduces the logged ops exactly — process
location is provably irrelevant to the policy, and a logged observation is
provably sufficient to reproduce its decision.

Two real findings, memorialized in the code:
- **Scoped-multiplayer RPC paths are RELATIVE to the multiplayer root.** The
  in-process harness never felt it (symmetric "Net" on both branches), but an
  external game peer sends "JamRoom/Net" relative to /root — the test host's
  scoped API must root at a wrapper CONTAINING JamRoom/Net.
- **64-bit seeds must be logged as strings.** JSON numbers are doubles; a
  numeric splitmix64 seed loses low bits on read-back and silently breaks
  replay determinism.

Dev knob: `--bpm=N` lets an externally launched peer match a harness transport.

## AI player Phase 2A — JamFeatures: measurements, not opinions (2026-08-16)

`scripts/core/jam_features.gd`: a pure functional library over plain state
dicts (to_dict() shapes) — no nodes, no autoloads — so the same code measures
live state, hypothetical candidate states, and logged/replicated snapshots.
Only objectively defensible measurements: per-voice drum densities, bass
density / pitch mean / pitch range / mean interval, kick↔bass onset alignment,
chord slot count, active role count, and `similarity(a,b)` (Jaccard per track)
as the substrate for any repetition signal. Interpretations (energy/tension)
are deliberately NOT here — they belong in a later JamAnalysis.interpret layer
that consumes these features, keeping the measurement/opinion boundary hard.

BotPeer now attaches features of the observed (pre-edit — ordering matters and
is tested) state to every DecisionFrame as `analysis`.

Validation: **166 unit tests green** (+17: every feature hand-computed on the
starter fixture, empty-state zero behavior, similarity identities including
one-hit jaccard 12/13, and feature invariance across the JSON round-trip —
which caught string-keyed steps sorting lexicographically). **6/6 integration
tests green.**

## AI player Phase 2B + 2C — temporal features and the observation contract (2026-08-16)

**2B — temporal measurements.** Two states with identical snapshot features are
musically different if one just changed and the other sat still for six loops.
`JamFeatures.compare(prev, cur)` (pure deltas over the numeric feature keys)
plus `scripts/core/jam_history.gd` — a ring that only STORES per-loop
{state, features, versions}; all math stays in pure functions so candidate
scoring and offline replay measure identically. Temporal output: per-feature
deltas vs the previous loop, event-overlap vs 1/2/4 loops ago (explicitly named
`*_event_jaccard_prev_N` / `chord_slot_match_prev_N` — overlap is a
measurement, "repetition" is a judgment for the interpretation layer), and
per-track change ages from the three version counters (`loops_since_*_change`,
a lower bound: a bot only knows what it watched). Unobserved lookbacks are
null — honesty over fabrication.

**2C — JamObservation as a versioned serialization contract**
(observation_schema 2): canonical state + snapshot features + temporal context
+ decision metadata, built ONLY by `JamBotObservation.build_bass` (BotPeer, the
MCP path, trainers, and replay all consume this one structure). The contract
test pins encode→decode→encode as a byte-identical fixed point — sidestepping
float-precision comparison — and the policy replays identically through the
round-tripped structure. BotPeer feeds history each loop (audible/active
states) and frames' `analysis` is now the observation's own feature block,
measured before the bot's ops mutate the pending buffer.

Validation: **184 unit tests green** (+18: hand-computed deltas, still-state vs
changed-state history including per-track age reset, null lookbacks, monotonic
push guard, schema field, fixed-point serialization, full-schema policy
replay). **6/6 integration green** — the external-process gate now pushes the
schema-2 observation through real ENet + JSON logs and still replays exactly.

## How to rebuild the extension

```
cd native
python -m SCons platform=windows target=template_debug arch=x86_64 -j8
```

Requires VS 2022 C++ tools + `pip install scons`. godot-cpp is a shallow clone of
`godot-4.5-stable` (compatible with the 4.6 runtime, `compatibility_minimum = 4.5`).
