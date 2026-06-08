extends Node
## Drives one deliberation beat (autoload `AgentRuntime`). On each `Clock.beat_ticked` it:
##   1. selects ACTIVE agents (near the player or explicitly flagged),
##   2. builds a perception snapshot for each and asks the SidecarBridge for proposals,
##   3. validates each proposal against ActionSchema,
##   4. commits the approved verb via ActionCommit and logs it to the EventBus,
##   5. runs schedule fallback for every INACTIVE agent so the world keeps moving.
## A rejected proposal falls the agent back to its schedule (the critic plan refines this
## into the approve/reroll/veto/amend verdict set). The overseer plan inserts its review
## between steps 3 and 4.

@export var auto_run: bool = true
var player_position: Vector2 = Vector2(440, 300)
var active_radius: float = 240.0
var always_active: Dictionary = {}   # agent_id -> true

func _ready() -> void:
	Clock.beat_ticked.connect(_on_beat)

func _on_beat(_beat_index: int, _day: int) -> void:
	if auto_run:
		run_beat()

func run_beat() -> void:
	var active: Array = _active_agents()
	var active_ids: Dictionary = {}
	for a in active:
		active_ids[a.id] = true

	if not active.is_empty():
		var snaps: Array = []
		for a in active:
			snaps.append(Perception.build_snapshot(a, player_position))
		var proposals: Array = SidecarBridge.propose(snaps)
		for i in active.size():
			var proposal: Variant = proposals[i] if i < proposals.size() else null
			_resolve_proposal(active[i], proposal)

	# Inactive agents keep to their schedule so nothing stalls.
	for a in Agents.all():
		if not active_ids.has(a.id):
			a.tick_fallback(Clock.phase, Agents.fallback_speed)

func _active_agents() -> Array:
	var out: Array = []
	for a in Agents.all():
		if always_active.has(a.id) or a.position.distance_to(player_position) <= active_radius:
			out.append(a)
	return out

func _resolve_proposal(agent: Agent, proposal: Variant) -> void:
	if typeof(proposal) != TYPE_DICTIONARY:
		agent.tick_fallback(Clock.phase, Agents.fallback_speed)
		return
	var action: Dictionary = proposal
	var verdict: Dictionary = ActionSchema.validate(action)
	if not verdict["ok"]:
		EventBus.emit_event("action_rejected", {
			"actor": agent.id, "verb": String(action.get("verb", "")), "reason": verdict["reason"],
		})
		agent.tick_fallback(Clock.phase, Agents.fallback_speed)
		return
	var outcome: Dictionary = ActionCommit.commit(action, agent)
	EventBus.emit_event("agent_action", {
		"actor": agent.id, "verb": String(action["verb"]), "args": action.get("args", {}), "outcome": outcome,
	})
