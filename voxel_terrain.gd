extends Node3D
## Orchestrator for the bridge builder. Hosts a vector of independent
## environments (each a self-contained terrain + cubes + BuildSystem + RLAgent,
## see environment.gd) laid out side by side so one Godot process exposes
## NUM_ENVS environments to the trainer. Shared across all of them: one set of
## lighting, one spectator camera, and one godot_rl Sync node (which discovers
## every agent in the "AGENT" group and bridges them to the Python trainer).

# Single source of truth for how this process runs. Switch to
# Sync.ControlModes.HUMAN to play by hand, TRAINING to connect to the trainer.
# HUMAN forces a single environment (keyboard drives one world, no idle extras).
var CONTROL_MODE := Sync.ControlModes.TRAINING

# How many environments to host in this process (TRAINING only). Overridable at
# launch with --n_envs=<N> (the trainer passes extra GodotEnv kwargs through as
# --key=value), so an exported binary can vary the count without re-exporting.
const NUM_ENVS := 4
const ENV_GAP := 4        # meters of empty space between adjacent environments

# Preloaded by path (not via the global class_name) so it resolves regardless of
# the editor's global-class registration state.
const EnvScene := preload("res://environment.gd")

func _ready() -> void:
	_setup_lighting()
	_setup_player()
	_setup_rl()

## Lay out the environments on a near-square grid, then add a single Sync node
## last so its _get_agents() sees every agent already in the tree.
func _setup_rl() -> void:
	# HUMAN play controls a single world; training hosts the full vector.
	var n := 1 if CONTROL_MODE == Sync.ControlModes.HUMAN else _env_count()
	var stride := environment_size() + ENV_GAP
	var cols := int(ceil(sqrt(float(n))))

	for i in n:
		var env := EnvScene.new()
		env.name = "Env%d" % i
		env.env_index = i
		# Spread environments out in X/Z only (Y is shared with the fall plane).
		var col := i % cols
		var row := i / cols
		env.position = Vector3(col * stride, 0.0, row * stride)
		add_child(env)
		env.setup()

	# Sync node: bridges all agents to the Python trainer (TRAINING), or lets you
	# drive the single environment by keyboard (HUMAN). See CONTROL_MODE above.
	var sync := Sync.new()
	sync.name = "Sync"
	sync.control_mode = CONTROL_MODE
	sync.action_repeat = 1
	add_child(sync)

## NUM_ENVS, or the --n_envs=<N> launch argument when present.
func _env_count() -> int:
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--n_envs="):
			return maxi(1, arg.split("=")[1].to_int())
	return NUM_ENVS

## Footprint of one environment in meters (its GRID), for the layout stride.
func environment_size() -> int:
	return EnvScene.GRID

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
	# Free-fly camera the player navigates with, aimed at the first environment.
	var size := environment_size()
	var cam := Camera3D.new()
	cam.set_script(load("res://fly_camera.gd"))
	add_child(cam)
	cam.position = Vector3(size + 8, size * 0.8, size + 8)
	cam.look_at(Vector3(size * 0.5, 3.0, size * 0.5), Vector3.UP)
	cam.current = true
