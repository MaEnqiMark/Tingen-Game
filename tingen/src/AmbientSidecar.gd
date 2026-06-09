class_name AmbientSidecar
extends MockSidecar
## Offline "living world" brain — the live default until HttpSidecar (the real LLM) is wired.
## MockSidecar idles every unscripted actor, so active agents near the player freeze while only
## far ones (schedule fallback) move; the district looks dead. AmbientSidecar instead gives every
## agent a faction-appropriate goal each beat: cultists (cult 教徒) converge on the rite site, and
## everyone else drifts along their daily schedule. A small deterministic per-agent/per-beat
## scatter keeps the crowd from stacking on a single pixel and reads as milling/loitering.
##
## It extends MockSidecar (not SidecarClient) to inherit the deterministic prayer adjudication, so
## the player's prayers still resolve correctly under the live brain. Only `propose` is replaced;
## `scripted` is ignored. Every output is a pure function of (snapshot, beat) — same inputs give
## the same proposal — so the world is reproducible and the behavior is unit-testable.

## Mirrors ActionCommit.SITES.iron_cross_warehouse — the descending god's rite pulls the faithful in.
const WAREHOUSE: Vector2 = Vector2(420, 360)
const WANDER: float = 28.0   # px of deterministic per-beat scatter around a goal

func propose(snapshots: Array) -> Array:
	var out: Array = []
	for s in snapshots:
		out.append(_decide(s as Dictionary))
	return out

func _decide(snap: Dictionary) -> Dictionary:
	var actor := String(snap.get("agent_id", ""))
	var faction := String(snap.get("faction", ""))
	var goal: Vector2 = _goal_for(actor, faction, snap) + _scatter(actor, int(snap.get("beat", 0)))
	# Encode the goal as an "x,y" target so ActionCommit resolves it without a named site.
	return {
		"actor": actor,
		"verb": "move_to",
		"args": {"target": "%.1f,%.1f" % [goal.x, goal.y]},
		"thought": _thought_for(faction),
	}

func _goal_for(actor: String, faction: String, snap: Dictionary) -> Vector2:
	if _is_cult(faction):
		return WAREHOUSE
	return _schedule_goal(actor, snap)

func _is_cult(faction: String) -> bool:
	return faction.to_lower().contains("cult")

## Where a non-cult agent is headed: its scheduled waypoint for the current phase. Falls back to
## holding position (+scatter) when the agent has no schedule entry, so it still reads as alive.
func _schedule_goal(actor: String, snap: Dictionary) -> Vector2:
	var wp: Vector2 = _al("NpcDB").waypoint_for(actor, String(snap.get("phase", "")))
	if wp == Vector2.ZERO:
		return _vec(snap.get("position", [0, 0]))
	return wp

## Deterministic per-agent, per-beat offset in roughly [-WANDER, WANDER] on each axis. A pure hash
## of (actor, beat) so the same beat replays identically while the crowd still spreads out.
func _scatter(actor: String, beat: int) -> Vector2:
	var fx := float(absi(hash(actor + "|x|" + str(beat)) % 2001)) / 1000.0 - 1.0
	var fy := float(absi(hash(actor + "|y|" + str(beat)) % 2001)) / 1000.0 - 1.0
	return Vector2(fx, fy) * WANDER

func _thought_for(faction: String) -> String:
	return "The rite needs me at the warehouse." if _is_cult(faction) else "Going about my day."

func _vec(v: Variant) -> Vector2:
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO

## Resolve an autoload by name — direct `NpcDB.` references fail to compile in a class_name script
## under the headless -s harness (autoloads register after class_name scripts parse).
func _al(autoload_name: String) -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node("/root/" + autoload_name)
