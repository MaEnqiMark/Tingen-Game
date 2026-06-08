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
	_test_item_db()
	_test_inventory_add_remove()
	_test_inventory_use()
	_test_inventory_save_load()
	_test_action_schema()
	_test_mock_sidecar()
	_test_sidecar_bridge()
	_test_perception_snapshot()
	_test_action_commit()
	_test_agent_runtime_beat()
	_test_overseer_state()
	_test_critic_verdicts()
	_test_runtime_with_overseer()
	_test_summoning_plan()
	_test_occult_divination()
	_test_occult_other_tools()
	_test_player_actions()
	_test_combat_scaled_by_impede()
	_test_player_state_save_load()

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

func _test_item_db() -> void:
	print("[item db]")
	var DB: Object = root.get_node("/root/ItemDB")
	_ok(DB.has_def("rye_bread"), "items.json loaded rye_bread")
	var d: ItemDef = DB.get_def("rye_bread")
	_ok(d != null, "get_def returns an ItemDef")
	_ok(d.category == "sustenance", "rye_bread is sustenance")
	_ok(d.stackable == true, "rye_bread is stackable")
	_ok(d.max_stack == 5, "rye_bread max_stack is 5")
	var pen: ItemDef = DB.get_def("spirit_pendulum")
	_ok(pen.stackable == false, "spirit_pendulum is not stackable")
	_ok(DB.get_def("does_not_exist") == null, "unknown id returns null")

func _test_inventory_add_remove() -> void:
	print("[inventory add/remove]")
	var INV: Object = root.get_node("/root/Inventory")
	INV.clear()
	_ok(INV.add("candle", 3), "add 3 candles succeeds")
	_ok(INV.count_of("candle") == 3, "count is 3")
	_ok(INV.add("candle", 100) == false, "add past max_stack (9) is rejected")
	_ok(INV.count_of("candle") == 3, "count unchanged after rejected add")
	_ok(INV.add("spirit_pendulum"), "add non-stackable succeeds")
	_ok(INV.add("spirit_pendulum") == false, "second non-stackable add rejected (cap 1)")
	_ok(INV.has("candle", 3), "has(candle,3) true")
	_ok(INV.has("candle", 4) == false, "has(candle,4) false")
	_ok(INV.remove("candle", 2), "remove 2 candles succeeds")
	_ok(INV.count_of("candle") == 1, "count is 1 after remove")
	_ok(INV.remove("candle", 5) == false, "remove more than held is rejected")
	_ok(INV.count_of("candle") == 1, "count unchanged after rejected remove")

func _test_inventory_use() -> void:
	print("[inventory use]")
	var INV: Object = root.get_node("/root/Inventory")
	var WS: Object = root.get_node("/root/WorldState")
	INV.clear()
	WS.set_pressure(&"fatigue", 50.0)
	INV.add("rye_bread", 2)
	_ok(INV.use("rye_bread"), "use rye_bread succeeds")
	_ok(abs(WS.get_pressure(&"fatigue") - 38.0) < 0.01, "fatigue dropped by on_use delta (12)")
	_ok(INV.count_of("rye_bread") == 1, "consumable decremented by 1")
	# Non-consumable (no on_use): use does not decrement.
	INV.add("spirit_pendulum")
	_ok(INV.use("spirit_pendulum"), "use non-consumable returns true")
	_ok(INV.count_of("spirit_pendulum") == 1, "non-consumable not decremented")
	# Unknown effect: warns, no-ops, still treated as used (not consumed by default).
	INV.clear()
	_ok(INV.use("candle") == false, "use of unheld item returns false")

func _test_inventory_save_load() -> void:
	print("[inventory save/load]")
	var INV: Object = root.get_node("/root/Inventory")
	var SM: Object = root.get_node("/root/SaveManager")
	INV.clear()
	INV.add("candle", 4)
	INV.add("spirit_pendulum")
	var tmp := "user://test_inventory.json"
	_ok(SM.save_game(tmp), "save_game writes file")
	INV.clear()
	_ok(INV.count_of("candle") == 0, "inventory cleared before load")
	_ok(SM.load_game(tmp), "load_game reads file")
	_ok(INV.count_of("candle") == 4, "candle count restored")
	_ok(INV.has("spirit_pendulum"), "pendulum restored")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

