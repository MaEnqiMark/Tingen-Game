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
			agent.remember("performed ritual step: %s" % args.get("step", ""))
			return {"ritual_step": String(args.get("step", ""))}
		"recruit":
			agent.remember("approached %s to recruit" % args.get("agent", ""))
			return {"recruited": String(args.get("agent", ""))}
		"report":
			agent.remember("reported to %s: %s" % [args.get("to", ""), args.get("info", "")])
			return {"reported_to": String(args.get("to", ""))}
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
