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

## Chord-relative bass — R/3/5/7/O (2026-08-17)

Found by PLAYING (the whole point of Phase 2.5): the bass ring resolved its
lanes against the fixed key root, so a stored motif sounded identical every bar
while the chord strip moved underneath it. Fixed as a **semantic
reinterpretation, not a bass-system refactor**: `JamBassLine` already stored
semantics (step → lane), the wire format, op grammar, server validation range
(0..4), ring UI, and bot op legality are all untouched. The 5 lanes now mean
harmonic ROLES against the current bar's chord:

    lane 0 → R → chord degree +0        lane 3 → 7 → +6 (DIATONIC seventh —
    lane 1 → 3 → +2 diatonic steps                 derived from the key, no G7
    lane 2 → 5 → +4                                 spelling needed)
    lane 4 → O → chord root + 12 semitones (the one lane that isn't a third-stack)

`Harmony.chord_tone_midi(root, chord_degree, tone)` is the single resolver used
by the native scheduler, the legacy trigger path, AND feature extraction — the
analysis layer can never disagree with the audio. Empty chord slots (-1)
resolve against the tonic. Invariant pinned: `chord_tone_midi(c, 4) ==
chord_tone_midi(c, 0) + 12` for every degree.

**JamFeatures v2** (features_schema 2, observation_schema 3): the old
key-relative pitch stats described a different musical world than the one being
heard, so bass measurement split into two families answering different
questions. SEMANTIC — what behavior was written: per-lane fractions
(`bass_root/third/fifth/seventh/octave_fraction`), normalized
`bass_lane_entropy`. SOUNDING — what it produces under this progression: the
one-bar motif virtually rendered across all four chord slots
(`sounding_pitch_mean/range`, `sounding_mean/max_interval`,
`sounding_direction_change_rate`). The motivating case is pinned as a test:
R-only pedal is semantically static (root_fraction 1, entropy 0) yet sounds
C2-A2-F2-G2 under I|vi|IV|V. RuleBassPolicy untouched — its chord-tone scoring
is now vacuous BY CONSTRUCTION (every lane is structurally harmonic), which is
the desired staged action-space design: V2 lanes 2/4/6 reintroduce
harmonic-context choice as color/tension.

Validation: **215 unit tests green** (+31: the V|vi|IV|V five-lane sounding
table, octave invariant across all 7 degrees, tonic fallback + diatonic
seventh, hand-computed semantic fractions/entropy and 4-bar sounding stats
including the 16-semitone max leap and 6/10 direction reversals, pedal-tone
case, schema bumps, JSON round-trip). **6/6 integration green** — the bot
plays the same legal ops under the new semantics and the external-process
replay gate still reproduces logged frames exactly.

## Pointer grammar slice 1 — rings as the instrument, radial blooms as vocabulary (2026-08-17)

The interface direction: **rings are the instrument; radial blooms are the
contextual vocabulary; the keyboard is a shortcut layer.** Three-level pointer
grammar (mouse today; touch rides Godot's emulation): tap = perform the
obvious action, hold = expose musical options, drag + release = choose.
Everything routes through the SAME `_dispatch` as the keyboard and the bot —
the UI produces ordinary validated ops; role gates, server validation, and the
commit boundary apply unchanged. No new mutation path.

- **Drum ring**: tap a wedge toggles the hit in that lane (no cursor dance);
  hold blooms ACC / DEL.
- **Bass ring**: the 5 concentric lanes ARE the chord-relative vocabulary, so
  tapping a lane places/re-tunes/removes that tone directly; hold blooms
  R/3/5/7/O + × (thin-lane fallback for touch, and deliberate choice).
- **Chord strip**: pressing a bar blooms I–vii° + × (clear). This needed one
  op-grammar addition: `chords "set" {bar 0..3, degree 0..6}` — validated,
  idempotent, and also exactly what the Phase 2.5 manual policy and a future
  RoleRealizer want (cycle ±1 cannot express "pick vi directly").
- **`JamRadialBloom`**: reusable overlay; momentary (hold-drag-release like an
  instrument) with a sticky fallback (a quick tap keeps it open for a second
  click), Esc/right-click cancels. Gesture resolution is a pure static
  function.
- Gestures also move focus/cursors, so keyboard and pointer stay coherent.

Findings: GDScript rejects `match` inside a lambda ("Expected expression for
match pattern") — bloom handlers are named methods with `Callable.bind`. The
in-process integration tests never load jam_room.gd; only the
external-process gate (test 6) boots the real game and caught the parse error
— the reason that gate exists.

Validation: **235 unit tests green** (+20: every ring wedge centroid picks
back to its own (lane, step) — hit-testing is the exact inverse of the draw
layout; chord-strip slot picking incl. margins; bloom gesture resolution for
dead zone/center/all option directions/outside; `set_slot` range guards;
chord "set" through TrackOps editing pending only). **6/6 integration green.**

## Phase 2.5 groundwork — human decision recording + shadow policy (2026-08-17)

Two passive recorders, both mandated by the design docs before the
observation schema freezes:

**Human recording (always on for player instances).** "You cannot reconstruct
human decisions from sessions you failed to record." `JamHumanRecorder` gives
HUMAN bass play the same window semantics as the bot: the observation is built
when the editable window OPENS (pre-edit, same `JamBotObservation` contract),
raw ops accumulate in submission order off the room's new `edit_dispatched`
signal (emitted for every locally accepted edit), and the frame is written
when the boundary closes — zero-op windows are first-class HOLD frames.
Attention proxies (`window_focused`, `input_events`) distinguish a deliberate
hold from an AFK one. Records only seats the local player owns; `--bot`
instances mount no recorder. Logs to `human_<ts>.jsonl`, source `human`,
policy tag `human_ui` — never mixed with bot sources.

**Shadow policy (`--shadow` / `--shadow-seed=N`).** The rule policy mounted on
a peer that does NOT own bass: the role gate is bypassed for OBSERVING only —
it decides and logs proposals (`"shadow": true` frames, `shadow_<ts>.jsonl`)
but never dispatches, never sets a pending-commit key, and its staleness clock
keeps running since its proposals never resolve. Result: human frames and
policy proposals over IDENTICAL windows and observations — the raw material
for the 2.5 divergence analysis ("what did the human know that the observation
doesn't contain?") and later preference/counterfactual experiments.

Validation: **260 unit tests green** (+25: ops grouped into their window,
pre-edit observation ordering, foreign-role ops ignored, HOLD frames,
state-version advance across commits, attention-proxy fields, seat gating for
recorders; shadow never dispatches, all 8 windows logged with proposals,
stale pressure forces proposals, zero commit events). **6/6 integration
green.**

## Observation schema 4 — the gaps the 2.5 experiment actually found (2026-08-17)

The first live human-vs-shadow session (27 human windows, 28 shadow proposals
over identical observations) produced two concrete divergences, and both were
observation gaps predicted by the design docs:

1. The human edited EXACTLY where the policy is forbidden to: immediately
   after changing the chords, continuing to sculpt bass across the
   breathe-hold windows. The policy cannot distinguish "someone changed my
   line" (rest) from "I am mid-phrase" (continue) — it lacked **change
   attribution**.
2. The human's only edit trigger was harmony; the shadow's only trigger was
   its staleness clock. (Policy-side consumption is 3A's job — the rule bot
   stays baseline — but the observation must carry the inputs.)

Schema 4 adds, built by the observers because only a participant knows which
ops were its own (op attribution is not on the wire — the server replicates
state, not ops):

- **`last_change_by`**: per-track `"self" | "other" | "none"`. BotPeer: a bass
  bump is self iff its own edit was awaiting resolution (shadow mode: always
  other). HumanRecorder: a bump is self iff the local player dispatched ops
  into that track since the previous bump (`edit_dispatched` fires only for
  locally accepted edits).
- **`bass_notes_prev`**: the previous committed bass line (from
  `JamHistory.state_before_change`, a storage read), null when unobserved or
  evicted — for revert/continuation reasoning. Rehydrated to int keys by
  `from_json`; the fixed-point and policy-replay contract tests still pin the
  round trip.

Also recorded from the session: attention proxies cleanly separated 4
deliberate listening holds (focused, input rising) from a 14-window AFK tail
(unfocused, zero input) — without which "hold forever" would read as musical
taste. Known shadow artifact confirmed: proposals never resolve, so the
shadow's staleness clock never resets and it proposes every window once
stale; preference-pair extraction must weight for this.

Validation: **272 unit tests green** (+11: state_before_change storage read,
attribution defaults absent-not-fabricated, observer-supplied attribution
flow-through, pre-change line surfacing + int-key rehydration, bot
self-after-commit and foreign-bump-is-other, human self-attribution with
authored-but-uncommitted tracks staying none). **6/6 integration green.**

## Phase 3A — JamAnalysis: the musical perception layer (2026-08-17)

`scripts/core/jam_analysis.gd`: a pure, deterministic, versioned
(analysis_schema 1) function from a schema-4 observation to a VECTOR of
interpretation contributors — never a single tension scalar; collapsing the
vector is the consumer's decision. The layer holds the design opinions
(normalization ceilings, tone/function tension tables, weights) that
JamFeatures deliberately refused to hold.

Contributors and their specific meanings:

- **energy** — activity/force (density + motion), NOT tension: a dense
  consonant groove is high-energy and calm.
- **rhythmic_tension** — WHERE events sit, normalized per event (offbeat
  weighting + kick↔bass divergence), so it cannot become a second density
  metric.
- **harmonic_tension** — resolution pressure from two independent
  contributors: bass tone color over the chord-relative lanes (R/5 stable,
  3 descriptive, 7 directional) + diatonic function (I low … V directional,
  vii° strong). Lanes 2/4/6 will slot in without an API change.
- **density_tension** — crowding via PAIRWISE track fullness products:
  drums-dense-bass-sparse is energetic but uncrowded.
- **external_change_pressure / self_change_pressure** — kept as SEPARATE
  outputs (same principle as no global tension): schema 4's attribution is
  exactly what distinguishes "someone changed the jam → listen/react" from
  "I just changed my line → don't immediately re-change". Documented, not
  implemented: if own and foreign ops share one observed version transition,
  "mixed" is the honest fourth attribution state — add it when a test
  demonstrates the ambiguity.
- **repetition_pressure** — time-without-novelty (first simple version:
  weighted change ages); bass_notes_prev enables alternation/motif-recurrence
  refinements later without an API change.

Unobserved inputs (empty temporal, "none" attribution) contribute ZERO
pressure — no information is never interpreted as pressure. Both observers
attach the vector to every frame (`interpretation` field, human and bot/shadow
alike), so the 2.5 divergence corpus is now automatically annotated with what
the perception layer would have said. The rule policy deliberately does NOT
consume it (baseline stays frozen); the first consumer will be Phase 3B/4.

Validation: **296 unit tests green** (+24: the full scene table — sparse/calm,
dense-consonant high-energy-low-tension, sparse 7ths-over-V low-energy-high-
tension, all-offbeat syncopation, fresh external edits, stale-forever,
self-change, chords-moved-under-stale-bass — plus the two structural
invariants energy≠tension and change≠repetition pinned as opposing orderings,
monotonic repetition, zero-pressure-when-unobserved, and byte-identical
interpretation across the JSON boundary). **6/6 integration green.**

## Phase 3B — interpretation-aware intent policy, shadow-only (2026-08-17)

`scripts/ai/intent_policy.gd`: deterministic threshold rules over the 3A
vector producing a small behavioral vocabulary — HOLD / RESPOND / SIMPLIFY /
INTENSIFY / VARY / REVERT — keeping perception ("what is happening"),
intention ("what should I do about it"), and realization ("what should that
sound like") strictly separate. No RNG, no note knowledge; the drivers that
fired are returned with the intent, so the reason IS the log.

Priority order is part of the contract: REVERT (own change crowded the jam —
`bass_notes_prev`'s first consumer; the actual previous pattern, not a
mutation in the opposite direction) > HOLD-on-self > RESPOND > SIMPLIFY >
INTENSIFY (hot jam, bass under-participating) > VARY > HOLD.

**Shadow-only**: the frozen rule baseline still plays; both observers attach
the intent the 3B policy WOULD have chosen to every frame, next to the
baseline's ops and the human's actual ops. The comparison "did causal signals
improve behavioral timing?" gets answered from session logs before any intent
is realized (3C: intent-conditioned candidate generation).

**Style hook architected, inert**: `decide(obs, interp, style_context)` with
DEFAULT only — the 3A signals describe interaction, not genre; genre belongs
to realization weights (3D/3E) and we refuse to invent them without corpus
evidence. Unknown styles fall back to default behavior, the request is
preserved in the output for the log.

The flagship test is the 2.5 divergence converted into explicit behavior:
stale+quiet → VARY, chords-changed-under-stale-bass → RESPOND (external
outranks staleness), own-fresh-edit → HOLD. Plus crowding→SIMPLIFY before
VARY, hot-jam-absent-bass→INTENSIFY (and its negation), REVERT requiring
bass_notes_prev (falls to HOLD without it), calm default, determinism, style
fallback.

Corpus stage 1 started alongside (~/JamminCorpus, research-use): GMD
(genre drums), POP909 + POP909-CL (pop keys/chords), FiloBass (jazz bass +
chords, via Zenodo), MidiCaps captions (genre filtering over Lakh), Lakh
lmd_full. Slakh2100 (~100GB, interaction) located but not auto-downloaded.
Next data-side artifact: a midi → JamminCorpusExample converter into the ONE
common representation (chord-relative bass, features, style tags).

Validation: **307 unit tests green** (+11). **6/6 integration green.**

## Phase 3B gate — first live session results (2026-08-17)

One instrumented solo session (53 windows, 13 human edit windows, 3 chord
changes): the intent policy keyed RESPOND (driver
`external_change_pressure=1.0`) to BOTH of the human's harmonic responses —
including the one the frozen baseline missed entirely — and stayed quiet at
the chord change the human ignored, where the baseline fired from staleness.
SIMPLIFY correctly tracked a density pile-up (0.78) where the baseline sprayed
an identical 10-op removal flood every window. Naive per-window act/hold match
was a wash (29% vs 31%), dominated by idle-tail windows — response timing at
events is the discriminating metric. Attention proxies resolved three
engagement states (focused+input / focused-idle / away). Verdict: mechanism
proven on the flagship divergence, n too small for statistics — which the 3C
duet makes moot: the intent policy now plays audibly and every jam produces
richer human-reacting-to-bot data as a byproduct.

## Phase 3C — intent-conditioned candidate realization (2026-08-17)

`scripts/ai/bass_realizer.gd` + `scripts/ai/intent_bass_policy.gd`: the full
perception → intention → realization pipeline as a policy with the SAME
contract as the frozen baseline (pure `decide(obs, seed) -> ops`), mounted via
`--bot --bot-policy=intent`. RuleBassPolicy remains untouched as the
comparison baseline.

- **Candidates per intent** (each set includes "hold" — the line may already
  serve the intent): RESPOND = anchor root / add diatonic 7th / align to kick
  / recolor one note; SIMPLIFY = strip offbeats / retune color to R-5 / strip
  to band; INTENSIFY = root on beat / double a kick / octave lift; VARY =
  move / retune / breathe-or-add; REVERT = restore `bass_notes_prev` exactly
  (op-capped: partial revert beats a flood).
- **Deterministic evaluator** (the 3D/3E swap point): simulates each
  candidate's ops and scores the RESULT — shared house style (density band,
  kick alignment) + intent-specific terms (thinner for SIMPLIFY, novelty for
  VARY, downbeat grounding for RESPOND). Seeds choose only WITHIN candidates;
  scoring is seed-free; ties resolve by generation order.
- Emergent judgments the tests pin: VARY on an out-of-band line REFUSES (a
  crowded line needs SIMPLIFY, not novelty); RESPOND can enter from an empty
  seat; SIMPLIFY on a sparse line holds; the mounted bot listens ~5 windows
  before room-wide staleness draws it in, then breathes after its own commits
  (self-pressure) — bandmate pacing emerging from the pipeline, not scripted.
- **Auditability**: every edit frame logs the full realization —
  interpretation vector, intent + drivers, candidate scores, winner. The
  reason IS the log.
- Replay: the whole pipeline (interpret → intend → generate → evaluate)
  reproduces byte-identically from a JSON-round-tripped observation + seed.

Validation: **348 unit tests green** (+41: full-legality sweep across every
intent×seed×state, determinism, per-intent faithfulness by simulation, revert
restoration + cap, empty-seat entry, pipeline JSON replay, mounted-bot
listen-then-act pacing, explained frames). **6/6 integration green.**

## First duet session + REVERT v2 (2026-08-17)

First human-vs-intent-bot duet (82 bot windows, session bot_1787000738), user
verdict "timing is good", logs concur: entered after listening 5 windows;
21 edits / 61 holds; 19/21 edits immediately followed by a HOLD; RESPONDed to
every chord change within 0-2 windows with the right candidate (anchor_root
when the downbeat had drifted, add_seventh/recolor otherwise) while the
baseline shadow proposed unrelated staleness moves; 21/21 edits committed,
zero rejects.

The explained frames exposed a real behavioral bug invisible to tests:
**REVERT ping-pong** (windows 58-66) — the bot reverted its own MOVE, then
reverted the revert, then reverted a seventh it had just added as a RESPOND.
Cause: ambient density (the human's busy drums) satisfied "crowded", and a
revert is itself a self-change. IntentPolicy v2 adds two guards: REVERT
requires the bot's change to have ADDED notes (count > prev — moves and
reverts can never re-trigger it) and no live external pressure (a response is
forward motion, not retreat). Regression tests pin both ping-pong shapes.

Noted for the style era, not changed: VARY cadence is metronomic (threshold
crossing every 4th window — variability is a style/seeded-jitter concern) and
VARY's random walk can erode the downbeat anchor (a candidate-evaluator term,
possibly; the RESPOND anchor_root currently repairs it on the next harmonic
event).

Validation: **350 unit tests green** (+2 regressions). **6/6 integration
green.**

## Corpus converter stage 1 — midi → JamminCorpusExample (2026-08-17)

`tools/corpus/convert.py`: GMD (1,138 drum performances) and FiloBass (48
jazz bass performances, via its pre-joined note_data.csv — every note already
aligned to its chord) converted into ONE common representation
(example_schema 1): 16-step bars, chord-relative bass tokens (game lanes
R/3/5/7 + explicit out-of-vocab x2/x4/x6 color classes), and the game's own
feature definitions (densities, offbeat mass with JamAnalysis's 0/.5/1
weights, groove timing as %-of-a-16th deviations by down/e/and/a position —
AGR-compatible). Output: JSONL + SUMMARY.txt in ModelData/JamminCorpusExamples.

First empirical findings (style profiles are now measurements, not adjectives):

- **73.9% of 53k real jazz bass notes fit the V1 lanes** (R .334, 3 .164,
  5 .155, 7 .090); the remainder is almost exactly the planned V2 color set
  (9ths .097, 11ths .091, 13ths .069) — the staged action-space design
  confirmed by corpus. Walking bass is ON the beat (offbeat mass .077 vs
  ~.45 for drums) and stepwise (mean interval 3.45 st).
- **Jazz is the only style with a positive swung "and"** (+8.2% of a 16th;
  blues shuffle +22.6 at n=4) — every groove style pushes it ahead (funk
  -9.5, hiphop -7.1, dance -14.1). Jazz kick is feathered (density .125,
  half of rock's). Punk inverts the velocity hierarchy (offbeat 90 vs
  downbeat 60). Funk = high hat density + high offbeat mass + tight 16ths +
  strong ghost-note velocity contrast.
- Caveat pinned: deviations fold at ±50% of a 16th, so extreme swing can
  alias into the neighboring step (blues/afrocuban small-n values are
  indicative, not gospel). GMD fills are tagged (`kind`) and excluded from
  beat profiles.

These distributions are the seed data for 3D JamStyleProfile (drum + bass
profiles per style) and the renderer groove lens (nominal AGR shapes + these
measured variances).

## JamStyleProfile v1 + the separability gate — PASSED (2026-08-17)

Converter v2 (example_schema 2) stores distributions, not means: per-step
onset histograms per lane, timing-offset histograms per beat position,
bass tone-given-beat splits, interval and tone-transition distributions.
`tools/corpus/profiles.py` estimates PARTIAL, role-specific profiles with
provenance and confidence — 17 style files; only jazz has a bass section
(FiloBass, HIGH); drums range HIGH (rock/funk/jazz/latin/hiphop) to LOW;
missing roles are absent, never fabricated.

**The gate** (required before profiles may influence gameplay): held-out
label-free classification of 115 GMD performances by nearest-profile
likelihood over 7 styles — **51% vs 14% chance (3.6×)**. Confusions are
musically legible: funk 82%, latin 83%, hiphop 88% (distinct vocabularies);
rock 24% (the generic style — scatters everywhere); pop↔soul overlap; jazz
56% . Verdict: the Jammin representation preserves stylistic identity where
styles have identity — it is not washing performances into generic
accompaniment. Profiles are cleared to become 3E scoring priors.

## Phase 3E — the jazz style prior enters the evaluator (2026-08-17)

`scripts/ai/style_prior.gd` + `data/style_profiles/jazz.json` (the corpus
profile, committed and versioned with the game — replay provenance) +
intent_bass_policy v2. A deliberately SMALL evaluator change:

    final = interaction + W_STYLE(0.35) * confidence_factor * style_fit

Style biases among reasonable responses; it never generates notes, never
alters the candidate set, never outranks interaction. Four dimensions stay
separate in every log (degree / beat-position / interval / transition fit)
and collapse only at the end — a weird choice is inspectable, and the
dimensions tell us which corpus features matter perceptually.

Scoring rules, each a pinned invariant:
- per-EVENT normalization (sparse vs dense candidates compare fairly);
- Laplace smoothing (zero-count in 53k events = "rare", never -inf);
- SOFT MANIFOLD: fits are nats-above-chance capped at 0.6 — "reasonably
  jazz-like" earns full credit, "extremely corpus-common" earns no extra
  (common != good: R R R R must not win on typicality), atypical floors at -2;
- missing profile data contributes EXACTLY zero (no substitute masquerading);
- w_style = 0 or absent profile -> byte-identical pre-3E decisions;
- exact provenance logged per decision (style_id, source, n_events, w_style);
- BOTH rankings (interaction-only vs styled) computed from the same candidate
  set and logged every frame — the ablation is built into the corpus, and
  disagreement frames are flagged for blind-listening export.

Direction sanity pinned from measurements, not opinion: the prior prefers
on-beat placement and stepwise motion because FiloBass does. V2 lanes stay
deliberately parked so the next duet tests style-aware SELECTION with the
vocabulary fixed — one architectural change at a time.

Validation: **371 unit tests green** (+21). **6/6 integration green.**

## Riff/motif bank — the player's own lines become bot vocabulary (2026-08-17)

`tools/corpus/harvest_riffs.py` reads HUMAN session logs (solo sessions —
rights-clean by construction), extracts bass-state transitions across
decision windows, filters by DWELL (windows a line survived — the implicit
quality signal; one-window casualties drop), groups consecutive similar
lines (event-jaccard >= 0.5) into MOTIFS with variants, dedupes across
sessions, and commits `data/pattern_bank.json` (bank_schema 1). First
harvest: 7 motifs / 9 variants from one day of play — the bank grows as a
byproduct of jamming, never as homework.

Realizer integration: `motif_variant` (VARY only, offered only when the
current line actually belongs to a harvested motif — "same idea, another
variant" instead of random cell mutation; repetition becomes musical
identity) and `bank_pattern` (VARY + RESPOND — a known-good line as a
candidate, reachable within an 8-op cap via the generalized `_diff_to`,
which REVERT now shares). Bank candidates flow through the SAME evaluator +
style prior — the bank proposes, it never decides — and the chosen pattern's
bank id rides in every logged realization.

Emergent improvement pinned: VARY on an out-of-band (crowded) line
previously refused (cell edits can't fix a bad line); with the bank it
escapes to a banked in-band riff instead.

Validation: **396 unit tests green** (+25: bank schema/legality, bank
candidates land EXACTLY on their banked variant, op cap, starter-groove
motif membership, provenance id in realizations, the crowded-line escape;
the whole-intent legality sweep covers the new candidates automatically).
**6/6 integration green.**

## DaisySP voice engine — the game sounds like Jammin now (2026-08-17)

The PCM-table spike voices are replaced by **Jammin's real DaisySP rack,
ported verbatim from the Unreal original** (`Plugins/JamAudioCore/.../
JamSynthVoices.h` → `native/src/jam_voices.h`): same DSP modules, same
parameter presets, same pool sizes (kick 4 / snare 4 / hat 8 / perc 4 /
bass 4 / pluck 16, steal-oldest), same base mix gains
(0.8/0.5/0.25/0.45/0.35/0.25). DaisySP itself (MIT) is vendored at
`native/daisysp/` from the same tree the Unreal build used.

- Kick/snare/hat/perc: DaisySP analog/synthetic drum models with the three
  kit variants per lane as Trigger-time presets — kit switching is now
  per-hit parameter hopping, no table swaps.
- Bass: poly-blep saw → ADSR (5ms/100ms/0.7/100ms) → SVF low-pass @1200Hz.
  **Real gated durations at last**: the room computes each note's gate as
  hold-until-next-note (capped at 4 sixteenths), so bass is legato instead
  of a resampled one-shot — and pitch no longer shifts timbre across octaves.
- Pluck (chords): Karplus-Strong with a 3ms deterministic xorshift noise
  burst — polyphonic, naturally ringing. This unblocks chord performance
  (sustained comp patterns need gated/ringing voices).
- Extension contract: `schedule_note(sample, voice, midi, velocity,
  duration, variant)` replaces the table API; the SPSC queue, absolute-sample
  stamps, per-sample onset placement, and (intended, actual) diagnostics ring
  are unchanged — the integration timing gates run against the same
  invariants on the new engine. The native rack owns the mix; GDScript passes
  pure musical velocities. Legacy fallback (no extension) keeps the PCM path.

**Cross-platform status** (all-C++ portable, per-platform builds required):
- linux x86_64: built + committed (`libjam_audio.linux.template_debug.x86_64.so`).
- windows: **existing DLL is STALE** (old table API) — rebuild on the Windows
  partition: `python -m SCons platform=windows target=template_debug arch=x86_64 -j8`.
- macos: build on the MacBook: `scons platform=macos target=template_debug`
  (universal dylib path already wired in the .gdextension).
- ios: entries added to the .gdextension;
  `scons platform=ios target=template_debug` on the Mac when packaging.

## Groove lens + room mixer/drum-synth popout + chord performance (2026-08-17)

Three systems in one arc, all through existing validated paths:

**Groove lens (V)** — ported from the Unreal original (JamGrooveLibrary/
Processor, values from our Ableton captures): 6 templates (Base straight /
Shake / Shake-heavy / Push lay-back / Trip triplet-lurch / Clave 3-3-2) as
per-step timing offsets (quarter-note beats, independent periods) + velocity
multipliers, blended by TimingAmount 0.7 / VelocityAmount 0.2. Applied at
RENDER time to drum scheduling — the lens never rewrites the pattern; the
template index replicates as drum-role state, so every peer derives identical
offsets. Trip's negative (rushed) offsets stay far inside the scheduler
lookahead — the pinned max_negative_groove_offset constraint, now with a test.

**Room mixer + drum-synth popout (M)** — the D10 mixer: 6 per-pool gains
(0..2, unity notch) on top of the rack's base mix, applied ATOMICALLY on the
audio thread (`set_pool_gain`). Server-owned drum-role state — the drummer
adjusts, everyone hears the same mix ("turn up the kick" is now a slider).
The popout panel is pure projection + dispatch: sliders emit validated `mix`
ops, kit buttons per drum lane emit `kit` ops, the groove row cycles `groove`
— nothing in the panel has its own authority.

**Chord performance (W/S on chords focus)** — WHAT the chords play (slots)
now separate from HOW (comp + voicing, commit-gated fields on the chord
track — zero new net paths, they replicate/promote like any edit). 5 comp
patterns (Pad / Pulse / Offbeat / Charleston / Arp), 3 voicings
(Close / Open / Wide — same pattern, different spread: the smallest ladder),
comping velocity band 0.7, and rolled chords (~8ms per voice low→high, from
the measured budgets) — on the DaisySP plucks this finally sounds like an
instrument, not a bar-top stab.

Validation: **430 unit tests green** (+34: groove no-op/wrap/samples/velocity
math + the negative-offset-vs-lookahead pin; mixer clamp + replication round
trip; voicing spreads, comp legality, arp cycling, commit gating, performance
in equals/replication). **6/6 integration green.**

## Voice expansion — activate-what-we-own + Freeverb + WeirdDrums topology (2026-08-17)

The portedplugins survey (GPL-3 collection, mostly ports of MIT code we
already vendor) turned into an activation pass of our own tree plus two
clean-room additions:

- **Expanded drum kits** (per-lane variant counts, kit op unchanged): Kick 6
  (analog Deep/Punch/Boom + SyntheticBassDrum Click/Solid + parametric Zap),
  Snare 6 (synthetic Snap/Tight/Fat + AnalogSnareDrum 808/Rim + Trash),
  Hat 4 (+ Shaker), Perc 6 (analog toms + MODAL Block/Bell — real struck
  bodies at last — + Laser).
- **WdLayer** — parametric drum topology clean-room after WeirdDrums by
  Daniele Filaretti (MIT, JUCE plugin; topology reused, reimplemented over
  DaisySP), itself channeling Sonic Charge Microtonic: sine osc with
  exponential pitch envelope + filtered-noise layer + tanh drive. One
  topology, any drum — powers Zap/Trash/Shaker/Laser and is the future
  kit-designer voice (knobs in the M panel someday).
- **Two new chord synths** (SYNTHS now 5, Q cycles): String (Mutable
  StringVoice — extended Karplus with exciter/brightness) and Mallet
  (ModalVoice — vibes/marimba territory).
- **jam::Reverb** — Freeverb (public-domain Schroeder/Moorer topology,
  classic tunings) implemented fresh: upstream DaisySP moved reverbsc to an
  LGPL companion repo, which a statically-linked cross-platform GDExtension
  is better off without. Per-pool sends (drums dry-ish, notes wet), stereo
  wet return — the game's first stereo element.
- **Master soft limit** (tanh) — raw float sums could clip at full mixer
  gains; measured rack peak now 0.955 with kick + mallet + full sends.
- LGPL compressor skipped deliberately (MIT limiter available if needed).

Offline harness renders every new variant at healthy levels. Validation:
**434 unit tests green**, **6/6 integration green** (timing gates unchanged
on the stereo master path).

## Interaction axis — measured drums↔bass coupling enters the prior (2026-08-17)

`tools/corpus/interaction.py`: drums+bass pairs from aligned multitracks —
BabySlakh (19 clean-labeled pairs) + Lakh genre-filtered through MidiCaps
captions (jazz 268 / electronic 120 pairs; 400-file caps per genre, LOGGED).
Per pair on the 16-step grid: the joint per-step {kick&bass / kick / bass /
neither} table, per-bar density correlation, bass-in-drum-silence rate.

**The findings (all HIGH confidence, remarkably cross-genre):**
- Bass lands on the kick at **3.4× the rate of anywhere else**
  (bass|kick 0.67-0.70 vs bass|no-kick 0.20-0.23) — the evaluator's
  kick-alignment house rule now has a corpus magnitude.
- **Bass does NOT fill drum silence** (0.05-0.08) — it locks, it doesn't
  complement. A "play where drums don't" heuristic would be corpus-wrong.
- **Densities move together** (+0.23 jazz, +0.34 electronic) — bass thickens
  WITH drums.

Game side: style profiles gain an `interaction` role section (provenance +
confidence, absent-not-fabricated); `StylePrior.score_bass` gains
**coupling_fit** — per-onset log-likelihood of P(bass | kick at this step)
vs the corpus marginal, conditioned on the observation's ACTUAL kick_steps,
soft-manifold capped like every dimension. The style prior finally answers
"is this jazz-shaped against THESE drums?" instead of scoring bass in a
vacuum. Interaction provenance (source, n_pairs) rides in every decision log.

Validation: **439 unit tests green** (+5: same-line-different-kicks coupling
direction, manifold caps, dimension absent without data, committed-profile
interaction presence, provenance logging). **6/6 integration green.**

## V2 bass lanes — the full diatonic ladder, experiment pre-registered (2026-08-17)

The bass ring grows 5 → 8 lanes: lane d = chord root + d SCALE STEPS
(R 2 3 4 5 6 7, all diatonic — the key decides color), lane 7 = octave.
Corpus justification: 26% of real jazz bass is exactly the 2/4/6 color
classes V1 could not express.

**Pre-registered experiment first** (docs/design/v2-lanes-experiment.md +
tools/corpus/v2_metrics.py, both written BEFORE the vocabulary code):
success is SELECTIVE color in corpus-supported contexts with no rise in
revert rate — never "uses 2/4/6 often". Held fixed: candidate generator
logic (no 2/4/6-specific candidates — color enters only through the existing
retune/recolor tone pool; the style prior's measured x2/x4/x6 distributions
decide when it wins), profiles, weights, intent policy.

Migration notes:
- `chord_tone_midi` tones 0..6 are now STEPWISE (+d scale steps), 7 = octave;
  the octave invariant moved to tone 7 and still holds for every degree.
- **Frozen baseline preserved by boundary translation**: RuleBassPolicy v2
  thinks in its original 5-tone space and remaps at the edges
  (0/2/4/6/7 on the wire; removals emit the exact stored degree — the lossy
  round trip cannot, pinned by test "never emits color lanes").
- features_schema 3 (8 lane fractions, entropy over 8), observation_schema 5;
  pattern bank migrated to V2 lane space (bank_schema 2); harvest remaps
  pre-V2 logs by observation_schema; style prior LANE_TOKEN maps color lanes
  onto the corpus x2/x4/x6 tokens; JamAnalysis TONE_TENSION has 8 entries
  (4 tension-sensitive 0.55 — it rubs the third — 2 smooth 0.35, 6 color 0.4).
- UI: 8 ring lanes, keys 1-8, 8-option radial bloom, color lanes drawn
  muted-warm so structure vs color reads at a glance.

Validation: **527 unit tests green** (+82 net: the 8-lane V|vi|IV sounding
table, octave invariant at tone 7, chord-tones-outrank-color degree fit,
all-color-finite, baseline-never-emits-color across 40 seeds, migrated
fixtures throughout). **6/6 integration green.** The experiment now runs on
ordinary duet sessions via v2_metrics.py.

## How to rebuild the extension

```
cd native
python -m SCons platform=windows target=template_debug arch=x86_64 -j8
```

Requires VS 2022 C++ tools + `pip install scons`. godot-cpp is a shallow clone of
`godot-4.5-stable` (compatible with the 4.6 runtime, `compatibility_minimum = 4.5`).