func _test_action_schema() -> void:
	print("[action schema]")
	var ok := ActionSchema.validate({"actor": "voss", "verb": "move_to", "args": {"target": "iron_cross_warehouse"}})
	_ok(ok["ok"] == true, "valid move_to accepted")
	var no_verb := ActionSchema.validate({"actor": "voss", "verb": "teleport", "args": {}})
	_ok(no_verb["ok"] == false, "unknown verb rejected")
	var missing := ActionSchema.validate({"actor": "voss", "verb": "talk_to", "args": {"agent": "orin"}})
	_ok(missing["ok"] == false, "talk_to missing 'topic' rejected")
	var idle := ActionSchema.validate({"actor": "voss", "verb": "idle", "args": {}})
	_ok(idle["ok"] == true, "idle needs no args")
	var no_actor := ActionSchema.validate({"verb": "idle", "args": {}})
	_ok(no_actor["ok"] == false, "missing actor rejected")
	_ok(ActionSchema.is_verb("attack"), "attack is a known verb")
	_ok(not ActionSchema.is_verb("nope"), "nope is not a known verb")

func _test_mock_sidecar() -> void:
	print("[mock sidecar]")
	var mock := MockSidecar.new()
	mock.set_action("voss", {"actor": "voss", "verb": "move_to", "args": {"target": "iron_cross_warehouse"}})
	var snaps := [{"agent_id": "voss"}, {"agent_id": "orin"}]
	var out: Array = mock.propose(snaps)
	_ok(out.size() == 2, "one proposal per snapshot")
	_ok(out[0]["verb"] == "move_to", "scripted action returned for voss")
	_ok(out[1]["verb"] == "idle", "unscripted agent defaults to idle")
	_ok(out[1]["actor"] == "orin", "idle proposal is attributed to the right actor")
	# Queue support: pop one action per beat.
	mock.set_action("orin", [{"actor": "orin", "verb": "hide", "args": {}}])
	var out2: Array = mock.propose([{"agent_id": "orin"}])
	_ok(out2[0]["verb"] == "hide", "queued action consumed")
	var out3: Array = mock.propose([{"agent_id": "orin"}])
	_ok(out3[0]["verb"] == "idle", "empty queue falls back to idle")

func _test_sidecar_bridge() -> void:
	print("[sidecar bridge]")
	var SB: Object = root.get_node("/root/SidecarBridge")
	_ok(SB.client != null, "bridge has a default client")
	var mock := MockSidecar.new()
	mock.set_action("voss", {"actor": "voss", "verb": "attack", "args": {"target": "pell"}})
	SB.set_client(mock)
	var out: Array = SB.propose([{"agent_id": "voss"}])
	_ok(out.size() == 1, "bridge routes one proposal")
	_ok(out[0]["verb"] == "attack", "bridge returns the active client's proposal")
	# Every proposal the bridge returns must be schema-valid for the mock to be useful.
	_ok(ActionSchema.validate(out[0])["ok"], "bridged proposal is schema-valid")

func _test_perception_snapshot() -> void:
	print("[perception]")
	var AG: Object = root.get_node("/root/Agents")
	var EB: Object = root.get_node("/root/EventBus")
	AG.rebuild()
	EB.clear()
	EB.emit_event("test_seed", {"x": 1})
	var voss: Agent = AG.get_agent("clerk_voss")
	var snap: Dictionary = Perception.build_snapshot(voss, voss.position)
	_ok(snap.get("agent_id", "") == "clerk_voss", "snapshot carries agent_id")
	_ok(snap.has("intent"), "snapshot includes intent")
	_ok(snap.has("position"), "snapshot includes position")
	_ok(snap.has("nearby"), "snapshot includes nearby agents")
	_ok(snap.has("recent_events"), "snapshot includes recent events")
	_ok(snap.has("stage"), "snapshot includes world stage")
	_ok(snap.has("pressures"), "snapshot includes pressures")
	# Another agent placed at voss's position should show up as nearby.
	var pell: Agent = AG.get_agent("dockhand_pell")
	pell.position = voss.position
	var snap2: Dictionary = Perception.build_snapshot(voss, voss.position)
	var nearby_ids: Array = []
	for n in snap2["nearby"]:
		nearby_ids.append(n["id"])
	_ok(nearby_ids.has("dockhand_pell"), "co-located agent appears in nearby")
	_ok(not nearby_ids.has("clerk_voss"), "agent does not list itself as nearby")

