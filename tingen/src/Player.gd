extends CharacterBody2D
## Top-down protagonist. 8-direction movement; the child Camera2D follows
## automatically. Movement is frozen while a dialogue is open. The sprite swaps
## among four directional textures (down/left/right/up) to face the way it moves.

@export var speed: float = 120.0

const _TEX := {
	"down": preload("res://assets/characters/klein_down.png"),
	"left": preload("res://assets/characters/klein_left.png"),
	"right": preload("res://assets/characters/klein_right.png"),
	"up": preload("res://assets/characters/klein_up.png"),
}

@onready var _sprite: Sprite2D = $Sprite2D
var _facing: String = "down"

func _ready() -> void:
	_sprite.texture = _TEX[_facing]

func _physics_process(_delta: float) -> void:
	if DialogueManager.active:
		velocity = Vector2.ZERO
		return
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = direction * speed
	move_and_slide()
	_face(direction)

## Pick the directional texture from the dominant movement axis; keep the last
## facing while idle so the player stays oriented where they stopped.
func _face(direction: Vector2) -> void:
	if direction == Vector2.ZERO:
		return
	var f := _facing
	if absf(direction.x) > absf(direction.y):
		f = "right" if direction.x > 0.0 else "left"
	else:
		f = "down" if direction.y > 0.0 else "up"
	if f != _facing:
		_facing = f
		_sprite.texture = _TEX[f]
