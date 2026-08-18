class_name JamStylePrior
extends RefCounted

# Phase 3E: corpus-derived style profiles as a SCORING PRIOR over the 3C
# candidate set — style biases among reasonable responses, it never generates
# notes, never alters candidates, and never overrides interaction.
#
# Scoring rules (each one is a pinned invariant):
# - Per-EVENT normalization: sparse and dense candidates compare fairly.
# - Laplace smoothing everywhere: a zero-count transition in 53k notes means
#   "rare", never -inf/auto-reject.
# - SOFT MANIFOLD, not mode-seeking: each dimension's fit is the mean
#   log-probability in nats ABOVE CHANCE, capped at CAP_TYPICAL — "reasonably
#   jazz-like" earns full credit, "extremely corpus-common" earns no extra
#   (common != good; R R R R must not win on typicality), "very atypical" is
#   penalized down to FLOOR.
# - Missing profile data contributes EXACTLY zero — no generic substitute
#   quietly masquerading as a style.
# - Dimensions stay separate in the log (degree/beat/interval/transition fit)
#   and are combined only at the end, so a weird choice is inspectable.

const Harmony := preload("res://scripts/core/harmony.gd")

const STYLE_SCHEMA := 1
const CAP_TYPICAL := 0.6 # nats above chance where extra typicality stops paying
const FLOOR := -2.0
const BASS_ROOT_MIDI := 36

# V1 lane -> corpus tone token (FiloBass folds octave roots into R).
const LANE_TOKEN := ["R", "3", "5", "7", "R"]
const TOKENS := ["R", "3", "5", "7", "x2", "x4", "x6"]

const CONFIDENCE_FACTOR := {"HIGH": 1.0, "MEDIUM": 0.6, "LOW": 0.3}


static var _profiles := {} # path -> parsed profile or null (cached misses too)


## Load a committed profile (res:// path) — cached, deterministic, null on miss.
static func load_profile(path: String):
	if not _profiles.has(path):
		var text := FileAccess.get_file_as_string(path)
		_profiles[path] = JSON.parse_string(text) if text != "" else null
	return _profiles[path]


## Per-dimension style fits for a candidate bass line under a bass profile
## section. kick_steps + interaction add the drum-CONDITIONED dimension: a
## candidate is style-shaped AGAINST THE CURRENT DRUMS, not in a vacuum.
## Returns null when profile/notes give nothing to score (missing data
## contributes zero — the caller treats null as no style term).
static func score_bass(bass_profile: Dictionary, notes: Dictionary, chord_slots: Array,
		kick_steps: Array = [], interaction = null):
	if notes.is_empty() or bass_profile.is_empty():
		return null
	var steps := notes.keys()
	steps.sort()

	# degree_fit: candidate tones vs the corpus tone distribution.
	var tone_counts: Dictionary = bass_profile.get("tone_distribution", {})
	var tone_total := 0.0
	for t in TOKENS:
		tone_total += float(tone_counts.get(t, 0))
	var degree_lp := 0.0
	for s in steps:
		var tok: String = LANE_TOKEN[clampi(int(notes[s]), 0, 4)]
		degree_lp += log((float(tone_counts.get(tok, 0)) + 1.0) / (tone_total + TOKENS.size()))
	var degree_fit := _fit(degree_lp / steps.size(), log(1.0 / TOKENS.size()))

	# beat_position_fit: onset placement vs the corpus step distribution.
	var step_dist: Array = bass_profile.get("onset_step_distribution", [])
	var beat_fit = null
	if step_dist.size() == 16:
		var step_total := 0.0
		for c in step_dist:
			step_total += float(c)
		var lp := 0.0
		for s in steps:
			lp += log((float(step_dist[int(s)]) + 1.0) / (step_total + 16.0))
		beat_fit = _fit(lp / steps.size(), log(1.0 / 16.0))

	# interval_fit: sounding melodic motion (virtually rendered over the
	# progression, same resolver as the game) vs the corpus interval histogram.
	var ihist: Array = bass_profile.get("interval_distribution", [])
	var interval_fit = null
	if ihist.size() == 13 and steps.size() >= 1 and not chord_slots.is_empty():
		var midis: Array = []
		for bar in chord_slots.size():
			for s in steps:
				midis.append(Harmony.chord_tone_midi(BASS_ROOT_MIDI, int(chord_slots[bar]), int(notes[s])))
		if midis.size() >= 2:
			var itotal := 0.0
			for c in ihist:
				itotal += float(c)
			var lp2 := 0.0
			for i in range(1, midis.size()):
				var iv := mini(12, absi(int(midis[i]) - int(midis[i - 1])))
				lp2 += log((float(ihist[iv]) + 1.0) / (itotal + 13.0))
			interval_fit = _fit(lp2 / (midis.size() - 1), log(1.0 / 13.0))

	# transition_fit: consecutive tone tokens vs the corpus transition rows.
	var trans: Dictionary = bass_profile.get("tone_transition_counts", {})
	var transition_fit = null
	if steps.size() >= 2 and not trans.is_empty():
		var lp3 := 0.0
		for i in range(1, steps.size()):
			var a: String = LANE_TOKEN[clampi(int(notes[steps[i - 1]]), 0, 4)]
			var b: String = LANE_TOKEN[clampi(int(notes[steps[i]]), 0, 4)]
			var row: Dictionary = trans.get(a, {})
			var row_total := 0.0
			for t in TOKENS:
				row_total += float(row.get(t, 0))
			lp3 += log((float(row.get(b, 0)) + 1.0) / (row_total + TOKENS.size()))
		transition_fit = _fit(lp3 / (steps.size() - 1), log(1.0 / TOKENS.size()))

	# coupling_fit: onset likelihood conditioned on the CURRENT kick pattern
	# vs the corpus marginal — measured drums↔bass interaction, never opinion.
	var coupling_fit = null
	if interaction != null and interaction is Dictionary and interaction.has("bass_given_kick"):
		var r_k := clampf(float(interaction.bass_given_kick), 0.001, 0.999)
		var r_n := clampf(float(interaction.bass_given_nokick), 0.001, 0.999)
		var marginal := clampf(float(interaction.get("bass_marginal",
			(r_k + r_n) / 2.0)), 0.001, 0.999)
		var kickset := {}
		for s in kick_steps:
			kickset[int(s)] = true
		var lp4 := 0.0
		for s in steps:
			lp4 += log((r_k if kickset.has(int(s)) else r_n) / marginal)
		coupling_fit = _fit(lp4 / steps.size(), 0.0)

	var dims := {"degree_fit": degree_fit}
	if beat_fit != null:
		dims["beat_position_fit"] = beat_fit
	if interval_fit != null:
		dims["interval_fit"] = interval_fit
	if transition_fit != null:
		dims["transition_fit"] = transition_fit
	if coupling_fit != null:
		dims["coupling_fit"] = coupling_fit
	var combined := 0.0
	for k in dims:
		combined += dims[k]
	dims["combined"] = combined / (dims.size())
	return dims


## Soft manifold: mean log-prob relative to chance, capped above, floored below.
static func _fit(mean_lp: float, chance_lp: float) -> float:
	return clampf(mean_lp - chance_lp, FLOOR, CAP_TYPICAL)
