extends Node2D
## The live district. The agent-sim brain visibly drives the cast here: one rendered NPC
## per registry Agent (data-driven, not hand-placed), each bound by id so it follows its
## Agent's beat-driven position. Pushes the real player's position into AgentRuntime every
## frame so "active agents near the player" tracks what is on screen, and presents the
## summoning climax when SummoningPlan's countdown hits zero.
##
## The set itself is built procedurally in `_build_streetscape`: the district *regions* are
## drawn data-driven from districts.json (so they always match the map and risk model), while
## the Iron Cross crossroads, the flanking buildings, the harbor waterfront, the street lamps
## and the warehouse (the rite site the cult converges on) are authored set-dressing anchored
## to the known site coordinates. No external art — every shape is a Polygon2D/Line2D/Label.

const NPC_SCENE: PackedScene = preload("res://scenes/NPC.tscn")
const PLAYER_SCENE: PackedScene = preload("res://scenes/Player.tscn")
const INTERACTABLE_SCENE: PackedScene = preload("res://scenes/Interactable.tscn")
const DISTRICTS_PATH: String = "res://data/districts.json"

## The warehouse north door, by the rite-door lamp — where the sabotage point stands so the
## player can reach the cult's gathered cache on foot. Inside ActionCommit.RITE_RADIUS of (420,360).
const SABOTAGE_POINT: Vector2 = Vector2(420, 352)

# Per-district ground tints by id; districts not listed fall back to GROUND_DISTRICT.
const DISTRICT_TINTS: Dictionary = {
	"iron_cross": Color(0.205, 0.205, 0.255),
	"harbor": Color(0.105, 0.185, 0.245),
	"st_selena": Color(0.235, 0.225, 0.265),
	"night_market": Color(0.245, 0.200, 0.170),
	"uptown": Color(0.215, 0.225, 0.255),
}
const GROUND_BASE: Color = Color(0.085, 0.095, 0.125)   # void beyond the mapped districts
const GROUND_DISTRICT: Color = Color(0.180, 0.180, 0.220)
const ROAD: Color = Color(0.300, 0.300, 0.345)
const BUILDING_FILL: Color = Color(0.150, 0.155, 0.190)
const BUILDING_EDGE: Color = Color(0.310, 0.320, 0.380)
const WATER_EDGE: Color = Color(0.400, 0.560, 0.610, 0.70)
# The rite site. Sits at the south foot of the north-south street; agents pathing to the
# warehouse site (420,360) gather at its north door.
const WAREHOUSE_RECT: Rect2 = Rect2(360, 348, 140, 96)
const WAREHOUSE_FILL: Color = Color(0.235, 0.130, 0.130)
const WAREHOUSE_EDGE: Color = Color(0.520, 0.225, 0.215)

@export var player_start: Vector2 = Vector2(440, 300)

var _player: Node2D = null

func _ready() -> void:
	_build_streetscape()
	_spawn_player()
	_spawn_agents()
	_spawn_rite_sabotage_point()
	# The climax (and its win/lose endings) is owned by the EndGame autoload, which persists
	# across world swaps and pauses the tree to raise the end screen. The live district just
	# dresses the set; it no longer resolves the fight.

# --- Set construction -------------------------------------------------------------------
## Build the streetscape under one "Streetscape" node, added first so the player and NPCs
## (spawned after) render on top of it. Draw order within the group runs back-to-front:
## base ground -> district regions -> water -> roads -> buildings -> warehouse -> lamps -> labels.
func _build_streetscape() -> void:
	var s := Node2D.new()
	s.name = "Streetscape"
	add_child(s)

	_block(s, Rect2(-400, -400, 2000, 1600), GROUND_BASE)

	# District regions, straight from the same data the map and risk model read.
	for d in _load_districts():
		var poly: PackedVector2Array = _poly_of(d)
		if poly.size() < 3:
			continue
		var pg := Polygon2D.new()
		pg.polygon = poly
		pg.color = DISTRICT_TINTS.get(String(d.get("id", "")), GROUND_DISTRICT)
		s.add_child(pg)

	# Harbor waterfront: a bright quay edge along the harbor's north shore plus a few ripples.
	_line(s, [Vector2(80, 400), Vector2(360, 400)], WATER_EDGE, 2.0)
	for i in 3:
		var y := 438.0 + i * 46.0
		_line(s, [Vector2(108, y), Vector2(332, y)], Color(0.170, 0.300, 0.360, 0.65), 2.0)

	# The Iron Cross itself — an east-west street meeting a north-south street.
	_block(s, Rect2(120, 296, 660, 48), ROAD)
	_block(s, Rect2(412, 140, 48, 360), ROAD)
	_line(s, [Vector2(120, 296), Vector2(780, 296)], Color(0.42, 0.42, 0.47, 0.45), 1.0)
	_line(s, [Vector2(120, 344), Vector2(780, 344)], Color(0.42, 0.42, 0.47, 0.45), 1.0)

	# Tenements and shops flanking the crossroads.
	for b in [Rect2(150, 176, 140, 108), Rect2(150, 352, 150, 116), Rect2(300, 160, 96, 128),
			Rect2(486, 172, 130, 112), Rect2(500, 352, 120, 116), Rect2(636, 206, 104, 120)]:
		_building(s, b, BUILDING_FILL, BUILDING_EDGE)

	# The warehouse — the cult's rite site, set apart by an ominous maroon and a name.
	_building(s, WAREHOUSE_RECT, WAREHOUSE_FILL, WAREHOUSE_EDGE)
	_place_label(s, WAREHOUSE_RECT.position + Vector2(10, -18), "Warehouse", Color(0.88, 0.52, 0.50), 13)

	# Street lamps (the lamplighter's work) pooling warm light at the crossing and the rite door.
	for p in [Vector2(402, 286), Vector2(470, 286), Vector2(402, 354), Vector2(644, 322)]:
		_lamp(s, p)

	# Place-names. Kept ASCII — the fallback font has no CJK glyphs.
	_place_label(s, Vector2(330, 150), "Iron Cross Street", Color(0.72, 0.74, 0.82), 16)
	_place_label(s, Vector2(150, 470), "The Harbor", Color(0.50, 0.62, 0.68), 12)