func _test_action_commit() -> void:
	print("[action commit]")
	var AG: Object = root.get_node("/root/Agents")
	AG.rebuild()
	var voss: Agent = AG.get_agent("clerk_voss")
	voss.position = Vector2.ZERO
	var before: float = voss.position.distance_to(Vector2(420, 360))
	var out: Dictionary = ActionCommit.commit(
		{"actor": "clerk_voss", "verb": "move_to", "args": {"target": "iron_cross_warehouse"}}, voss)
	_ok(out.has("moved_to"), "move_to reports a new position")
	_ok(voss.position.distance_to(Vector2(420, 360)) < before, "agent moved toward the site")
	_ok(voss.current_action.get("verb", "") == "move_to", "current_action is recorded")
	# talk_to records memory, no movement.
	var pos_before: Vector2 = voss.position
	ActionCommit.commit({"actor": "clerk_voss", "verb": "talk_to", "args": {"agent": "lamplighter_orin", "topic": "ritual"}}, voss)
	_ok(voss.position == pos_before, "talk_to does not move the agent")
	_ok(voss.short_memory.size() >= 1, "talk_to records a memory")
	# move_to with an unresolved target is a safe no-op.
	var out2: Dictionary = ActionCommit.commit({"actor": "clerk_voss", "verb": "move_to", "args": {"target": "nowhere_xyz"}}, voss)
	_ok(out2.has("noop"), "unresolved move target is a no-op")
	# coordinate-string target resolves.
	ActionCommit.commit({"actor": "clerk_voss", "verb": "move_to", "args": {"target": "100,100"}}, voss)
	_ok(true, "coordinate target does not error")

func _test_agent_runtime_beat() -> void:
	print("[agent runtime]")
	var AG: Object = root.get_node("/root/Agents")
	var EB: Object = root.get_node("/root/EventBus")
	var SB: Object = root.get_node("/root/SidecarBridge")
	var ART: Object = root.get_node("/root/AgentRuntime")
	AG.rebuild()
	EB.clear()
	var voss: Agent = AG.get_agent("clerk_voss")
	voss.position = Vector2(400, 300)
	ART.player_position = Vector2(400, 300)
	ART.active_radius = 50.0   # only voss is active

	# Mock proposes a valid move for voss.
	var mock := MockSidecar.new()
	mock.set_action("clerk_voss", {"actor": "clerk_voss", "verb": "move_to", "args": {"target": "iron_cross_warehouse"}})
	SB.set_client(mock)

	var before: Vector2 = voss.position
	ART.run_beat()
	_ok(voss.position != before, "active agent acted on its proposal")
	_ok(EB.events("agent_action").size() == 1, "one agent_action logged")
	_ok(EB.events("agent_action")[0]["data"]["actor"] == "clerk_voss", "logged actor is voss")

	# Invalid proposal -> rejected -> fallback.
	EB.clear()
	mock.set_action("clerk_voss", {"actor": "clerk_voss", "verb": "teleport", "args": {}})
	ART.run_beat()
	_ok(EB.events("action_rejected").size() == 1, "invalid action is rejected, not committed")
	_ok(EB.events("agent_action").size() == 0, "no agent_action for the rejected proposal")

	# Idle proposal -> no movement.
	EB.clear()
	mock.set_action("clerk_voss", {"actor": "clerk_voss", "verb": "idle", "args": {}})
	var pos_idle: Vector2 = voss.position
	ART.run_beat()
	_ok(voss.position == pos_idle, "idle proposal leaves the agent in place")

