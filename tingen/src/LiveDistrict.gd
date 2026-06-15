extends Node2D
## The live, to-scale district. Built data-driven from CityLayout, which transforms the canonical
## map-pixel authoring (data/city_layout.json) into world space via MapProjection: the whole city
## — five districts, the east river/harbor, and many small building blocks — is laid out true to
## tingen_map.png. Each block and water body gets a visual Polygon2D plus a StaticBody2D /
## CollisionPolygon2D so the player and agents collide with the city. One rendered NPC per registry
## Agent is spawned at its (rescaled) position and follows its beat-driven goal. The warehouse
## (降临 / the cult's rite site) is open maroon set-dressing the cast converges on; the player can
## spoil the gathered cache there. The map underlay, camera bounds, city-edge walls, and the baked
## navmesh are layered on in LiveDistrict's later build steps.

const NPC_SCENE: PackedScene = preload("res://scenes/NPC.tscn")
const PLAYER_SCENE: PackedScene = preload("res://scenes/Player.tscn")
const INTERACTABLE_SCENE: PackedScene = preload("res://scenes/Interactable.tscn")
const DISTRICTS_PATH: String = "res://data/districts.json"
const MAP_TEXTURE: Texture2D = preload("res://assets/maps/tingen_map.png")

## Player spawn: a street just south of the Iron Cross blocks (map (470,360) x3.5). On the walkable
## negative space between buildings, a short walk from the warehouse rite site.
@export var player_start: Vector2 = Vector2(1645, 1260)
## The map art drawn behind the vector city, scaled to cover (0,0)-(3500,2471). ON by default so
## geometry can be traced against it; flipped OFF (a later user-triggered step) once faithful.
@export var show_map_underlay: bool = true

## The sabotage point at the warehouse door (map (505,372) x3.5): ~35u from the rite site, inside
## ActionCommit.RITE_RADIUS so the player can spoil the gathered cache by hand.
const SABOTAGE_POINT: Vector2 = Vector2(1767.5, 1302.0)
## The warehouse building footprint in world space (map rect (485,350)-(545,394) x3.5). Visual
## set-dressing only (no collider) so cultists gather in its open courtyard and the player reaches
## the sabotage point.
const WAREHOUSE_RECT: Rect2 = Rect2(1697.5, 1225.0, 210.0, 154.0)

# Per-district translucent ground tints by id; districts not listed fall back to GROUND_DISTRICT.
const DISTRICT_TINTS: Dictionary = {
	"iron_cross": Color(0.205, 0.205, 0.255),
	"harbor": Color(0.105, 0.185, 0.245),
	"st_selena": Color(0.235, 0.225, 0.265),
	"night_market": Color(0.245, 0.200, 0.170),
	"uptown": Color(0.215, 0.225, 0.255),
}
const GROUND_BASE: Color = Color(0.110, 0.120, 0.150)        # the streets/paving filling city_outline
const GROUND_DISTRICT: Color = Color(0.180, 0.180, 0.220)
const WATER_FILL: Color = Color(0.085, 0.150, 0.205)
const WATER_EDGE: Color = Color(0.400, 0.560, 0.610, 0.70)
const BUILDING_FILL: Color = Color(0.150, 0.155, 0.190)
const BUILDING_EDGE: Color = Color(0.310, 0.320, 0.380)
const WAREHOUSE_FILL: Color = Color(0.235, 0.130, 0.130)
const WAREHOUSE_EDGE: Color = Color(0.520, 0.225, 0.215)

var _player: Node2D = null

func _ready() -> void:
	_build_underlay()
	_build_city()
	_build_boundary()
	_spawn_player()
	_apply_camera_bounds()
	_spawn_agents()
	_spawn_rite_sabotage_point()

