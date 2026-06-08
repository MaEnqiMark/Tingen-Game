extends Node2D
## The live district. The agent-sim brain visibly drives the cast here: one rendered NPC
## per registry Agent (data-driven, not hand-placed), each bound by id so it follows its
## Agent's beat-driven position. Pushes the real player's position into AgentRuntime every
## frame so "active agents near the player" tracks what is on screen, and presents the
## summoning climax when SummoningPlan's countdown hits zero.

const NPC_SCENE: PackedScene = preload("res://scenes/NPC.tscn")
const PLAYER_SCENE: PackedScene = preload("res://scenes/Player.tscn")

@export var player_start: Vector2 = Vector2(440, 300)

var _player: Node2D = null

func _ready() -> void:
	_spawn_player()
	_spawn_agents()
	if not SummoningPlan.summoning_climax.is_connected(_on_climax):
		SummoningPlan.summoning_climax.connect(_on_climax)

func _spawn_player() -> void:
	_player = PLAYER_SCENE.instantiate()
	add_child(_player)
	_player.global_position = player_start
	AgentRuntime.player_position = player_start

func _spawn_agents() -> void:
	for a in Agents.all():
		var npc: Node2D = NPC_SCENE.instantiate()
		npc.npc_id = a.id
		add_child(npc)
		npc.global_position = a.position

func _process(_delta: float) -> void:
	if is_instance_valid(_player):
		AgentRuntime.player_position = _player.global_position

## Headless-real climax: resolve the fight deterministically and surface the result. The
## animated, interactive fight is a later polish; the resolution math is real now.
func _on_climax(strength: float) -> void:
	var fight := CombatEncounter.new(strength)
	var result: Dictionary = fight.auto_resolve()
	var verdict := "You hold the line." if result["win"] else "The descent takes you."
	WorldState.thought_requested.emit("The summoning breaks over Tingen. %s (%d HP left, %d rounds)" % [
		verdict, int(result["player_hp_left"]), int(result["rounds"])])
	EventBus.emit_event("combat_resolved", result)
