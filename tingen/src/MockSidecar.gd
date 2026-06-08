class_name MockSidecar
extends SidecarClient
## Deterministic test/offline sidecar. Returns a scripted action per actor; agents with
## no script idle. A scripted value may be a single action dict (returned every beat) or
## an Array used as a queue (one popped per beat, idle when empty). Lets headless tests
## drive exact agent behavior with no LLM.

var scripted: Dictionary = {}   # actor_id -> action dict OR Array[action dict]

func set_action(actor_id: String, action: Variant) -> void:
	scripted[actor_id] = action

func clear() -> void:
	scripted.clear()

func propose(snapshots: Array) -> Array:
	var out: Array = []
	for s in snapshots:
		var actor := String((s as Dictionary).get("agent_id", ""))
		out.append(_next_for(actor))
	return out

func _next_for(actor: String) -> Dictionary:
	if not scripted.has(actor):
		return _idle(actor)
	var v: Variant = scripted[actor]
	if typeof(v) == TYPE_ARRAY:
		var q: Array = v
		if q.is_empty():
			return _idle(actor)
		return (q.pop_front() as Dictionary).duplicate(true)
	return (v as Dictionary).duplicate(true)

func _idle(actor: String) -> Dictionary:
	return {"actor": actor, "verb": "idle", "args": {}}
