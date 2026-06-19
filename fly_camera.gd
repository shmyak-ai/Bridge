extends Camera3D
## Free-fly spectator camera.
## Move: WASD horizontal, E/Q up/down, hold Shift to move faster.
## Look: hold the right mouse button and drag.

const SPEED := 8.0
const FAST_MULTIPLIER := 3.0
const MOUSE_SENS := 0.005

var _yaw := 0.0
var _pitch := 0.0

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# Sync from the current orientation so look starts where we point now.
		_yaw = rotation.y
		_pitch = rotation.x
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch -= event.relative.y * MOUSE_SENS
		_pitch = clampf(_pitch, -1.4, 1.4)
		rotation = Vector3(_pitch, _yaw, 0.0)

func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S): dir += transform.basis.z
	if Input.is_key_pressed(KEY_A): dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D): dir += transform.basis.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir += Vector3.DOWN
	if dir != Vector3.ZERO:
		var speed := SPEED
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= FAST_MULTIPLIER
		position += dir.normalized() * speed * delta