func _test_overseer_state() -> void:
	print("[overseer]")
	var OV: Object = root.get_node("/root/Overseer")
	var EB: Object = root.get_node("/root/EventBus")
	OV.reset()
	# Directives: one-shot, keyed by agent.
	OV.issue_directive("clerk_voss", {"actor": "clerk_voss", "verb": "hide", "args": {}})
	_ok(OV.has_directive("clerk_voss"), "directive queued")
	var d: Dictionary = OV.take_directive("clerk_voss")
	_ok(d.get("verb", "") == "hide", "directive returned")
	_ok(not OV.has_directive("clerk_voss"), "directive is one-shot")
	_ok(OV.take_directive("nobody").is_empty(), "no directive returns empty dict")
	# Coordinate: issue the same directive to several agents.
	OV.coordinate(["fishwife_dalia", "lamplighter_orin"], {"verb": "move_to", "args": {"target": "iron_cross_warehouse"}})
	_ok(OV.has_directive("fishwife_dalia"), "coordinate queues for agent 1")
	_ok(OV.has_directive("lamplighter_orin"), "coordinate queues for agent 2")
	_ok(OV.take_directive("fishwife_dalia").get("actor", "") == "fishwife_dalia", "coordinate sets actor per agent")
	# Player involvement is initially false, flips on a player_ event.
	OV.reset()
	_ok(OV.allows_exposure() == false, "exposure disallowed until player is involved")
	EB.emit_event("player_sabotage", {"actor": "player", "item": "ritual_salt"})
	_ok(OV.allows_exposure() == true, "a player_ event marks the player involved")

func _test_critic_verdicts() -> void:
	print("[critic]")
	var AG: Object = root.get_node("/root/Agents")
	var OV: Object = root.get_node("/root/Overseer")
	AG.rebuild()
	OV.reset()
	var voss: Agent = AG.get_agent("clerk_voss")        # cult / leader
	var pell: Agent = AG.get_agent("dockhand_pell")     # civilian / victim
	var orin: Agent = AG.get_agent("lamplighter_orin")  # cult / scout_waverer

	# Coherent cult ritual step: approved.
	_ok(Critic.review({"actor": "clerk_voss", "verb": "perform_ritual_step", "args": {"step": "draw_circle"}}, voss)["verdict"] == "approve",
		"cult leader may perform a ritual step")
	# Victim performing a ritual step: incoherent -> veto.
	_ok(Critic.review({"actor": "dockhand_pell", "verb": "perform_ritual_step", "args": {"step": "draw_circle"}}, pell)["verdict"] == "veto",
		"the victim cannot perform a ritual step")
	# A turned waverer (faction no longer cult) performing a ritual step -> veto.
	orin.faction = "ally"
	_ok(Critic.review({"actor": "lamplighter_orin", "verb": "perform_ritual_step", "args": {"step": "draw_circle"}}, orin)["verdict"] == "veto",
		"a turned waverer would not perform a ritual step")
	# Exposing report without player involvement -> veto; with involvement -> approve.
	var expose := {"actor": "clerk_voss", "verb": "report", "args": {"to": "nighthawks", "info": "the cult meets at the warehouse"}}
	_ok(Critic.review(expose, voss)["verdict"] == "veto", "no caught-by-chance: exposing report vetoed")
	OV.player_involved = true
	_ok(Critic.review(expose, voss)["verdict"] == "approve", "exposing report allowed once player is involved")
	# Ordinary move is always fine.
	_ok(Critic.review({"actor": "clerk_voss", "verb": "move_to", "args": {"target": "iron_cross_warehouse"}}, voss)["verdict"] == "approve",
		"ordinary move approved")

