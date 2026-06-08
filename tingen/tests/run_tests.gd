extends SceneTree
## Dependency-free headless test runner. Run with:
##   godot --headless --path tingen -s tests/run_tests.gd
##
## Exercises the data-driven systems that don't need a rendered scene: the clock's
## phase math, pressure clamping + stability, the world-manager stage machine and
## seeded slots, clue collection + topic unlock, event scoring, and a full
## save -> mutate -> load round-trip. Autoloads are available because they are
## registered in project.godot. Exits non-zero on any failure so CI can gate on it.

var _passed: int = 0
var _failed: int = 0

func _init() -> void:
	# Let autoloads finish their _ready before asserting against them.
	await process_frame
	await process_frame

	_test_clock_phases()
	_test_pressure_clamp_and_stability()
	_test_world_manager_stages()
	_test_seeded_slots_are_deterministic()
	_test_clue_collection()
	_test_event_scoring()
	_test_save_load_roundtrip()
	_test_clock_beats()
	_test_event_bus()
	_test_agent_fallback()
	_test_agent_registry()
	_test_cult_cell_seeded()
	_test_substrate_save_load()

	print("\n=== %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)

func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  PASS  %s" % label)
	else:
		_failed += 1
		printerr("  FAIL  %s" % label)

func _test_clock_phases() -> void:
	print("[clock]")
	var Clk: Object = root.get_node("/root/Clock")
	_ok(Clk.phase_for_minute(0) == "late-night", "00:00 -> late-night")
	_ok(Clk.phase_for_minute(360) == "early-morning", "06:00 -> early-morning")
	_ok(Clk.phase_for_minute(540) == "morning", "09:00 -> morning")
	_ok(Clk.phase_for_minute(780) == "afternoon", "13:00 -> afternoon")
	_ok(Clk.phase_for_minute(1080) == "dusk", "18:00 -> dusk")
	_ok(Clk.phase_for_minute(1200) == "night", "20:00 -> night")
	_ok(Clk.phase_for_minute(1439) == "late-night", "23:59 -> late-night")

func _test_pressure_clamp_and_stability() -> void:
	print("[pressures]")
	var WS: Object = root.get_node("/root/WorldState")
	WS.set_pressure(&"corruption", 200.0)
	_ok(WS.get_pressure(&"corruption") == 100.0, "clamps high to 100")
	WS.set_pressure(&"corruption", -50.0)
	_ok(WS.get_pressure(&"corruption") == 0.0, "clamps low to 0")
	WS.set_pressure(&"corruption", 0.0)
	WS.set_pressure(&"panic", 0.0)
	WS.set_pressure(&"cult_readiness", 0.0)
	_ok(abs(WS.stability() - 100.0) < 0.01, "all-zero -> stability 100")
	WS.set_pressure(&"corruption", 100.0)
	_ok(abs(WS.stability() - 50.0) < 0.01, "corruption 100 -> stability 50")

func _test_world_manager_stages() -> void:
	print("[world manager]")
	var WM: Object = root.get_node("/root/WorldManager")
	var WS: Object = root.get_node("/root/WorldState")
	WM.from_dict({"seed_value": 12345})  # reset bookkeeping deterministically
	WM.current_stage_id = "disturbance"
	WM.refresh_count = 0
	WS.set_pressure(&"cult_readiness", 100.0)
	WM.force_advance_stage()
	_ok(WM.current_stage_id == "awakening", "force_advance from disturbance -> awakening")
	var before: int = WM.stage_index()
	WM.force_advance_stage()
	_ok(int(WM.stage_index()) == before + 1, "force_advance increments stage index")

func _test_seeded_slots_are_deterministic() -> void:
	print("[slots]")
	var WM: Object = root.get_node("/root/WorldManager")
	WM.from_dict({"seed_value": 999})
	WM._start_run(false)
	var first: Dictionary = WM.slots.duplicate(true)
	WM.from_dict({"seed_value": 999})
	WM._start_run(false)
	_ok(WM.slots == first, "same seed -> identical slot resolution")
	_ok(WM.slots.has("primary_ritual_site"), "primary_ritual_site resolved at world-start")

func _test_clue_collection() -> void:
	print("[clues]")
	var CD: Object = root.get_node("/root/ClueDB")
	CD.from_dict({})  # clear
	var ok: bool = CD.collect("antigonus_notebook")
	_ok(ok, "collect known clue returns true")
	_ok(not CD.collect("antigonus_notebook"), "double-collect returns false")
	_ok(CD.collected_count() == 1, "collected_count == 1")
	_ok(CD.unlocked_topics().size() > 0, "collecting unlocked at least one topic")

func _test_event_scoring() -> void:
	print("[events]")
	var EM: Object = root.get_node("/root/EventManager")
	_ok(EM.library.size() > 0, "event library loaded")
	# An always-eligible event (no conditions) should be pickable on a fresh count.
	EM._cooldowns.clear()
	var pick: Dictionary = EM._pick(0)
	_ok(not pick.is_empty(), "picks an eligible event at refresh 0")

func _test_save_load_roundtrip() -> void:
	print("[save/load]")
	var WS: Object = root.get_node("/root/WorldState")
	var SM: Object = root.get_node("/root/SaveManager")
	var CD: Object = root.get_node("/root/ClueDB")
	WS.set_pressure(&"panic", 42.0)
	CD.from_dict({})
	CD.collect("spent_revolver")
	var tmp := "user://test_save.json"
	_ok(SM.save_game(tmp), "save_game writes file")
	WS.set_pressure(&"panic", 7.0)
	CD.from_dict({})
	_ok(SM.load_game(tmp), "load_game reads file")
	_ok(abs(WS.get_pressure(&"panic") - 42.0) < 0.01, "panic restored to 42")
	_ok(CD.is_collected("spent_revolver"), "clue restored after load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

func _test_clock_beats() -> void:
	print("[clock beats]")
	var Clk: Object = root.get_node("/root/Clock")
	Clk.minutes_per_beat = 15
	Clk.beat_index = 0
	Clk._beat_accum_minutes = 0
	var seen := {"n": 0}
	var cb := func(_bi: int, _d: int) -> void: seen["n"] += 1
	Clk.beat_ticked.connect(cb)
	Clk.advance_minutes(15)
	_ok(Clk.beat_index == 1, "15 minutes -> 1 beat")
	_ok(seen["n"] == 1, "beat_ticked emitted once")
	Clk.advance_minutes(30)
	_ok(Clk.beat_index == 3, "45 minutes total -> 3 beats")
	Clk.beat_ticked.disconnect(cb)

func _test_event_bus() -> void:
	print("[event bus]")
	var EB: Object = root.get_node("/root/EventBus")
	EB.clear()
	var ev: Dictionary = EB.emit_event("test_action", {"actor": "voss"})
	_ok(ev["type"] == "test_action", "event records its type")
	_ok(int(ev["seq"]) == 1, "first event seq is 1")
	_ok(EB.events().size() == 1, "one event logged")
	EB.emit_event("other", {})
	_ok(EB.events("test_action").size() == 1, "filter by type returns only matches")
	_ok(EB.latest(1).size() == 1, "latest(1) returns one event")

func _test_agent_fallback() -> void:
	print("[agent fallback]")
	var ND: Object = root.get_node("/root/NpcDB")
	var target: Vector2 = ND.waypoint_for("lamplighter_orin", "morning")
	var a: Agent = Agent.new("lamplighter_orin")
	a.position = Vector2.ZERO
	var before: float = a.distance_to(target)
	a.tick_fallback("morning", 100.0)
	var after: float = a.distance_to(target)
	_ok(after < before, "fallback step moves agent toward its waypoint")
	for _i in range(100):
		a.tick_fallback("morning", 100.0)
	_ok(a.position == target, "fallback converges onto the waypoint")
	a.remember("saw the player near the warehouse")
	_ok(a.short_memory.size() == 1, "remember() appends to short memory")

func _test_agent_registry() -> void:
	print("[agent registry]")
	var AG: Object = root.get_node("/root/Agents")
	AG.rebuild()
	_ok(AG.get_agent("lamplighter_orin") != null, "registry builds a known agent")
	_ok(AG.all().size() >= 2, "registry holds at least the seeded npcs")
	var orin: Agent = AG.get_agent("lamplighter_orin")
	var near: Array = AG.active(orin.position, 1.0)
	_ok(near.has(orin), "active() finds an agent at its own position")
	var far: Array = AG.active(orin.position + Vector2(99999, 0), 1.0)
	_ok(not far.has(orin), "active() excludes agents outside the radius")

func _test_cult_cell_seeded() -> void:
	print("[cult cell]")
	var ND: Object = root.get_node("/root/NpcDB")
	_ok(ND.get_def("clerk_voss").get("faction", "") == "cult", "voss is faction cult")
	_ok(ND.get_def("clerk_voss").get("role", "") == "leader", "voss is the leader")
	_ok(ND.get_def("dockhand_pell").get("role", "") == "victim", "pell is the victim")
	_ok(String(ND.get_def("lamplighter_orin").get("intent", "")) != "", "orin has an intent")
	_ok(String(ND.get_def("fishwife_dalia").get("role", "")) == "logistics", "dalia is logistics")

func _test_substrate_save_load() -> void:
	print("[substrate save/load]")
	var EB: Object = root.get_node("/root/EventBus")
	var AG: Object = root.get_node("/root/Agents")
	var SM: Object = root.get_node("/root/SaveManager")
	AG.rebuild()
	EB.clear()
	EB.emit_event("seed_event", {"x": 1})
	AG.get_agent("clerk_voss").position = Vector2(123, 456)
	var tmp := "user://test_substrate.json"
	_ok(SM.save_game(tmp), "save_game writes file")
	EB.clear()
	AG.get_agent("clerk_voss").position = Vector2.ZERO
	_ok(SM.load_game(tmp), "load_game reads file")
	_ok(EB.events("seed_event").size() == 1, "event log restored after load")
	_ok(AG.get_agent("clerk_voss").position == Vector2(123, 456), "agent position restored")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
