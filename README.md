# Bridge

A Godot 4.6 reinforcement-learning environment. An agent must connect two cubes
(blue and red) sitting on a procedurally generated voxel terrain by placing
physics blocks — flat **plates** and thin **supports** — to build a structure
that links them and stays standing. Episodes end on a **win** (the cubes are
connected by plates and the structure is at rest) or a **collapse** (any placed
block falls or topples).

The game is driven either by a human (keyboard) or by an RL agent through the
[`godot_rl_agents`](https://github.com/edbeeching/godot_rl_agents) addon. A single
Godot process hosts **N independent environments** at once (each its own terrain,
cubes and agent), so one process is already a vectorized environment of size N.

- Engine: Godot **4.6**, Forward Plus renderer, **Jolt Physics**.
- Observation: a `6 × 25 × 25` uint8 top-down image (`map_2d`).
- Action: one discrete head of size 6 (move cursor ±x/±z, toggle block, place).

See `CLAUDE.md` for the code architecture.

## Running in the editor

Open the project in Godot 4.6 and run the main scene (`voxel_terrain.tscn`). The
run mode is the `CONTROL_MODE` variable at the top of `voxel_terrain.gd`:

- `Sync.ControlModes.HUMAN` — play by hand (auto-runs a **single** environment).
  Controls are shown in the on-screen HUD.
- `Sync.ControlModes.TRAINING` (default) — connect to a Python trainer over TCP
  (port `11008`). With no trainer listening it falls back to human controls.

The in-process environment count is `NUM_ENVS` (default 4), overridable at launch
with `--n_envs=<N>`.

## Building the binary for a trainer

A trainer that collects experience in parallel launches **exported binaries**
(one per collector/process), so you need to export the game once.

1. **Install export templates** for Godot 4.6 (one-time, the usual blocker):
   in the editor, *Editor → Manage Export Templates → Download and Install*.
   They must match your editor version (e.g. 4.6.3). Until installed, export is
   disabled.
2. **Export from the GUI** (recommended): *Project → Export…* — the `Linux`
   preset is already present (from `export_presets.cfg`) with its path set to
   `build/bridge.x86_64`. Select it, click **Export Project…**, and **uncheck
   "Export With Debug"** for a release build. The preset has `embed_pck=true`, so
   this produces a single self-contained `build/bridge.x86_64` (untick **Embed
   PCK** if you'd rather have a separate `build/bridge.pck` beside it).
3. **Or export headlessly** from a terminal. `godot` is usually not on `PATH`, so
   call your Godot 4.6 binary directly (adjust the name to yours):

   ```bash
   mkdir -p build
   ~/Godot/<godot-4.6-binary> --headless --export-release "Linux" build/bridge.x86_64
   ```

   Optionally symlink it so the bare `godot` command works:
   `ln -s ~/Godot/<godot-4.6-binary> ~/.local/bin/godot`.
4. The trainer points at the binary **without** the suffix — `godot_rl`'s
   `GodotEnv` appends `.x86_64` itself:

   ```python
   GodotEnv(env_path="path/to/Bridge/build/bridge", port=11008, n_envs=8, show_window=False)
   ```

Tip: add `build/` to `.gitignore` — the exported binary is a build artifact.

## Training against it

Each collector launches one binary on its own port (`11008 + i`) and talks the
`godot_rl` TCP protocol. A Bridge process exposes `n_agents == N` environments,
so total envs = `collectors × N`. `train/collect_smoke.py` is a small reference
harness.

To **implement an environment wrapper** for the trainer (one that drives several
Bridge environments / collectors), follow `docs/trainer_env_wrapper.md`.
