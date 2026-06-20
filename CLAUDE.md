# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Godot 4.6 project ("Bridge") where an agent must connect two cubes (blue and red)
sitting on a procedurally generated voxel terrain by placing physics blocks (plates and
supports) to build a standing bridge between them. The game is driven either by a human
(keyboard) or by a reinforcement-learning agent via the `godot_rl_agents` addon.

- Engine: Godot **4.6**, Forward Plus renderer, **Jolt Physics**.
- Main scene: `voxel_terrain.tscn` (`uid://5xfrnni0gg0l`), a one-node scene with
  `voxel_terrain.gd` attached. Nearly everything (terrain, cubes, lighting, camera, HUD,
  build system, RL nodes) is built **in code at runtime**, not in the scene file.

## Running

- **Play/train**: open the project in Godot and run the main scene, or `project_run` via
  the `godot-ai` MCP. There is no separate build step.
- **RL control mode** is set in `voxel_terrain.gd::_setup_rl()` on the `Sync` node:
  - `Sync.ControlModes.TRAINING` (current default) — connects to a Python `godot_rl`
    trainer over TCP (default port `11008`, see `addons/godot_rl_agents/sync.gd`).
    The Godot side blocks waiting for the trainer, so launch the Python trainer to drive it.
  - `HUMAN` — play/test manually with the keyboard (see HUD controls in `build_system.gd`).
  - Switch this constant when you want to play by hand vs. train.

## Architecture

Four project scripts (everything else under `addons/` is third-party — `godot_ai` MCP
tooling and `godot_rl_agents`). The data flow is one orchestrator wiring up the rest:

- **`voxel_terrain.gd`** (`Node3D`, the main scene root) — orchestrator. Generates the
  GRID×GRID noise terrain (one column per meter, rendered as a `MultiMeshInstance3D` plus
  a matching `StaticBody3D` of per-column box colliders), places the two anchor cubes at
  random cells, sets up lighting and the fly camera, and creates the `BuildSystem`,
  `RLAgent`, and `Sync` nodes. `generate_world()` is the per-episode reset for the world.

- **`build_system.gd`** (`Node3D`) — all game logic and the RL observation. Owns the grid
  cursor, ghost preview, block placement, and win/lose detection (win = plates connect the
  two cubes and the structure stays still; loss = any block falls or topples). The
  human keyboard path (`_unhandled_input`) and the RL path (`move_cursor`/`toggle_type`/
  `place`) funnel into the same `_place()`. Also produces the agent's observation:
  `build_obs_image()` returns a `IMG_CHANNELS × IMG_SIZE × IMG_SIZE` uint8 top-down,
  channel-major image (heights encoded in `HEIGHT_UNIT` = 0.1 m steps).

- **`rl_agent_controller.gd`** (`AIController3D`) — the RL agent. Action space is one
  discrete head of size 8 (move ±x/±z/±y, toggle block, place); observation is the
  `build_system` image under obs key `map_2d`; reward is +1 each time the blue↔red
  connecting distance (`compute_gap`, Chebyshev) reaches a new minimum at a connectable
  level. On win/collapse it sets `done`/`needs_reset` and `reset()` rebuilds the world.

- **`fly_camera.gd`** (`Camera3D`) — spectator camera (WASD/EQ move, hold RMB to look).

Key wiring detail: `voxel_terrain.gd` injects world data (`heights`, `grid`, `blue_cell`,
`red_cell`, and the `bs`/`world` back-references) into `BuildSystem` and the controller
**before** those nodes enter the tree, so their `_ready()` sees populated state. If you add
fields that `_ready()` depends on, set them before `add_child()`.

Coordinate convention: integer `Vector3i` grid cells (x, y, z) where y is height in voxels;
`heights[x][z]` is the terrain top at a column. World positions are cell + 0.5 offsets.

## Conventions

- Pure GDScript, static typing throughout (`var x := ...`, typed params/returns). Match the
  existing `##` doc-comment style on functions and the section-divider comments.
- `.gitignore` excludes `/addons/` and `.godot/` — the addons are external tooling and are
  **not** versioned here. Don't commit changes inside `addons/`.

## Verifying GDScript changes

After editing a `.gd` file, check the editor/compiler diagnostics (e.g. via the `godot-ai`
MCP `logs_read` / reload) before claiming it works — do not trust a stale running instance.
