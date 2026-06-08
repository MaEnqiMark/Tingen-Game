extends CharacterBody2D
## Stub NPC agent (GDD §15 / §22.3). Reads its definition + phase schedule from NpcDB,
## re-targets its waypoint on Clock.phase_changed, and straight-line steers toward it.
## Pathfinding is intentionally simple (move_and_slide with wall sliding) — the
## schedule logic is the art-agnostic part; a real navmesh/A* is later polish.
##
## If its definition has a dialogue_id, the player can talk to it (E when near).

@export var npc_id: String = ""
@export var move_speed: float = 60.0
@export var arrive_radius: float = 8.0

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _name_label: Label = $Name
@onready var _prompt: Label = $TalkArea/Prompt

var _def: Dictionary = {}
var _target: Vector2
var _player_near: bool = false
var _agent = null   # bound Agent (from the registry) or null = schedule fallback

func _ready() -> void:
	_def = NpcDB.get_def(npc_id)
	if _def.is_empty():
		push_warning("NPC: no def for '%s'" % npc_id)
	var tint: Array = _def.get("tint", [1, 1, 1])
	if tint.size() >= 3:
		_sprite.modulate = Color(tint[0], tint[1], tint[2])
	_name_label.text = String(_def.get("name", npc_id))
	_prompt.visible = false
	_prompt.text = "Talk"
	_target = global_position
	if Clock.phase != "":
		_retarget(Clock.phase)
	Clock.phase_changed.connect(func(p, _d): _retarget(p))
	var area: Area2D = $TalkArea
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)
	_agent = Agents.get_agent(npc_id)

## True when this node is the rendered body of a live registry Agent.
func is_bound() -> bool:
	return _agent != null

## Where the node should walk this frame: its Agent's beat-driven position when bound,
## otherwise its scheduled waypoint.
func steer_goal() -> Vector2:
	return _agent.position if _agent != null else _target

func _retarget(phase: String) -> void:
	var wp := NpcDB.waypoint_for(npc_id, phase)
	if wp != Vector2.ZERO:
		_target = wp

func _physics_process(_delta: float) -> void:
	if DialogueManager.active:
		velocity = Vector2.ZERO
		return
	var to_target := steer_goal() - global_position
	if to_target.length() <= arrive_radius:
		velocity = Vector2.ZERO
	else:
		velocity = to_target.normalized() * move_speed
		move_and_slide()

func _on_body_entered(body: Node) -> void:
	if body.is_in_group("player") and _can_talk():
		_player_near = true
		_prompt.visible = true

func _on_body_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_player_near = false
		_prompt.visible = false

func _can_talk() -> bool:
	return String(_def.get("dialogue_id", "")) != ""

func _unhandled_input(event: InputEvent) -> void:
	if not _player_near or not _can_talk():
		return
	if event.is_action_pressed("interact"):
		DialogueManager.start(String(_def["dialogue_id"]))
		get_viewport().set_input_as_handled()
