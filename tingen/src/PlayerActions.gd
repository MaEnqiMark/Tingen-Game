extends Node
## The player's interference verbs (autoload `PlayerActions`). Each is a first-class
## EventBus event — identical in shape to an agent action — so the overseer reacts to the
## player exactly as it reacts to agents (and marks the player "involved", lifting the
## no-chance-exposure guard). Both verbs feed the hidden impede score.

const SABOTAGE_IMPEDE: float = 10.0
const SOCIAL_IMPEDE: float = 12.0

## Strip one of an ingredient from the cell's stock. Returns false if the cell lacks it.
func sabotage(item_id: String, count: int = 1) -> bool:
	if not SummoningPlan.remove_ingredient(item_id, count):
		return false
	SummoningPlan.add_impede(SABOTAGE_IMPEDE * count, "sabotage")
	EventBus.emit_event("player_sabotage", {"actor": "player", "item": item_id, "count": count})
	return true

## Turn a waverer (role "scout_waverer") into an ally. Returns false for anyone else.
func social_influence(agent_id: String) -> bool:
	var a: Agent = Agents.get_agent(agent_id)
	if a == null or a.role != "scout_waverer":
		return false
	a.faction = "ally"
	a.remember("chose to turn against the cell")
	SummoningPlan.add_impede(SOCIAL_IMPEDE, "turned waverer")
	EventBus.emit_event("player_social", {"actor": "player", "agent": agent_id, "result": "turned"})
	return true