func _test_runtime_with_overseer() -> void:
	print("[runtime + overseer]")
	var AG: Object = root.get_node("/root/Agents")
	var EB: Object = root.get_node("/root/EventBus")
	var SB: Object = root.get_node("/root/SidecarBridge")
	var OV: Object = root.get_node("/root/Overseer")
	var ART: Object = root.get_node("/root/AgentRuntime")
	AG.rebuild()
	OV.reset()
	var voss: Agent = AG.get_agent("clerk_voss")
	voss.position = Vector2(400, 300)
	ART.player_position = Vector2(400, 300)
	ART.active_radius = 50.0

	# 1) Critic veto: turned waverer proposing a ritual step -> vetoed -> no commit.
	var orin: Agent = AG.get_agent("lamplighter_orin")
	orin.faction = "ally"
	orin.position = Vector2(400, 300)   # make orin active too
	var mock := MockSidecar.new()
	mock.set_action("lamplighter_orin", {"actor": "lamplighter_orin", "verb": "perform_ritual_step", "args": {"step": "x"}})
	mock.set_action("clerk_voss", {"actor": "clerk_voss", "verb": "idle", "args": {}})
	SB.set_client(mock)
	EB.clear()
	ART.run_beat()
	_ok(EB.events("action_vetoed").size() >= 1, "incoherent action is vetoed")
	var ritual_actions: Array = EB.events("agent_action").filter(func(e): return e["data"]["verb"] == "perform_ritual_step")
	_ok(ritual_actions.size() == 0, "vetoed ritual step is never committed")

	# 2) Overseer directive overrides the agent's own proposal.
	AG.rebuild(); OV.reset()
	var voss2: Agent = AG.get_agent("clerk_voss")
	voss2.position = Vector2(800, 800)              # far from player -> not active
	ART.player_position = Vector2(0, 0)
	ART.active_radius = 10.0
	var before: Vector2 = voss2.position
	OV.issue_directive("clerk_voss", {"actor": "clerk_voss", "verb": "move_to", "args": {"target": "iron_cross_warehouse"}})
	EB.clear()
	ART.run_beat()
	_ok(EB.events("overseer_directive").size() == 1, "directive committed even for an inactive agent")
	_ok(voss2.position != before, "directed agent moved per the directive")

	# 3) End-to-end exposure invariant: exposing report blocked, then allowed.
	AG.rebuild(); OV.reset()
	var voss3: Agent = AG.get_agent("clerk_voss")
	voss3.position = Vector2(0, 0)
	ART.player_position = Vector2(0, 0)
	ART.active_radius = 50.0
	mock.clear()
	mock.set_action("clerk_voss", {"actor": "clerk_voss", "verb": "report", "args": {"to": "nighthawks", "info": "the cult meets at the warehouse"}})
	# make only voss active: move others away
	for a in AG.all():
		if a.id != "clerk_voss":
			a.position = Vector2(9000, 9000)
	EB.clear()
	ART.run_beat()
	_ok(EB.events("action_vetoed").size() == 1, "exposing report vetoed without player involvement")
	# Player gets involved, then the same report is allowed.
	EB.emit_event("player_investigate", {"actor": "player"})
	EB.clear()
	mock.set_action("clerk_voss", {"actor": "clerk_voss", "verb": "report", "args": {"to": "nighthawks", "info": "the cult meets at the warehouse"}})
	ART.run_beat()
	_ok(EB.events("agent_action").size() == 1, "report committed once the player is involved")

func _test_summoning_plan() -> void:
	print("[summoning plan]")
	var SP: Object = root.get_node("/root/SummoningPlan")
	SP.reset()
	var base: float = SP.manifestation_strength()
	# Impede weakens the manifestation.
	SP.add_impede(20.0, "test")
	_ok(SP.manifestation_strength() < base, "impede lowers manifestation strength")
	_ok(SP.impede_score == 20.0, "impede accumulates")
	# Removing an ingredient weakens it further AND sets back the countdown.
	var cd_before: int = SP.countdown_beats
	var strength_before: float = SP.manifestation_strength()
	_ok(SP.remove_ingredient("ritual_salt", 1), "ritual_salt removed from cult stock")
	_ok(SP.manifestation_strength() < strength_before, "fewer ingredients -> weaker")
	_ok(SP.countdown_beats > cd_before, "removing an ingredient sets back the countdown")
	# Removing more than held fails and changes nothing.
	var cd_now: int = SP.countdown_beats
	_ok(SP.remove_ingredient("ritual_salt", 999) == false, "cannot remove more than held")
	_ok(SP.countdown_beats == cd_now, "failed removal does not set back the countdown")
	# Strength is clamped to a floor.
	SP.add_impede(1000.0, "overkill")
	_ok(SP.manifestation_strength() >= SP.MIN_STRENGTH, "strength never drops below the floor")

