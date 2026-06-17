extends CharacterBody2D
## Top-down protagonist. 8-direction movement; the child Camera2D follows
## automatically. Movement is frozen while a dialogue is open. The sprite swaps
## among four directional textures (down/left/right/up) to face the way it moves.
## Double-tapping "up" (W) engages a sprint (faster movement) that drains a stamina
## pool; stamina regenerates while not sprinting, and once drained to empty must
## recover past sprint_recharge_threshold before sprint can re-engage.

@export var speed: float = 120.0
@export var sprint_multiplier: float = 1.8
## Stamina pool (0..max_stamina). Sprinting drains it; it regenerates otherwise.
@export var max_stamina: float = 100.0
@export var stamina_drain: float = 30.0          # per second while sprinting
@export var stamina_regen: float = 45.0          # per second while not sprinting
## After draining to empty, stamina must recover to this before sprint re-engages.
@export var sprint_recharge_threshold: float = 20.0
## Max seconds between two "up" taps to engage a sprint.
@export var double_tap_window: float = 0.28

var stamina: float = max_stamina

const _TEX := {
	"down": preload("res://assets/characters/klein_down.png"),
	"left": preload("res://assets/characters/klein_left.png"),
	"right": preload("res://assets/characters/klein_right.png"),
	"up": preload("res://assets/characters/klein_up.png"),
}

@onready var _sprite: Sprite2D = $Sprite2D
var _facing: String = "down"
var _last_up_tap: float = -1000.0
var _sprinting: bool = false
var _exhausted: bool = false

func _ready() -> void:
	stamina = max_stamina
	_sprite.texture = _TEX[_facing]

func _physics_process(delta: float) -> void:
	if DialogueManager.active:
		velocity = Vector2.ZERO
		step_stamina(delta, false)  # recover while a conversation holds you still
		return
	# Double-tap "up" (W) within the window engages sprint, unless exhausted.
	if Input.is_action_just_pressed("move_up"):
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_up_tap <= double_tap_window and not _exhausted:
			_sprinting = true
		_last_up_tap = now
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var sprinting := _resolve_sprint(direction)
	step_stamina(delta, sprinting)
	velocity = direction * (speed * sprint_multiplier if sprinting else speed)
	move_and_slide()
	_face(direction)

## Sprint holds only while armed, actually moving, and not exhausted. Hitting empty sets
## the exhausted latch (cleared once stamina recovers past sprint_recharge_threshold), so a
## drained player cannot stutter-sprint. Returns whether this frame is a sprint.
func _resolve_sprint(direction: Vector2) -> bool:
	if stamina <= 0.0:
		_exhausted = true
	elif stamina >= sprint_recharge_threshold:
		_exhausted = false
	if _sprinting and (direction == Vector2.ZERO or _exhausted):
		_sprinting = false
	return _sprinting

## Advance stamina one frame: drain while sprinting, regenerate otherwise; clamp to
## [0, max_stamina]. Pure (no Input/tree) so it is unit-testable headless.
func step_stamina(delta: float, sprinting: bool) -> void:
	if sprinting:
		stamina = maxf(0.0, stamina - stamina_drain * delta)
	else:
		stamina = minf(max_stamina, stamina + stamina_regen * delta)

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
