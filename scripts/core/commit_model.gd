class_name JamCommitModel
extends RefCounted

# Active/pending commit model, ported from Jammin's FJamDrumCommitModel (D1) and made
# generic: works for any track object exposing clone() and equals(other). Rules:
#   * edits mutate only a pending snapshot; the active track keeps playing untouched;
#   * the first edit in loop N schedules the commit for loop N+1 (later edits coalesce);
#   * at the boundary, a genuinely changed pending is promoted (version bumped, previous
#     active archived); an unchanged pending is dropped with no version;
#   * version history is capped at MAX_VERSIONS.

const MAX_VERSIONS := 4

var active
var pending = null
var commit_loop_index: int = -1
var version_history: Array = [] # { version_id: int, track, created_at_loop: int }
var version_id: int = 0


func _init(initial) -> void:
	active = initial


func has_pending() -> bool:
	return pending != null


## Open (or continue) an edit session during current_loop; returns the pending track to mutate.
func begin_or_get_pending(current_loop: int):
	if pending == null:
		pending = active.clone()
		commit_loop_index = current_loop + 1
	return pending


func cancel_pending() -> void:
	pending = null
	commit_loop_index = -1


## Promote pending to active if current_loop has reached the scheduled commit loop.
## Returns true only when a real change was committed.
func try_commit_at_loop(current_loop: int) -> bool:
	if pending == null or current_loop < commit_loop_index:
		return false
	if pending.equals(active):
		cancel_pending()
		return false
	version_history.append({
		"version_id": version_id,
		"track": active,
		"created_at_loop": current_loop,
	})
	while version_history.size() > MAX_VERSIONS:
		version_history.remove_at(0)
	version_id += 1
	active = pending
	cancel_pending()
	return true