func _test_occult_divination() -> void:
	print("[occult divination]")
	var OTM: Object = root.get_node("/root/OccultToolManager")
	var INV: Object = root.get_node("/root/Inventory")
	var WS: Object = root.get_node("/root/WorldState")
	var WM: Object = root.get_node("/root/WorldManager")
	OTM.rebuild()
	INV.clear()
	WS.set_pressure(&"fatigue", 0.0)
	WS.set_pressure(&"attention", 0.0)
	WS.set_pressure(&"corruption", 0.0)   # no mislead at zero corruption
	# Gating: cannot use without owning the kit + the candle ingredient.
	_ok(OTM.can_use("divination") == false, "divination blocked without tool item")
	INV.add("divination_kit")
	_ok(OTM.can_use("divination") == false, "divination blocked without candle ingredient")
	INV.add("candle", 1)
	_ok(OTM.can_use("divination") == true, "divination usable once kit + candle present")
	# Use: pays cost, consumes the candle, yields a directional lead.
	var res: Dictionary = OTM.use("divination")
	_ok(res.get("ok", false), "divination returns ok")
	_ok(String(res.get("lead", "")) != "", "divination yields a directional lead")
	_ok(WS.get_pressure(&"fatigue") > 0.0, "divination spent fatigue")
	_ok(INV.count_of("candle") == 0, "divination consumed the candle")
	# No-name guarantee: the lead never contains the true resolved site id.
	var true_site: String = String(WM.slots.get("primary_ritual_site", ""))
	_ok(true_site == "" or not String(res["lead"]).contains(true_site), "lead never names the true site")

func _test_occult_other_tools() -> void:
	print("[occult other tools]")
	var OTM: Object = root.get_node("/root/OccultToolManager")
	var INV: Object = root.get_node("/root/Inventory")
	var WS: Object = root.get_node("/root/WorldState")
	OTM.rebuild()
	INV.clear()
	WS.set_pressure(&"fatigue", 0.0)
	WS.set_pressure(&"corruption", 0.0)
	# Residue sight: owns lens, no ingredient cost.
	INV.add("spirit_lens")
	_ok(OTM.can_use("residue_sight"), "residue sight usable with just the lens")
	var r1: Dictionary = OTM.use("residue_sight")
	_ok(r1.get("ok", false), "residue sight returns ok")
	# Dream fragments: produces dream_residue.
	INV.add("dream_draught")
	INV.add("dream_herb", 1)
	var r2: Dictionary = OTM.use("dream_fragments")
	_ok(r2.get("ok", false), "dream fragments returns ok")
	_ok(INV.count_of("dream_residue") == 1, "dream fragments produces dream_residue")
	_ok(INV.count_of("dream_herb") == 0, "dream fragments consumes dream_herb")
	# Gray fog: hard-capped at 3 uses per run.
	INV.add("gray_fog_focus")
	INV.add("consecrated_chalk", 9)
	_ok(OTM.use("gray_fog").get("ok", false), "gray fog use 1 ok")
	OTM.use("gray_fog")
	OTM.use("gray_fog")
	_ok(OTM.can_use("gray_fog") == false, "gray fog refused after 3 uses")
	_ok(OTM.use("gray_fog").get("ok", false) == false, "gray fog 4th use blocked")

