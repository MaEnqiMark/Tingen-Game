extends CharacterBody2D
## Top-down protagonist. 8-direction movement; the child Camera2D follows
## automatically. Movement is frozen while a dialogue is open.

@export var speed: float = 120.0

func _physics_process(_delta: float) -> void:
	if DialogueManager.active:
		velocity = Vector2.ZERO
		return
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = direction * speed
	move_and_slide()
