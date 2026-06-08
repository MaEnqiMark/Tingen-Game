extends SceneTree
## Headless wiring check for the Klein's-bedroom slice. Instances IntroRoom and asserts the
## placeholder flats were replaced with real art (TileMapLayer floor, repointed player +
## interactable sprites, Y-sorted furniture). Logic (clues/door) is covered by run_tests.gd.
## Run:  <godot> --headless --path tingen -s tests/test_intro_room.gd

var _passed := 0
var _failed := 0

func _init() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/IntroRoom.tscn")
	var room: Node = packed.instantiate()
	root.add_child(room)
	await process_frame
	await process_frame

	_ok(room.get("y_sort_enabled") == true, "IntroRoom root is Y-sorted")
	_ok(room.get_node_or_null("Floor") is TileMapLayer, "Floor is a TileMapLayer")

	var psprite: Sprite2D = room.get_node_or_null("Player/Sprite2D")
	_ok(psprite != null and psprite.texture != null
		and psprite.texture.resource_path.ends_with("player_detective.png"),
		"Player sprite -> player_detective.png")

	_check_icon(room, "Notebook", "antigonus_notebook_0.png")
	_check_icon(room, "Gun", "revolver_0.png")
	_check_icon(room, "Mirror", "cracked_mirror_0.png")
	_check_icon(room, "Door", "door_wood_0.png")

	_ok(room.get_node_or_null("Bed") != null, "Bed prop present")
	_ok(room.get_node_or_null("Desk") != null, "Desk prop present")
	_ok(room.get_node_or_null("Bookshelf") != null, "Bookshelf prop present")

	print("\n=== %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)

func _check_icon(room: Node, node_name: String, expect_suffix: String) -> void:
	var spr: Sprite2D = room.get_node_or_null("%s/Sprite2D" % node_name)
	var ok := spr != null and spr.texture != null and spr.texture.resource_path.ends_with(expect_suffix)
	_ok(ok, "%s sprite -> %s" % [node_name, expect_suffix])

func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  PASS  %s" % label)
	else:
		_failed += 1
		printerr("  FAIL  %s" % label)
