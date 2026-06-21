extends Node3D
## Bridge build system: a 1 m grid cursor, a ghost preview, and placement of
## two physics block types (plate / support). Watches for the win (plates link
## the blue and red cubes and the structure stays standing) and the loss (any
## placed block falls or topples = collapse).

# --- Injected by voxel_terrain.gd before this node enters the tree ---
var heights: Array = []          # heights[x][z] = terrain column height
var grid := 25                   # terrain is grid x grid cells
var blue_cell := Vector3i.ZERO   # cell occupied by the blue cube
var red_cell := Vector3i.ZERO    # cell occupied by the red cube
var show_hud := true             # only one env draws the on-screen HUD overlay

enum BlockType { PLATE, SUPPORT }
enum GameState { BUILDING, WON, COLLAPSED }

const PLATE_SIZE := Vector3(1.0, 0.1, 1.0)
const SUPPORT_SIZE := Vector3(0.1, 1.0, 0.1)
const PLATE_COLOR := Color(0.85, 0.80, 0.20)
const SUPPORT_COLOR := Color(0.60, 0.40, 0.20)

const FAIL_Y := -3.0          # below this = block fell off the world
const COLLAPSE_DIST := 1.0    # moved this far from where placed = toppled
const V_STILL := 0.15         # speed under this counts as "at rest"
const STABLE_TIME := 1.0      # must stay connected + still this long to win

# --- RL observation image (godot_rl_agents) --------------------------------
# A top-down, multi-channel uint8 "image" of the board, one pixel per grid
# cell (native GRID x GRID, no padding). Each pixel stores a top-surface height
# in 0.1 m units (0 = empty), matching the smallest object (0.1 m plates) while
# terrain steps are 1 m.
const IMG_SIZE := 25
const IMG_CHANNELS := 6        # terrain, cubes, supports, slabs, cursor, block type
const HEIGHT_UNIT := 0.1       # discretization: 1 byte = 0.1 m (max 25.5 m)

var _cursor := Vector3i.ZERO
var _current: int = BlockType.PLATE
var _state: int = GameState.BUILDING
var _stable_timer := 0.0

var _occupied := {}        # Vector3i -> true, cells filled by placed blocks
var _plate_cells := {}     # Vector3i -> true, plate cells only (for connectivity)
var _support_cells := {}   # Vector3i -> true, support cells only (for the obs image)
var _blocks := []          # [{node: RigidBody3D, spawn: Vector3}]

var _ghost: MeshInstance3D
var _hud_type: Label
var _hud_cursor: Label
var _hud_status: Label

func _ready() -> void:
	_cursor = blue_cell
	_make_ghost()
	if show_hud:
		_make_hud()
	_update_hud()

# --- Input -----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_R:
		if _state != GameState.BUILDING:
			get_tree().reload_current_scene()
		return
	if _state != GameState.BUILDING:
		return
	match event.keycode:
		KEY_LEFT: _cursor.x -= 1
		KEY_RIGHT: _cursor.x += 1
		KEY_UP: _cursor.z -= 1
		KEY_DOWN: _cursor.z += 1
		KEY_PAGEUP: _cursor.y += 1
		KEY_PAGEDOWN: _cursor.y -= 1
		KEY_TAB:
			_current = BlockType.SUPPORT if _current == BlockType.PLATE else BlockType.PLATE
			(_ghost.mesh as BoxMesh).size = _size_for(_current)
		KEY_ENTER, KEY_KP_ENTER:
			_place()
	_update_hud()

# --- Placement -------------------------------------------------------------

func _place() -> void:
	var cell := _resolve(_cursor)
	var type := _current
	var size := _size_for(type)

	var body := RigidBody3D.new()
	var phys := PhysicsMaterial.new()
	phys.friction = 1.0
	body.physics_material_override = phys

	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = PLATE_COLOR if type == BlockType.PLATE else SUPPORT_COLOR
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)

	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)

	var pos := _world_pos(cell, type)
	body.position = pos
	add_child(body)

	_occupied[cell] = true
	_blocks.append({"node": body, "spawn": pos})
	if type == BlockType.PLATE:
		_plate_cells[cell] = true
	else:
		_support_cells[cell] = true

func _resolve(cell: Vector3i) -> Vector3i:
	var c := cell
	if _is_occupied(c):
		# "If a block is already there, put the new one just above."
		while _is_occupied(c):
			c.y += 1
		return c
	# Empty cell: let the block settle onto the first surface below it, so a
	# block carried out over a hollow rests on the ground instead of floating
	# in mid-air and falling (which would end the game).
	while c.y > 0 and not _is_occupied(c - Vector3i(0, 1, 0)):
		c.y -= 1
	return c