# --- Set construction -------------------------------------------------------------------
## Build the city under one "Streetscape" node (added first so the cast renders on top). The fills,
## district tints, water, and building blocks are all data-driven from CityLayout; the warehouse is
## authored maroon set-dressing at the rite site.
func _build_city() -> void:
	var s := Node2D.new()
	s.name = "Streetscape"
	add_child(s)

	var layout := CityLayout.load_default()

	# 1) Ground base filling the city outline (the streets/negative space read as paving).
	var ground := Polygon2D.new()
	ground.polygon = layout.outline()
	ground.color = GROUND_BASE
	s.add_child(ground)

	# 2) District tints, from the same map_polygon data the panel & risk model read.
	for d in _load_districts():
		var poly := _district_world_poly(d)
		if poly.size() < 3:
			continue
		var pg := Polygon2D.new()
		pg.polygon = poly
		var tint: Color = DISTRICT_TINTS.get(String(d.get("id", "")), GROUND_DISTRICT)
		tint.a = 0.45
		pg.color = tint
		s.add_child(pg)

	# 3) Water (river + harbor): visual fill + edge + a solid body so the player can't enter it.
	for w in layout.water():
		_fill(s, w, WATER_FILL)
		_outline(s, w, WATER_EDGE, 2.0)
		_solid(s, w, "city_water")

	# 4) Building blocks: visual fill + edge + a solid body each.
	for b in layout.blocks():
		_fill(s, b, BUILDING_FILL)
		_outline(s, b, BUILDING_EDGE, 1.5)
		_solid(s, b, "city_block")

	# 5) The warehouse — maroon, named, no collider (open rite courtyard).
	var wh_poly := _rect_poly(WAREHOUSE_RECT)
	_fill(s, wh_poly, WAREHOUSE_FILL)
	_outline(s, wh_poly, WAREHOUSE_EDGE, 2.0)

	# 6) Landmark labels (rite site, cathedral, bridge, market, harbor) at their world positions.
	for lm in layout.landmarks():
		_place_label(s, (lm["pos"] as Vector2) + Vector2(-30, -22), String(lm["label"]),
			Color(0.86, 0.84, 0.92), 13)

## The map art underlay: a Sprite2D covering exactly (0,0)-(3500,2471), behind everything. A
## tracing aid only — the vectors are the source of truth for collision/nav — so its visibility is
## a free toggle that changes nothing functional.
func _build_underlay() -> void:
	var spr := Sprite2D.new()
	spr.name = "MapUnderlay"
	spr.texture = MAP_TEXTURE
	spr.centered = false
	spr.position = Vector2.ZERO
	spr.scale = Vector2(MapProjection.CITY_SCALE, MapProjection.CITY_SCALE)
	spr.z_index = -100
	spr.visible = show_map_underlay
	add_child(spr)

## Four infinite WorldBoundaryShape2D walls at the world rect edges, so the player can't walk off
## the map. Each normal points inward (toward the playable side); distance = normal . edge-point.
func _build_boundary() -> void:
	var w: float = MapProjection.MAP_SIZE.x * MapProjection.CITY_SCALE   # 3500
	var h: float = MapProjection.MAP_SIZE.y * MapProjection.CITY_SCALE   # 2471
	_wall(Vector2(1, 0), 0.0)     # left   (x = 0)
	_wall(Vector2(-1, 0), -w)     # right  (x = 3500)
	_wall(Vector2(0, 1), 0.0)     # top    (y = 0)
	_wall(Vector2(0, -1), -h)     # bottom (y = 2471)

func _wall(normal: Vector2, distance: float) -> void:
	var body := StaticBody2D.new()
	body.add_to_group("city_boundary")
	var col := CollisionShape2D.new()
	var shape := WorldBoundaryShape2D.new()
	shape.normal = normal
	shape.distance = distance
	col.shape = shape
	body.add_child(col)
	add_child(body)

