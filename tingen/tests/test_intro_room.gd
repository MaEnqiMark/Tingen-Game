extends SceneTree
## Headless wiring check for the Klein's-bedroom Y-sorted depth build. Instances IntroRoom
## and asserts: the empty klein_floor is the Floor sprite, the root is Y-sorted, the rug +
## blood decals are present, the 9 bespoke klein furniture props are placed as non-solid
## (collision stays on the Solids StaticBody2D), the player + interactable art is wired, and
## the clue/door logic is intact. Visual occlusion itself is checked by eye in the playtest.
## Run:  <godot> --headless --path tingen -s tests/test_intro_room.gd

var _passed := 0
var _failed := 0

const FURNITURE := {
	"Bed": "klein_bed.png", "Desk": "klein_desk.png", "Chair": "klein_chair.png",
	"Bookshelf": "klein_bookshelf.png", "Nightstand1": "klein_nightstand.png",
	"Nightstand2": "klein_nightstand.png", "Wardrobe": "klein_wardrobe.png",
	"Dresser": "klein_dresser.png", "Chest": "klein_chest.png",
}

func _init() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/IntroRoom.tscn")
	var room: Node = packed.instantiate()
	root.add_child(room)
	await process_frame
	await process_frame

	# Root Y-sort drives all depth.
	_ok(room.get("y_sort_enabled") == true, "IntroRoom root is Y-sorted")

	# Empty room floor (furniture/blood/rug removed) is a flat Sprite2D, not the furnished photo.
	var floor: Sprite2D = room.get_node_or_null("Floor")
	_ok(floor != null and floor.texture != null
		and floor.texture.resource_path.ends_with("klein_floor.png"),
		"Floor -> klein_floor.png")

	# Floor decals restore what was painted into klein_room.png.
	_check_sprite(room, "Rug", "klein_rug.png")
	_check_sprite(room, "BloodPool", "blood_pool_0.png")

	# Collision stays on the hand-authored Solids boxes (walls + furniture).
	var solids: Node = room.get_node_or_null("Solids")
	_ok(solids is StaticBody2D, "Solids is a StaticBody2D")
	var shape_count := 0
	if solids:
		for c in solids.get_children():
			if c is CollisionShape2D and c.shape != null:
				shape_count += 1
	_ok(shape_count >= 10, "Solids has >=10 collision shapes (got %d)" % shape_count)

	# The 9 bespoke furniture props: present, art wired, and non-solid (Solids owns collision).
	for node_name in FURNITURE:
		var p: Node = room.get_node_or_null(node_name)
		var tex: Texture2D = p.get("icon") if p != null else null
		_ok(p != null and tex != null and tex.resource_path.ends_with(FURNITURE[node_name]),
			"%s prop -> %s" % [node_name, FURNITURE[node_name]])
		_ok(p != null and p.get("solid") == false,
			"%s is non-solid (collision via Solids)" % node_name)

	# Player art (bespoke 4-way Klein; asset owned elsewhere — just verify wiring).
	var psprite: Sprite2D = room.get_node_or_null("Player/Sprite2D")
	_ok(psprite != null and psprite.texture != null
		and psprite.texture.resource_path.ends_with("klein_down.png"),
		"Player sprite -> klein_down.png")
	_ok(room.get_node_or_null("RoomCam") is Camera2D, "RoomCam is a Camera2D")

	# Interactables: real art on all four.
	_check_icon(room, "Notebook", "antigonus_notebook_0.png")
	_check_icon(room, "Gun", "revolver_0.png")
	_check_icon(room, "Mirror", "cracked_mirror_0.png")
	_check_icon(room, "Door", "door_wood_0.png")

	# Interactable logic intact: clue ids + door target unchanged by the art upgrade.
	_check_clue(room, "Notebook", "antigonus_notebook")
	_check_clue(room, "Gun", "spent_revolver")
	_check_clue(room, "Mirror", "wrong_reflection")
	var door: Node = room.get_node_or_null("Door")
	_ok(door != null and door.get("target_scene") == "res://scenes/City.tscn",
		"Door -> City.tscn")

	print("\n=== %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)

func _check_sprite(room: Node, node_name: String, expect_suffix: String) -> void:
	var s: Sprite2D = room.get_node_or_null(node_name)
	_ok(s != null and s.texture != null and s.texture.resource_path.ends_with(expect_suffix),
		"%s -> %s" % [node_name, expect_suffix])

func _check_icon(room: Node, node_name: String, expect_suffix: String) -> void:
	var spr: Sprite2D = room.get_node_or_null("%s/Sprite2D" % node_name)
	var ok := spr != null and spr.texture != null and spr.texture.resource_path.ends_with(expect_suffix)
	_ok(ok, "%s sprite -> %s" % [node_name, expect_suffix])

func _check_clue(room: Node, node_name: String, expect_clue: String) -> void:
	var n: Node = room.get_node_or_null(node_name)
	_ok(n != null and n.get("clue_id") == expect_clue,
		"%s clue_id == %s" % [node_name, expect_clue])

func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  PASS  %s" % label)
	else:
		_failed += 1
		printerr("  FAIL  %s" % label)