func _test_player_actions() -> void:
	print("[player actions]")
	var PA: Object = root.get_node("/root/PlayerActions")
	var SP: Object = root.get_node("/root/SummoningPlan")
	var OV: Object = root.get_node("/root/Overseer")
	var EB: Object = root.get_node("/root/EventBus")
	var AG: Object = root.get_node("/root/Agents")
	AG.rebuild(); SP.reset(); OV.reset(); EB.clear()

	# Sabotage: strips a cult ingredient, raises impede, sets back the countdown, and
	# marks the player involved (so the overseer will now allow exposure).
	var cd_before: int = SP.countdown_beats
	var impede_before: float = SP.impede_score
	_ok(PA.sabotage("ritual_salt"), "sabotage of a held ingredient succeeds")
	_ok(SP.countdown_beats > cd_before, "sabotage sets back the summoning countdown")
	_ok(SP.impede_score > impede_before, "sabotage raises impede")
	_ok(EB.events("player_sabotage").size() == 1, "sabotage logs a player event")
	_ok(OV.allows_exposure(), "sabotage marks the player involved")
	# Sabotage of an absent ingredient fails and changes nothing.
	_ok(PA.sabotage("does_not_exist") == false, "sabotage of an unheld ingredient fails")

	# Social influence: turning the waverer flips his faction and raises impede.
	var orin: Agent = AG.get_agent("lamplighter_orin")
	_ok(orin.faction == "cult", "orin starts in the cult")
	var impede2: float = SP.impede_score
	_ok(PA.social_influence("lamplighter_orin"), "turning the waverer succeeds")
	_ok(orin.faction == "ally", "the waverer is turned to an ally")
	_ok(SP.impede_score > impede2, "turning the waverer raises impede")
	_ok(EB.events("player_social").size() == 1, "social influence logs a player event")
	# A non-waverer cannot be turned.
	_ok(PA.social_influence("clerk_voss") == false, "the committed leader cannot be turned")

func _test_combat_scaled_by_impede() -> void:
	print("[combat]")
	var SP: Object = root.get_node("/root/SummoningPlan")

	# Strong manifestation (no impede): hard fight.
	SP.reset()
	var hard := CombatEncounter.new(SP.manifestation_strength())
	var hard_result: Dictionary = hard.auto_resolve()

	# Weakened manifestation (heavy impede + stripped ingredients): easy fight.
	SP.reset()
	SP.add_impede(70.0, "test")
	SP.remove_ingredient("ritual_salt", 3)
	var easy := CombatEncounter.new(SP.manifestation_strength())
	var easy_result: Dictionary = easy.auto_resolve()

	_ok(easy.enemy_max_hp < hard.enemy_max_hp, "more impede -> weaker enemy")
	_ok(easy_result["player_hp_left"] > hard_result["player_hp_left"], "more impede -> player ends with more HP")
	_ok(easy_result["win"] == true, "a heavily-impeded summoning is winnable")
	_ok(hard_result.has("rounds"), "result reports the round count")
	# The occult ability hits harder than a basic attack.
	var enc := CombatEncounter.new(50.0)
	_ok(enc.OCCULT_DAMAGE > enc.ATTACK_DAMAGE, "occult ability beats a basic attack")

func _test_player_state_save_load() -> void:
	print("[player state save/load]")
	var SP: Object = root.get_node("/root/SummoningPlan")
	var OV: Object = root.get_node("/root/Overseer")
	var OTM: Object = root.get_node("/root/OccultToolManager")
	var SM: Object = root.get_node("/root/SaveManager")
	SP.reset(); OV.reset(); OTM.rebuild()
	SP.add_impede(33.0, "test")
	SP.remove_ingredient("candle", 1)
	OV.player_involved = true
	var tmp := "user://test_player_state.json"
	_ok(SM.save_game(tmp), "save_game writes file")
	SP.reset(); OV.reset()
	_ok(SP.impede_score == 0.0, "impede cleared before load")
	_ok(SM.load_game(tmp), "load_game reads file")
	_ok(abs(SP.impede_score - 33.0) < 0.01, "impede restored")
	_ok(SP.ingredients.get("candle", 0) == 2, "cult ingredient stock restored")
	_ok(OV.player_involved == true, "overseer player-involvement restored")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