func _is_occupied(cell: Vector3i) -> bool:
	if _in_anchor_stack(cell, blue_cell) or _in_anchor_stack(cell, red_cell):
		return true
	if _occupied.has(cell):
		return true
	if cell.x >= 0 and cell.x < grid and cell.z >= 0 and cell.z < grid:
		var h: int = heights[cell.x][cell.z]
		if cell.y >= 0 and cell.y < h:
			return true
	return false

## The anchor cube and the filler cubes beneath it fill the column from the
## terrain top up to (and including) the anchor row.
func _in_anchor_stack(cell: Vector3i, anchor: Vector3i) -> bool:
	return cell.x == anchor.x and cell.z == anchor.z \
		and cell.y >= heights[anchor.x][anchor.z] and cell.y <= anchor.y

func _size_for(type: int) -> Vector3:
	return PLATE_SIZE if type == BlockType.PLATE else SUPPORT_SIZE

func _world_pos(cell: Vector3i, type: int) -> Vector3:
	# Plate sits at the floor of its cell; support fills the cell.
	var y := float(cell.y) + (0.05 if type == BlockType.PLATE else 0.5)
	return Vector3(cell.x + 0.5, y, cell.z + 0.5)

# --- Win / lose ------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_ghost.visible = _state == GameState.BUILDING
	if _state != GameState.BUILDING:
		return
	# Positions are kept local to this BuildSystem so they stay correct when the
	# environment is placed at an X/Z offset (one of many in the same scene).
	_ghost.position = _world_pos(_resolve(_cursor), _current)

	for b in _blocks:
		var node: RigidBody3D = b["node"]
		if node.position.y < FAIL_Y or node.position.distance_to(b["spawn"]) > COLLAPSE_DIST:
			_set_state(GameState.COLLAPSED)
			return

	if _is_connected() and _all_still():
		_stable_timer += delta
		if _stable_timer >= STABLE_TIME:
			_set_state(GameState.WON)
	else:
		_stable_timer = 0.0

func _all_still() -> bool:
	for b in _blocks:
		if (b["node"] as RigidBody3D).linear_velocity.length() > V_STILL:
			return false
	return true

func _is_connected() -> bool:
	if _plate_cells.is_empty():
		return false
	var blue_seeds := []
	var red_seeds := {}
	for cell in _plate_cells:
		if _chebyshev(cell, blue_cell) <= 1:
			blue_seeds.append(cell)
		if _chebyshev(cell, red_cell) <= 1:
			red_seeds[cell] = true
	if blue_seeds.is_empty() or red_seeds.is_empty():
		return false

	var visited := {}
	var queue := []
	for s in blue_seeds:
		visited[s] = true
		queue.append(s)
	while not queue.is_empty():
		var c: Vector3i = queue.pop_back()
		if red_seeds.has(c):
			return true
		for nb in _neighbors(c):
			if _plate_cells.has(nb) and not visited.has(nb):
				visited[nb] = true
				queue.append(nb)
	return false

func _neighbors(c: Vector3i) -> Array:
	var result := []
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				result.append(c + Vector3i(dx, dy, dz))
	return result

func _chebyshev(a: Vector3i, b: Vector3i) -> int:
	return maxi(abs(a.x - b.x), maxi(abs(a.y - b.y), abs(a.z - b.z)))

func _set_state(state: int) -> void:
	_state = state
	_update_hud()

# --- Ghost + HUD -----------------------------------------------------------

func _make_ghost() -> void:
	_ghost = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = _size_for(_current)
	_ghost.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.4)
	_ghost.material_override = mat
	add_child(_ghost)

func _make_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var box := VBoxContainer.new()
	box.position = Vector2(16, 16)
	layer.add_child(box)
	_hud_type = _new_label(box)
	_hud_cursor = _new_label(box)
	_hud_status = _new_label(box)
	var controls := _new_label(box)
	controls.text = "Move: WASD  E/Q  (Shift=fast)   Look: hold Right Mouse\nCursor: Arrows + PageUp/PageDown   Tab: switch block   Enter: place   R: restart"

func _new_label(parent: Node) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	parent.add_child(l)
	return l

func _update_hud() -> void:
	if not show_hud:
		return
	var tname := "PLATE (1 x 0.1 x 1)" if _current == BlockType.PLATE else "SUPPORT (0.1 x 1 x 0.1)"
	_hud_type.text = "Block: " + tname
	var rc := _resolve(_cursor)
	_hud_cursor.text = "Cursor: (%d, %d, %d)  ->  lands at y=%d" % [_cursor.x, _cursor.y, _cursor.z, rc.y]
	match _state:
		GameState.WON: _hud_status.text = "CONNECTED - YOU WIN!   (R to restart)"
		GameState.COLLAPSED: _hud_status.text = "COLLAPSED!   (R to restart)"
		_: _hud_status.text = "Status: building..."

# --- RL agent API (driven by rl_agent_controller.gd) -----------------------
# These mirror the keyboard actions so a training agent and a human use the
# same placement code path.

