class_name MapProjection
extends RefCounted
## Pure, static, node-free coordinate math for the district map panel. Three spaces:
##   • World space     — the streetscape coords the player/agents already live in.
##   • Map-image space — tingen_map.png pixels (MAP_SIZE). The canonical anchor space:
##     district map_polygons and the player tracker are all expressed here.
##   • Canvas space    — the panel's Map control pixels (runtime-sized).
## Two transforms move between them; canvas_to_image is the exact inverse of image_to_canvas.
## This is the headless-testable seam under the thin DistrictMap view (mirrors EndGameResolver).

const MAP_SIZE := Vector2(1000.0, 706.0)
## The Iron Cross streetscape occupies this world-space rect …
const STREETSCAPE_SOURCE := Rect2(120.0, 140.0, 660.0, 460.0)
## … and maps linearly onto this map-image-space rect (the Iron Cross region on the map art).
const IRON_CROSS_DEST := Rect2(430.0, 300.0, 170.0, 140.0)
## The rite / 降临 site in world space; its map marker = world_to_map(WAREHOUSE_WORLD).
const WAREHOUSE_WORLD := Vector2(420.0, 360.0)

## World → map-image: linearly remap STREETSCAPE_SOURCE onto IRON_CROSS_DEST.
static func world_to_map(world_pos: Vector2) -> Vector2:
	var u: Vector2 = (world_pos - STREETSCAPE_SOURCE.position) / STREETSCAPE_SOURCE.size
	return IRON_CROSS_DEST.position + u * IRON_CROSS_DEST.size
