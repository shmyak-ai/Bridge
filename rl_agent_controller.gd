extends AIController3D
## Reinforcement-learning agent for the bridge builder (godot_rl_agents).
## It drives the same BuildSystem a human does: move the grid cursor, switch
## block type, and place plates/supports to link the blue and red cubes.
##
## Observation: a 6 x 25 x 25 uint8 "image" (terrain, cubes, supports, slabs,
## cursor, and a constant block-type plane: 0 = PLATE, 255 = SUPPORT).
## Action: one discrete head of size 6 (move +/-x, +/-z, toggle, place).
## Reward: +1 whenever the blue<->red connecting distance reaches a new minimum
## at a connectable level, else 0 (see BuildSystem.compute_gap).

var bs: Node      # BuildSystem
var world: Node   # BridgeEnvironment (owns this env's world generation / reset)

var _best_gap := 1 << 30

func get_action_space() -> Dictionary:
	return {"act": {"size": 6, "action_type": "discrete"}}

func set_action(action) -> void:
	match int(action["act"]):
		0: bs.move_cursor(Vector3i(-1, 0, 0))
		1: bs.move_cursor(Vector3i(1, 0, 0))
		2: bs.move_cursor(Vector3i(0, 0, -1))
		3: bs.move_cursor(Vector3i(0, 0, 1))
		4: bs.toggle_type()
		5: bs.place()

func get_obs() -> Dictionary:
	return {"map_2d": bs.build_obs_image().hex_encode()}

func get_obs_space() -> Dictionary:
	return {"map_2d": {"size": bs.obs_image_shape(), "space": "box"}}

func get_reward() -> float:
	return reward

func get_info() -> Dictionary:
	return {"is_success": bs.is_won()}

func _physics_process(delta):
	super(delta)  # increments n_steps, sets needs_reset after reset_after

	# No step/time limit when a human is playing (explicit HUMAN mode or the
	# training fallback when no trainer is connected): only win/collapse resets.
	if heuristic == "human":
		needs_reset = false

	# Reward: +1 only when the connecting distance hits a new minimum.
	var gap: int = bs.compute_gap()
	if gap < _best_gap:
		reward += 1.0
		_best_gap = gap

	# Episode boundary: end (and self-reset) on win or collapse.
	if bs.is_won() or bs.is_collapsed():
		done = true
		needs_reset = true

	if needs_reset:
		reset()

func reset():
	super()  # n_steps = 0, needs_reset = false
	world.generate_world()  # fresh terrain + cube positions
	bs.rl_reset()           # clear placed blocks / state, cursor -> blue
	_best_gap = bs.compute_gap()  # baseline = Chebyshev(blue, red)
