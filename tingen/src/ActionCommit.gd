class_name ActionCommit
extends RefCounted
## Deterministically applies ONE already-validated action to its agent and the world.
## Returns a small outcome Dictionary describing what happened (logged to the EventBus by
## the runtime). This is the only place agents change world state. For the slice, verbs
## that belong to later systems (combat, ritual countdown, sabotage economy) are recorded
## as memory + outcome here and given their full effects in their own plans.

## Named ritual/world sites in scene coordinates. Inside the iron_cross polygon
## [320,200, 560,380] from districts.json.
const SITES: Dictionary = {
	"iron_cross_warehouse": Vector2(420, 360),
}

## How close (px) an agent must stand to the rite site for its ritual work to actually bite.
## Shared with AmbientSidecar so the live brain only proposes the rite when committing it counts.
const RITE_RADIUS: float = 80.0

## Resolve an autoload singleton by name. Direct `Autoload.` references fail to compile
## in a class_name script under the headless -s harness (autoloads register after
## class_name scripts are parsed); the /root lookup is ordering-independent.
static func _al(autoload_name: String) -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node("/root/" + autoload_name)

## One beat's worth of movement, matching the registry fallback step.
static func _step() -> float:
	return _al("Agents").fallback_speed

static func commit(action: Dictionary, agent: Agent) -> Dictionary:
	agent.current_action = action.duplicate(true)
	agent.thought = String(action.get("thought", ""))
	var verb := String(action.get("verb", ""))
	var args: Dictionary = action.get("args", {})
	match verb:
		"move_to":
			return _move_to(agent, String(args.get("target", "")))
		"talk_to":
			agent.remember("talked to %s about %s" % [args.get("agent", ""), args.get("topic", "")])
			return {"talked_to": String(args.get("agent", ""))}
		"gather_item":
			agent.remember("gathered %s" % args.get("item_id", ""))
			return {"gathered": String(args.get("item_id", ""))}
		"perform_ritual_step":
			return _perform_ritual_step(agent, String(args.get("step", "")))
		"recruit":
			agent.remember("approached %s to recruit" % args.get("agent", ""))
			return {"recruited": String(args.get("agent", ""))}
		"report":
			agent.remember("reported to %s: %s" % [args.get("to", ""), args.get("info", "")])
			return {"reported_to": String(args.get("to", ""))}
		"pray":
			# An NPC praying is memory-only flavor; only PrayerService.pray() (player-initiated)
			# runs adjudication and applies mechanical effects.
			agent.remember("prayed to %s" % args.get("god", ""))
			return {"prayed_to": String(args.get("god", ""))}
		"hide":
			agent.remember("went to ground")
			return {"hid": true}
		"flee":
			return _flee(agent, String(args.get("from", "")))
		"attack":
			agent.remember("attacked %s" % args.get("target", ""))
			return {"attacked": String(args.get("target", ""))}
		"idle":
			return {"idle": true}
		_:
			return {"noop": "unhandled verb '%s'" % verb}

## A cultist working the rite AT the warehouse drives the summoning clock forward — this is the
## only place cult behavior bites the doomsday countdown, so the player can watch the descent leap
## as the faithful gather. The same verb off-site, or from anyone outside the cult, is flavor only.
## (The Critic already blocks non-cultists from proposing this verb; the guard here keeps the world
## effect honest regardless of how the action reached commit.) Emits `ritual_advanced` for the
## debug log — deliberately NOT a public cult-progress event, so the rite stays hidden but felt.
static func _perform_ritual_step(agent: Agent, step: String) -> Dictionary:
	agent.remember("performed ritual step: %s" % step)
	var site: Vector2 = SITES["iron_cross_warehouse"]
	if agent.faction == "cult" and agent.position.distance_to(site) <= RITE_RADIUS:
		var sp: Node = _al("SummoningPlan")
		sp.advance_rite(1)
		_al("EventBus").emit_event("ritual_advanced",
			{"actor": agent.id, "step": step, "closeness": sp.closeness_ratio()})
		return {"ritual_step": step, "advanced": true}
	return {"ritual_step": step, "advanced": false}

static func _move_to(agent: Agent, target: String) -> Dictionary:
	var resolved := _resolve_target(target)
	if not resolved["found"]:
		return {"noop": "unresolved target '%s'" % target}
	var dest: Vector2 = resolved["pos"]
	var to_dest: Vector2 = dest - agent.position
	var dist: float = to_dest.length()
	var step := _step()
	if dist <= step or dist == 0.0:
		agent.position = dest
	else:
		agent.position += to_dest / dist * step
	agent.remember("moved toward %s" % target)
	return {"moved_to": [agent.position.x, agent.position.y]}

static func _flee(agent: Agent, from: String) -> Dictionary:
	var resolved := _resolve_target(from)
	if resolved["found"]:
		var away: Vector2 = agent.position - (resolved["pos"] as Vector2)
		if away.length() > 0.0:
			agent.position += away / away.length() * _step()
	agent.remember("fled from %s" % from)
	return {"fled_from": from}

## Resolve a target string to a position. Order: another agent's id, a named site, an
## "x,y" coordinate. Returns { found: bool, pos: Vector2 }.
static func _resolve_target(target: String) -> Dictionary:
	var other: Agent = _al("Agents").get_agent(target)
	if other != null:
		return {"found": true, "pos": other.position}
	if SITES.has(target):
		return {"found": true, "pos": SITES[target]}
	if "," in target:
		var parts := target.split(",")
		if parts.size() >= 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
			return {"found": true, "pos": Vector2(float(parts[0]), float(parts[1]))}
	return {"found": false, "pos": Vector2.ZERO}
