class_name JamDecisionLog
extends RefCounted

# Phase 1A: decision-window logging. The dataset priority is capturing DECISION
# OPPORTUNITIES, not just edits — a window where the player looked and chose to
# do nothing is training data (otherwise a learned player inherits pathological
# busyness). Frames from different sources (HUMAN / RULE_BOT / ML_BOT) must stay
# distinguishable forever: a model that "wins" by cloning the rule bot is a bug.
#
# Append-only JSONL, one event per line:
#   {"type":"session", ...}   file header: schema/session metadata
#   {"type":"decision", ...}  one editable-window decision (ops may be [])
#   {"type":"commit", ...}    later resolution of a decision key (state after commit)
# Decisions and commits join on decision_key — commits land loops after the
# decision, so the stream records them as separate events rather than mutating
# a written line.

const SCHEMA_VERSION := 1

const SOURCE_HUMAN := "human"
const SOURCE_RULE_BOT := "rule_bot"
const SOURCE_ML_BOT := "ml_bot"

const DEFAULT_DIR := "user://decision_logs"


# ---------------------------------------------------------------- identity

## One decision per DecisionKey, ever — the BotPeer watermark (Phase 1B) and the
## idempotence rule are both defined over this tuple, not a bare loop integer,
## so reconnects/resets (epoch bump) and role handoffs can't alias decisions.
static func make_key(room_epoch: int, role: int, target_loop: int, state_version: int) -> Dictionary:
	return {
		"room_epoch": room_epoch,
		"role": role,
		"target_loop": target_loop,
		"state_version": state_version,
	}


## Per-decision RNG seed derived from the session seed and the DecisionKey
## (state_version excluded: a re-decision after new state should still be the
## same "roll" for the same window). Same state + same session seed -> same ops
## by construction; policies get no other randomness source. splitmix64-style
## integer mixing — explicitly NOT GDScript hash(), whose value is not
## guaranteed stable across engine versions.
static func derive_seed(session_seed: int, room_epoch: int, role: int, target_loop: int) -> int:
	var z := session_seed
	for component in [room_epoch, role, target_loop]:
		z = _mix64(z + -0x61C8864680B583EB + component) # 0x9E3779B97F4A7C15 as signed 64-bit
	return z


static func _mix64(z: int) -> int:
	z = (z ^ (z >> 30)) * -0x40A7B892E31B1A47 # 0xBF58476D1CE4E5B9 as signed 64-bit
	z = (z ^ (z >> 27)) * -0x6B2FB644ECCEEE15 # 0x94D049BB133111EB as signed 64-bit
	return z ^ (z >> 31)


# ---------------------------------------------------------------- frames

## A decision-window frame. ops == [] is a deliberate HOLD, not a gap. Fields
## that only exist later (accepted/rejected split, analysis) stay present but
## null/empty so schema v1 consumers never key-check.
static func build_frame(key: Dictionary, source: String, policy_name: String, policy_version: int,
		rng_seed: int, observation: Dictionary, ops: Array,
		decision_started_usec: int, decision_submitted_usec: int,
		deadline_margin_steps: float, analysis = null, extra: Dictionary = {}) -> Dictionary:
	var frame := {
		"type": "decision",
		"schema_version": SCHEMA_VERSION,
		"decision_key": key,
		"source": source,
		"policy_name": policy_name,
		"policy_version": policy_version,
		# As a STRING: seeds use all 64 bits and JSON numbers are doubles — a
		# numeric seed would lose low bits on read-back and break replay.
		"rng_seed": str(rng_seed),
		"observation": observation,
		"ops": ops,
		"result": "hold" if ops.is_empty() else "edit",
		"accepted_ops": null, # joined later from server echo (needs op sequence IDs)
		"rejected_ops": null,
		"analysis": analysis, # JamFeatures measurements of the observed state
		"decision_started_usec": decision_started_usec,
		"decision_submitted_usec": decision_submitted_usec,
		"deadline_margin_steps": deadline_margin_steps,
	}
	frame.merge(extra) # attention proxies, latency notes, etc.
	return frame


## Resolution event: what the commit model actually promoted for this window.
static func build_commit(key: Dictionary, committed_state: Dictionary, committed_version: int, at_loop: int) -> Dictionary:
	return {
		"type": "commit",
		"schema_version": SCHEMA_VERSION,
		"decision_key": key,
		"committed_state": committed_state,
		"committed_version": committed_version,
		"at_loop": at_loop,
	}


# ---------------------------------------------------------------- writer

var _file: FileAccess
var path := ""


## session_meta should carry at least: session_id, session_seed, room_epoch,
## peer_id. Written as the file's header line; the game revision and engine
## version are stamped automatically — a frame is only interpretable if you
## know which build produced it.
func open(session_meta: Dictionary, dir: String = DEFAULT_DIR) -> Error:
	DirAccess.make_dir_recursive_absolute(dir)
	path = "%s/%s.jsonl" % [dir, session_meta.get("session_id", "session")]
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		return FileAccess.get_open_error()
	var header := {
		"type": "session",
		"schema_version": SCHEMA_VERSION,
		"game_revision": game_revision(),
		"engine_version": Engine.get_version_info()["string"],
	}
	header.merge(session_meta)
	write(header)
	return OK


## Best-effort git HEAD of the running project (dev runs only; exported builds
## have no .git and report "unknown").
static func game_revision() -> String:
	var head := FileAccess.get_file_as_string("res://.git/HEAD").strip_edges()
	if head.begins_with("ref: "):
		var ref := FileAccess.get_file_as_string("res://.git/" + head.trim_prefix("ref: ")).strip_edges()
		return ref.substr(0, 12) if not ref.is_empty() else "unknown"
	return head.substr(0, 12) if not head.is_empty() else "unknown"


## Append any event dict as one JSONL line, flushed immediately — a crashed or
## killed session must not cost recorded human decisions.
func write(event: Dictionary) -> void:
	if _file == null:
		return
	_file.store_line(JSON.stringify(event))
	_file.flush()


func close() -> void:
	if _file != null:
		_file.close()
		_file = null


## Read a log back as an Array of event Dictionaries (test/analysis helper).
static func read_events(file_path: String) -> Array:
	var events: Array = []
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return events
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if parsed != null:
			events.append(parsed)
	return events
