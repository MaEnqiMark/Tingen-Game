extends Control
## Modal district map (GDD §19.3 / §20). Toggled with M. Draws Tingen's districts as
## filled zones tinted by live "risk" — a blend of each district's base risk and the
## citywide pressure it tracks — so the player can read where the night is going wrong
## without the simulation being spelled out in numbers.

const DISTRICTS_PATH: String = "res://data/districts.json"
const LOW_RISK := Color(0.25, 0.55, 0.35)
const HIGH_RISK := Color(0.85, 0.25, 0.25)

var districts: Array = []
var _hover_index: int = -1

@onready var _canvas: Control = $Center/Frame/VBox/Map
@onready var _readout: Label = $Center/Frame/VBox/Readout

func _ready() -> void:
	_load()
	visible = false
	_canvas.draw.connect(_draw_map)
	_canvas.gui_input.connect(_on_map_input)
	_canvas.mouse_exited.connect(func():
		_hover_index = -1
		_canvas.queue_redraw())
	WorldState.state_changed.connect(_canvas.queue_redraw)

func _load() -> void:
	if not FileAccess.file_exists(DISTRICTS_PATH):
		push_error("DistrictMap: missing %s" % DISTRICTS_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DISTRICTS_PATH))
	if typeof(parsed) == TYPE_ARRAY:
		districts = parsed

func toggle() -> void:
	visible = not visible
	if visible:
		_canvas.queue_redraw()

func _risk_for(d: Dictionary) -> float:
	var base: float = float(d.get("base_risk", 0.0))
	var pname := String(d.get("risk_pressure", ""))
	var pressure: float = WorldState.get_pressure(StringName(pname)) / 100.0 if pname != "" else 0.0
	return clampf(base + pressure * (1.0 - base), 0.0, 1.0)

func _poly_of(d: Dictionary) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var raw: Array = d.get("polygon", [])
	for i in range(0, raw.size() - 1, 2):
		pts.append(Vector2(float(raw[i]), float(raw[i + 1])))
	return pts

func _draw_map() -> void:
	_canvas.draw_rect(Rect2(Vector2.ZERO, _canvas.size), Color(0.07, 0.08, 0.11))
	for i in districts.size():
		var d: Dictionary = districts[i]
		var poly := _poly_of(d)
		if poly.size() < 3:
			continue
		var risk := _risk_for(d)
		var fill := LOW_RISK.lerp(HIGH_RISK, risk)
		fill.a = 0.55 if i != _hover_index else 0.85
		_canvas.draw_colored_polygon(poly, fill)
		var outline := poly
		outline.append(poly[0])
		_canvas.draw_polyline(outline, Color(0.9, 0.9, 0.95, 0.6), 1.5)
		var center := _centroid(poly)
		_canvas.draw_string(ThemeDB.fallback_font, center - Vector2(40, 0),
			String(d.get("name", d.get("id", "?"))), HORIZONTAL_ALIGNMENT_CENTER, 80, 12)

func _centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / poly.size()

func _on_map_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var prev := _hover_index
		_hover_index = -1
		for i in districts.size():
			if Geometry2D.is_point_in_polygon(event.position, _poly_of(districts[i])):
				_hover_index = i
				break
		if _hover_index != prev:
			_update_readout()
			_canvas.queue_redraw()

func _update_readout() -> void:
	if _hover_index < 0:
		_readout.text = "Hover a district to read its risk."
		return
	var d: Dictionary = districts[_hover_index]
	_readout.text = "%s — risk %d%% (%s)" % [
		String(d.get("name", "?")), int(_risk_for(d) * 100.0),
		String(d.get("risk_pressure", "—")),
	]