## Bound the player's camera to the (0,0)-(3500,2471) city rect so the view never shows the void.
func _apply_camera_bounds() -> void:
	if _player == null:
		return
	var cam := _player.get_node_or_null("Camera2D") as Camera2D
	if cam == null:
		return
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = int(MapProjection.MAP_SIZE.x * MapProjection.CITY_SCALE)   # 3500
	cam.limit_bottom = int(MapProjection.MAP_SIZE.y * MapProjection.CITY_SCALE)  # 2471

func _fill(parent: Node2D, poly: PackedVector2Array, color: Color) -> void:
	var p := Polygon2D.new()
	p.polygon = poly
	p.color = color
	parent.add_child(p)

func _outline(parent: Node2D, poly: PackedVector2Array, color: Color, w: float) -> void:
	var l := Line2D.new()
	var pts := poly
	pts.append(poly[0])   # close the loop
	l.points = pts
	l.width = w
	l.default_color = color
	parent.add_child(l)

## A static collider for a closed polygon, tagged with `group` so tests can count blocks/water.
func _solid(parent: Node2D, poly: PackedVector2Array, group: String) -> void:
	var body := StaticBody2D.new()
	body.add_to_group(group)
	var col := CollisionPolygon2D.new()
	col.polygon = poly
	body.add_child(col)
	parent.add_child(body)

func _rect_poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end,
		Vector2(r.position.x, r.end.y)])

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

## A district's outline in world space, from its canonical map_polygon (x CITY_SCALE).
func _district_world_poly(d: Dictionary) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var raw: Array = d.get("map_polygon", [])
	for i in range(0, raw.size() - 1, 2):
		pts.append(MapProjection.map_to_world(Vector2(float(raw[i]), float(raw[i + 1]))))
	return pts

# --- Test/debug seams -------------------------------------------------------------------
## Number of solid building-block colliders realized from the layout data.
func city_block_count() -> int:
	return _count_in_group("city_block")

## Number of solid water-body colliders realized from the layout data.
func city_water_count() -> int:
	return _count_in_group("city_water")

func _count_in_group(group: String) -> int:
	var s: Node = get_node_or_null("Streetscape")
	if s == null:
		return 0
	var n := 0
	for c in s.get_children():
		if c.is_in_group(group):
			n += 1
	return n

## True once the streetscape has labeled the warehouse rite site.
func has_warehouse_marker() -> bool:
	var s: Node = get_node_or_null("Streetscape")
	if s == null:
		return false
	for c in s.get_children():
		if c is Label and (c as Label).text == "Warehouse":
			return true
	return false

## True once the rite-cache sabotage interactable has been placed.
func has_sabotage_point() -> bool:
	for c in get_children():
		if c.is_in_group("interactable") and bool(c.get("sabotage_cache")):
			return true
	return false

## True when the map underlay sprite is currently shown.
func underlay_visible() -> bool:
	var spr := get_node_or_null("MapUnderlay") as Sprite2D
	return spr != null and spr.visible

## Toggle the tracing underlay on/off (the vectors stay the source of truth either way).
func set_underlay_visible(v: bool) -> void:
	var spr := get_node_or_null("MapUnderlay") as Sprite2D
	if spr != null:
		spr.visible = v

## True when the player's camera has been limited to the full city rect.
func has_camera_bounds() -> bool:
	if _player == null:
		return false
	var cam := _player.get_node_or_null("Camera2D") as Camera2D
	return cam != null and cam.limit_right == int(MapProjection.MAP_SIZE.x * MapProjection.CITY_SCALE) \
		and cam.limit_bottom == int(MapProjection.MAP_SIZE.y * MapProjection.CITY_SCALE)

## Number of city-edge boundary walls.
func boundary_wall_count() -> int:
	var n := 0
	for c in get_children():
		if c.is_in_group("city_boundary"):
			n += 1
	return n

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

## The player's hands-on counter to the summoning: a sabotage point at the warehouse door. Walk up,
## press E, and one gathered ingredient is scattered (PlayerActions.sabotage_any) — setting the rite
## back. The cult re-gathers, so it is a tug-of-war, not a kill switch.
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
