class_name Agent
extends RefCounted
## Runtime representation of one inhabitant of the district.
##
## An Agent is the live, mutable counterpart to a static NpcDB definition: it holds the
## NPC's current position, intent, in-progress action, short-term memory and plan. In
## later plans an LLM decides each agent's actions per beat; until then `tick_fallback`
## gives cheap deterministic behaviour by walking the agent toward its scheduled
## waypoint. Agents round-trip through to_dict()/from_dict() so the AgentRegistry can
## persist the whole cast in a save file.

var id: String = ""
var display_name: String = ""
var faction: String = "civilian"
var role: String = ""
var intent: String = ""
var position: Vector2 = Vector2.ZERO
var current_action: Dictionary = {}
var short_memory: Array = []
var plan: Array = []

func _init(agent_id: String = "") -> void:
	id = agent_id

func tick_fallback(phase: String, speed: float) -> void:
	# Resolve the NpcDB autoload via the engine singleton table rather than the bare
	# global identifier: when this class_name script is compiled as a dependency of the
	# headless `-s` test runner, autoload globals aren't registered yet, so a bare
	# `NpcDB` reference fails to compile. The singleton lookup is ordering-independent.
	var npc_db: Object = (Engine.get_main_loop() as SceneTree).root.get_node("/root/NpcDB")
	var target: Vector2 = npc_db.waypoint_for(id, phase)
	if target == Vector2.ZERO and position == Vector2.ZERO:
		return
	var to_target: Vector2 = target - position
	var dist: float = to_target.length()
	if dist <= speed or dist == 0.0:
		position = target
	else:
		position += to_target / dist * speed

func distance_to(p: Vector2) -> float:
	return position.distance_to(p)

func remember(entry: String, cap: int = 20) -> void:
	short_memory.append(entry)
	if short_memory.size() > cap:
		short_memory = short_memory.slice(short_memory.size() - cap)

func to_dict() -> Dictionary:
	return {
		"id": id,
		"display_name": display_name,
		"faction": faction,
		"role": role,
		"intent": intent,
		"position": [position.x, position.y],
		"current_action": current_action.duplicate(true),
		"short_memory": short_memory.duplicate(),
		"plan": plan.duplicate(true),
	}

func from_dict(d: Dictionary) -> void:
	id = String(d.get("id", id))
	display_name = String(d.get("display_name", display_name))
	faction = String(d.get("faction", faction))
	role = String(d.get("role", role))
	intent = String(d.get("intent", intent))
	var p: Variant = d.get("position", [0, 0])
	if typeof(p) == TYPE_ARRAY and (p as Array).size() >= 2:
		position = Vector2(float(p[0]), float(p[1]))
	current_action = (d.get("current_action", {}) as Dictionary).duplicate(true)
	short_memory = (d.get("short_memory", []) as Array).duplicate()
	plan = (d.get("plan", []) as Array).duplicate(true)
