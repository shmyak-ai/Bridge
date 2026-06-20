extends Node3D
## Voxel terrain: a 25 x 25 m surface of 1x1x1 m columns whose heights come
## from coherent noise, giving natural-looking hills and hollows.

const GRID := 25          # surface is GRID x GRID meters (one column per meter)
const BASE := 1           # shortest column height, in voxels
const AMPLITUDE := 6      # tallest column is BASE + AMPLITUDE voxels
const NOISE_FREQ := 0.09 # lower = broad rolling hills, higher = choppier

# Column heights, filled in while building the terrain so the cubes know how
# high the surface is at any grid cell. _heights[x][z] = top height in meters.
var _heights: Array = []

# Grid cells the two anchor cubes occupy (set in _place_cubes), handed to the
# build system as the bridge's start/end points.
var blue_cell: Vector3i
var red_cell: Vector3i

# Nodes recreated each episode by generate_world(); kept so they can be freed.
var _voxel_surface: MultiMeshInstance3D
var _terrain_body: StaticBody3D
var _blue_cube: RigidBody3D
var _red_cube: RigidBody3D

# RL wiring (set up once in _setup_rl).
var _build_system: Node3D
var _controller: Node3D

func _ready() -> void:
	generate_world()
	_setup_lighting()
	_setup_player()
	_setup_rl()

## (Re)build the terrain and place the cubes. Called on start and on every
## episode reset, so each episode trains on fresh hills and cube positions.
func generate_world() -> void:
	_clear_world()
	_build_terrain()
	_place_cubes()
	if _build_system:
		_build_system.heights = _heights
		_build_system.blue_cell = blue_cell
		_build_system.red_cell = red_cell

func _clear_world() -> void:
	for n in [_voxel_surface, _terrain_body, _blue_cube, _red_cube]:
		if is_instance_valid(n):
			n.queue_free()

func _build_terrain() -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = NOISE_FREQ
	noise.seed = randi()  # fresh hills/hollows each run

	var box := BoxMesh.new()
	box.size = Vector3.ONE

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = GRID * GRID

	# Start every column list fresh so re-running gives new terrain.
	_heights = []
	for x in GRID:
		var row := []
		row.resize(GRID)
		_heights.append(row)

	var i := 0
	for x in GRID:
		for z in GRID:
			var n := noise.get_noise_2d(float(x), float(z))        # -1..1
			var h := BASE + int(round((n * 0.5 + 0.5) * AMPLITUDE)) # voxel height
			_heights[x][z] = h
			# A box of unit size scaled in Y, sitting on the ground (y = 0).
			var b := Basis().scaled(Vector3(1.0, float(h), 1.0))
			var origin := Vector3(x + 0.5, h * 0.5, z + 0.5)
			mm.set_instance_transform(i, Transform3D(b, origin))
			mm.set_instance_color(i, _color_for(h))
			i += 1

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true  # use the per-instance colors

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "VoxelSurface"
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)
	_voxel_surface = mmi

	# The MultiMesh above is only visual. Give the terrain a matching solid
	# body (one box collider per column) so the physics cubes rest on it
	# instead of falling through.
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	for x in GRID:
		for z in GRID:
			var h: int = _heights[x][z]
			var shape := BoxShape3D.new()
			shape.size = Vector3(1.0, float(h), 1.0)
			var cs := CollisionShape3D.new()
			cs.shape = shape
			cs.position = Vector3(x + 0.5, h * 0.5, z + 0.5)
			body.add_child(cs)
	add_child(body)
	_terrain_body = body

func _place_cubes() -> void:
	# Two different random grid cells, so the cubes never overlap.
	var a := Vector2i(randi() % GRID, randi() % GRID)
	var b := a
	while b == a:
		b = Vector2i(randi() % GRID, randi() % GRID)

	_blue_cube = _add_cube("BlueCube", a, Color(0.15, 0.35, 0.90))
	_red_cube = _add_cube("RedCube", b, Color(0.90, 0.20, 0.15))
	blue_cell = _cell_for(a)
	red_cell = _cell_for(b)

func _cell_for(cell: Vector2i) -> Vector3i:
	# The cube's base sits on the column top, so it occupies the row at y = top.
	var top: int = _heights[cell.x][cell.y]
	return Vector3i(cell.x, top, cell.y)

func _add_cube(node_name: String, cell: Vector2i, color: Color) -> RigidBody3D:
	var cube := RigidBody3D.new()
	cube.name = node_name
	cube.freeze = true  # fixed anchor: keeps collision but never moves

	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE  # 1 x 1 x 1 m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	cube.add_child(mi)

	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cube.add_child(cs)

	# Rest the cube on the surface at this cell (bottom on the column top).
	var top: int = _heights[cell.x][cell.y]
	cube.position = Vector3(cell.x + 0.5, top + 0.5, cell.y + 0.5)
	add_child(cube)
	return cube

func _color_for(h: int) -> Color:
	# Valley green up to hilltop light green.
	var t := clampf(float(h - BASE) / float(AMPLITUDE), 0.0, 1.0)
	return Color(0.20, 0.42, 0.16).lerp(Color(0.58, 0.76, 0.38), t)

func _setup_lighting() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.68, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.60, 0.70, 0.85)
	env.ambient_light_energy = 0.5
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -45, 0)
	sun.shadow_enabled = true
	add_child(sun)

func _setup_player() -> void:
	# Free-fly camera the player navigates with.
	var cam := Camera3D.new()
	cam.set_script(load("res://fly_camera.gd"))
	add_child(cam)
	cam.position = Vector3(GRID + 8, GRID * 0.8, GRID + 8)
	cam.look_at(Vector3(GRID * 0.5, 3.0, GRID * 0.5), Vector3.UP)
	cam.current = true

## Build system + the godot_rl_agents Sync/agent nodes. Created once; the agent
## resets the world in-place each episode instead of recreating these.
func _setup_rl() -> void:
	# Build system: grid cursor, block placement, win/lose. Hand it the world
	# data it needs before it enters the tree (so its _ready sees it).
	_build_system = Node3D.new()
	_build_system.name = "BuildSystem"
	_build_system.set_script(load("res://build_system.gd"))
	_build_system.heights = _heights
	_build_system.grid = GRID
	_build_system.blue_cell = blue_cell
	_build_system.red_cell = red_cell
	add_child(_build_system)

	# RL agent (extends AIController3D). Wire its world refs before it enters the
	# tree, then it adds itself to the "AGENT" group in _ready.
	_controller = load("res://rl_agent_controller.gd").new()
	_controller.name = "RLAgent"
	_controller.bs = _build_system
	_controller.world = self
	_build_system.add_child(_controller)

	# Sync node: bridges the agent(s) to the Python trainer. Switch control_mode
	# to TRAINING to connect to the godot_rl server; HUMAN lets you play/test.
	var sync := Sync.new()
	sync.name = "Sync"
	sync.control_mode = Sync.ControlModes.TRAINING
	sync.action_repeat = 1
	add_child(sync)