func _block(parent: Node2D, rect: Rect2, color: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y)])
	p.color = color
	parent.add_child(p)
	return p

func _building(parent: Node2D, rect: Rect2, fill: Color, edge: Color) -> void:
	_block(parent, rect, fill)
	_line(parent, [rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
		Vector2(rect.position.x, rect.end.y), rect.position], edge, 1.5)

func _line(parent: Node2D, pts: Array, color: Color, w: float) -> void:
	var l := Line2D.new()
	l.points = PackedVector2Array(pts)
	l.width = w
	l.default_color = color
	parent.add_child(l)

## A street lamp: a faint halo, a warmer glow, and a bright core — all texture-free discs.
func _lamp(parent: Node2D, center: Vector2) -> void:
	_disc(parent, center, 17.0, Color(0.95, 0.85, 0.45, 0.10))
	_disc(parent, center, 8.0, Color(1.0, 0.90, 0.55, 0.30))
	_disc(parent, center, 3.0, Color(1.0, 0.96, 0.72, 0.95))

func _disc(parent: Node2D, center: Vector2, radius: float, color: Color, segments: int = 16) -> void:
	var pts := PackedVector2Array()
	for i in segments:
		var a := TAU * float(i) / float(segments)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	var p := Polygon2D.new()
	p.polygon = pts
	p.color = color
	parent.add_child(p)

func _place_label(parent: Node2D, pos: Vector2, text: String, color: Color, size: int) -> void:
	var l := Label.new()
	l.position = pos
	l.text = text
	l.modulate = color
	l.add_theme_font_size_override("font_size", size)
	parent.add_child(l)

func _load_districts() -> Array:
	if not FileAccess.file_exists(DISTRICTS_PATH):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DISTRICTS_PATH))
	return parsed if typeof(parsed) == TYPE_ARRAY else []

func _poly_of(d: Dictionary) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var raw: Array = d.get("polygon", [])
	for i in range(0, raw.size() - 1, 2):
		pts.append(Vector2(float(raw[i]), float(raw[i + 1])))
	return pts

## Test/debug seam: true once the streetscape has drawn and labeled the warehouse rite site.
func has_warehouse_marker() -> bool:
	var s: Node = get_node_or_null("Streetscape")
	if s == null:
		return false
	for c in s.get_children():
		if c is Label and (c as Label).text == "Warehouse":
			return true
	return false

## Test/debug seam: true once the rite-cache sabotage interactable has been placed, so the player
## has a reachable way to strip the cult's stock by hand.
func has_sabotage_point() -> bool:
	for c in get_children():
		if c.is_in_group("interactable") and bool(c.get("sabotage_cache")):
			return true
	return false

# --- Cast -------------------------------------------------------------------------------
func _spawn_player() -> void:
	_player = PLAYER_SCENE.instantiate()
	add_child(_player)
	_player.global_position = player_start
	AgentRuntime.player_position = player_start

func _spawn_agents() -> void:
	for a in Agents.all():
		var npc: Node2D = NPC_SCENE.instantiate()
		npc.npc_id = a.id
		add_child(npc)
		npc.global_position = a.position

## The player's hands-on counter to the summoning: a sabotage point at the warehouse door. Walk
## up, press E, and one gathered ingredient is scattered (PlayerActions.sabotage_any) — setting the
## rite back and weakening the descent. The cult re-gathers, so it is a tug-of-war, not a kill switch.
func _spawn_rite_sabotage_point() -> void:
	var node: Node2D = INTERACTABLE_SCENE.instantiate()
	node.sabotage_cache = true
	node.prompt_text = "Spoil the rite cache"
	node.tint = WAREHOUSE_EDGE
	add_child(node)
	node.global_position = SABOTAGE_POINT

func _process(_delta: float) -> void:
	if is_instance_valid(_player):
		AgentRuntime.player_position = _player.global_position