func move_cursor(d: Vector3i) -> void:
	_cursor += d
	_update_hud()

func toggle_type() -> void:
	_current = BlockType.SUPPORT if _current == BlockType.PLATE else BlockType.PLATE
	(_ghost.mesh as BoxMesh).size = _size_for(_current)
	_update_hud()

func place() -> void:
	_place()
	_update_hud()

func current_block_type() -> int:
	return _current

func is_won() -> bool:
	return _state == GameState.WON

func is_collapsed() -> bool:
	return _state == GameState.COLLAPSED

## Clear all placed blocks and game state for a fresh episode. Terrain and cube
## cells are refreshed separately by voxel_terrain.generate_world() before this.
func rl_reset() -> void:
	for b in _blocks:
		(b["node"] as Node).queue_free()
	_blocks.clear()
	_occupied.clear()
	_plate_cells.clear()
	_support_cells.clear()
	_cursor = blue_cell
	_state = GameState.BUILDING
	_stable_timer = 0.0
	if _ghost:
		_update_hud()

## Symmetric Chebyshev distance between the two slab fronts growing from the
## cubes: min distance between {blue + its connected plates} and {red + its
## connected plates}. Chebyshev includes the y axis, so a decrease only counts
## when the fronts approach at a connectable ("same") level. <= 1 means linked.
func compute_gap() -> int:
	var blue_pts := _component_from(blue_cell).keys()
	blue_pts.append(blue_cell)
	var red_pts := _component_from(red_cell).keys()
	red_pts.append(red_cell)
	var best := 1 << 30
	for a in blue_pts:
		for b in red_pts:
			var d := _chebyshev(a, b)
			if d < best:
				best = d
	return best

## Plate cells reachable from a cube via Chebyshev-adjacent plate steps.
func _component_from(cube_cell: Vector3i) -> Dictionary:
	var comp := {}
	var queue := []
	for cell in _plate_cells:
		if _chebyshev(cell, cube_cell) <= 1:
			comp[cell] = true
			queue.append(cell)
	while not queue.is_empty():
		var c: Vector3i = queue.pop_back()
		for nb in _neighbors(c):
			if _plate_cells.has(nb) and not comp.has(nb):
				comp[nb] = true
				queue.append(nb)
	return comp

## [channels, height, width] of the observation image, for get_obs_space().
func obs_image_shape() -> Array:
	return [IMG_CHANNELS, IMG_SIZE, IMG_SIZE]

## IMG_CHANNELS x IMG_SIZE x IMG_SIZE uint8 buffer, channel-major, ready to
## hex_encode() and send under a "..._2d" obs key.
func build_obs_image() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(IMG_CHANNELS * IMG_SIZE * IMG_SIZE)  # resize() zero-fills

	# ch0: terrain top height
	for x in grid:
		for z in grid:
			_set_px(buf, 0, x, z, _enc(float(heights[x][z])))
	# ch1: blue/red cube top surfaces (cube base on its column top, 1 m tall)
	_set_px(buf, 1, blue_cell.x, blue_cell.z, _enc(float(blue_cell.y) + 1.0))
	_set_px(buf, 1, red_cell.x, red_cell.z, _enc(float(red_cell.y) + 1.0))
	# ch2: highest support top per column
	for cell in _support_cells:
		_max_px(buf, 2, cell.x, cell.z, _enc(float(cell.y) + 1.0))
	# ch3: highest plate top per column
	for cell in _plate_cells:
		_max_px(buf, 3, cell.x, cell.z, _enc(float(cell.y) + PLATE_SIZE.y))
	# ch4: cursor cell (>=1 so it is always visible, even at y = 0)
	_set_px(buf, 4, _cursor.x, _cursor.z, maxi(1, _enc(float(_cursor.y))))
	# ch5: selected block type as a constant plane (0 = PLATE, 255 = SUPPORT)
	var type_val := _current * 255
	var base := 5 * IMG_SIZE * IMG_SIZE
	for i in IMG_SIZE * IMG_SIZE:
		buf[base + i] = type_val
	return buf

func _enc(height_m: float) -> int:
	return clampi(int(round(height_m / HEIGHT_UNIT)), 0, 255)

func _px_index(c: int, x: int, z: int) -> int:
	return c * IMG_SIZE * IMG_SIZE + z * IMG_SIZE + x

func _set_px(buf: PackedByteArray, c: int, x: int, z: int, v: int) -> void:
	if x < 0 or x >= IMG_SIZE or z < 0 or z >= IMG_SIZE:
		return
	buf[_px_index(c, x, z)] = v

func _max_px(buf: PackedByteArray, c: int, x: int, z: int, v: int) -> void:
	if x < 0 or x >= IMG_SIZE or z < 0 or z >= IMG_SIZE:
		return
	var i := _px_index(c, x, z)
	if v > buf[i]:
		buf[i] = v
