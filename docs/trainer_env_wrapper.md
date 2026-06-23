# Implementing an environment wrapper for Bridge

Instructions for an AI/engineer building the **trainer side** that collects
experience from one or more Bridge environments. The canonical reference
implementation of the protocol is
`~/Godot/godot_rl_agents/godot_rl/core/godot_env.py` (class `GodotEnv`) —
read it alongside this guide. This document specifies exactly what Bridge sends
and expects, plus how to scale to several environments.

> **You usually do not need to reimplement the socket layer.** `GodotEnv`
> already speaks this protocol and works with Bridge unchanged. Prefer to *wrap*
> it (Section 6). The wire spec (Sections 3–5) is here so you can reimplement or
> debug it if your trainer can't depend on `godot_rl`.

---

## 1. Mental model: process = a vector of N environments

A single Bridge process hosts `N` agents (`AIController3D` nodes), each in its own
self-contained world. The `Sync` node discovers all of them and treats them as a
**vector**: it sends observations / rewards / dones as **arrays of length N**.

- `N` comes from `voxel_terrain.gd::NUM_ENVS` (default 4) or the `--n_envs=<N>`
  launch argument. The handshake reports it as `n_agents`.
- For more throughput, launch **K processes** (one per collector thread / Ray
  actor), each on its own TCP port. **Total environments = K × N.**

So a "wrapper that uses several Bridge environments" has two layers:

1. **Per-process** vector env over `N` agents (this is exactly `GodotEnv`).
2. **Vectorized aggregator** over `K` processes (Section 7) — stack the K arrays.

---

## 2. Launching a Bridge process

Connection model: **the trainer is the TCP server.** It binds a port and listens;
the Bridge process connects out to it. Launch the exported binary
(`build/bridge.x86_64`, see `README.md`) with:

| Argument | Read by | Meaning |
|---|---|---|
| `--port=<P>` | `sync.gd` | Port to connect back to (default `11008`). One per process. |
| `--n_envs=<N>` | `voxel_terrain.gd` | In-process environment count (Bridge-specific). |
| `--speedup=<S>` | `sync.gd` | Multiplies physics tick rate + time scale (faster collection). |
| `--action_repeat=<R>` | `sync.gd` | Apply each action for R physics frames (default 1 in Bridge). |
| `--env_seed=<seed>` | `sync.gd` | RNG seed for terrain / cube placement. |
| `--headless` | engine | Run with no window. |
| `--disable-render-loop` | engine | Skip rendering (training). |

Example for collector `i`:

```bash
build/bridge.x86_64 --headless --disable-render-loop \
    --port=$((11008 + i)) --n_envs=8 --speedup=8 --env_seed=$i
```

`GodotEnv` builds this command for you; any unknown `kwarg` you pass is forwarded
as `--key=value`, which is how `n_envs=8` reaches `voxel_terrain.gd`.

---

## 3. Wire protocol

**Framing (both directions):** a 4-byte **little-endian** unsigned length, then
that many bytes of **UTF-8 JSON**. (See `_send_string` / `_get_data` in
`godot_env.py`; Godot's `StreamPeer.put_string`/`get_string` use the same
length-prefixed format.)

**Sequence** (trainer = server; messages the trainer sends are marked →, replies
from Bridge ←):

1. Accept the TCP connection.
2. → `{"type":"handshake","major_version":"0","minor_version":"7"}`
   (use the versions from `GodotEnv.MAJOR_VERSION/MINOR_VERSION`, which must match
   `sync.gd`'s; a mismatch only logs a warning).
3. → `{"type":"env_info"}`
   ← `{"type":"env_info","n_agents":N,"observation_space":[...],"action_space":[...],"agent_policy_names":[...]}`
   The space arrays have one entry **per agent** (all identical for Bridge).
4. Then loop with `reset` / `action` and read the matching reply (Section 4).
5. → `{"type":"close"}` to shut the process down.

---

## 4. Stepping & resetting

**Reset all agents:**

- → `{"type":"reset"}`
- ← `{"type":"reset","obs":[obs_0, …, obs_{N-1}],"info":[…]}`

**Step:**

- → `{"type":"action","action":<actions>}` (encoding in Section 5)
- ← `{"type":"step","obs":[…],"reward":[r_0,…],"done":[d_0,…],"info":[…]}`

`obs`, `reward`, `done`, `info` are all **length-N arrays**, index = agent.
`reward` is float, `done` is bool. (`GodotEnv.step_recv` returns
`done` for both the `terminated` and `truncated` slots — Bridge does not
distinguish them.)

**Autoreset semantics — important.** Bridge resets each sub-env **internally** the
moment that agent reports `done` (`rl_agent_controller.gd::reset()` rebuilds that
env's terrain + clears blocks). You do **not** send a per-index reset. Treat it
like a Gym auto-resetting vector env: when `done[i]` is true, the `obs[i]` you
receive on subsequent steps belongs to env `i`'s **new** episode. Bookkeep the
terminal transition on your side from the `done` flag. (There is a known timing
caveat flagged in `sync.gd:220`; the behavior matches stock `godot_rl`, so reuse
its conventions rather than inventing new ones.) A `{"type":"reset"}` message
resets **all** agents at once.

---

## 5. Bridge's observation & action spaces

**Action space** (per agent): `{"act": {"size": 6, "action_type": "discrete"}}`
— a single `Discrete(6)`:

| value | effect |
|---|---|
| 0 / 1 | move cursor −x / +x |
| 2 / 3 | move cursor −z / +z |
| 4 | toggle block type (plate ↔ support) |
| 5 | place current block |

**Action encoding on the wire.** The `action` field is a list **per agent** of
action-head dicts: `[{"act": 3}, {"act": 0}, …]` (length N, values are plain
ints). If you use `GodotEnv.step(action)`, it expects `action` as
`action[head][agent]` (one inner list per head) and transposes it for you — Bridge
has a single head, so pass `[[a_0, a_1, …, a_{N-1}]]`.

**Observation space** (per agent): `{"map_2d": {"size": [6, 25, 25], "space": "box"}}`.
Because the key contains `"2d"`, the value on the wire is a **hex-encoded
uint8 buffer**, not a JSON array. Decode it (see `_decode_2d_obs_from_string`):

```python
import numpy as np
arr = np.frombuffer(bytes.fromhex(hex_string), dtype=np.uint8).reshape(6, 25, 25)
# Channel-major (C order): arr[channel, z, x]
```

The 6 channels: terrain, cubes, supports, and plates are top-surface heights in
0.1 m units (0 = empty); cursor marks the cursor's x/z cell, encoded with the
height its next block would land at (climbs as that column fills, ≥1 so it stays
visible); and a constant block-type plane (0 = plate, 255 = support). It's
identical regardless of an environment's world offset, so all N obs share the
same shape/meaning.

---

## 6. Reuse `GodotEnv` for one process (recommended)

```python
from godot_rl.core.godot_env import GodotEnv

env = GodotEnv(
    env_path="…/Bridge/build/bridge",  # no suffix; .x86_64 appended on Linux
    port=11008,
    n_envs=8,                # forwarded as --n_envs=8
    speedup=8,
    show_window=False,       # adds --headless --disable-render-loop
    convert_action_space=False,
)
assert env.num_envs == 8            # == n_agents reported by Bridge
obs, info = env.reset()             # obs: list of {"map_2d": np.uint8[6,25,25]}
action = [[a for _ in range(env.num_envs)]]   # one head, N agents
obs, reward, term, trunc, info = env.step(action)
env.close()
```

`env_path=None` connects to an editor session (press Play) instead of launching a
binary — handy for debugging, single process only.

---

## 7. Several environments: K collectors × N agents

Each collector owns one `GodotEnv` on a distinct port; aggregate their arrays.
The worked, correct reference for this is
`godot_rl/wrappers/stable_baselines_wrapper.py` (`StableBaselinesGodotEnv`) —
**copy its `step` plumbing rather than reinventing it.** The skeleton below is
schematic, to show the structure (ports, send-all-then-recv-all, flat
aggregation); the action-packing detail is deliberately left to Section 5 /
the SB3 wrapper:

```python
BASE_PORT = 11008

class BridgeVecEnv:
    """K Bridge processes × N in-process agents -> a flat vector of K*N envs."""
    def __init__(self, env_path, collectors=4, n_envs=8, **kw):
        self.envs = [
            GodotEnv(env_path=env_path, port=BASE_PORT + i, seed=i,
                     n_envs=n_envs, show_window=False,
                     convert_action_space=False, **kw)
            for i in range(collectors)
        ]
        self.num_envs = sum(e.num_envs for e in self.envs)
        self.per = self.envs[0].num_envs   # agents per process (== n_envs)

    def step(self, action):
        # Overlap network I/O: send to all, then receive from all. `action` must
        # be sliced/packed per collector in the layout GodotEnv.step expects
        # (Section 5 / StableBaselinesGodotEnv) — not shown here.
        for i, e in enumerate(self.envs):
            e.step_send(self._slice_for(action, i))
        obs, rew, term, trunc, info = [], [], [], [], []
        for e in self.envs:
            o, r, t, tr, inf = e.step_recv()
            obs += o; rew += r; term += t; trunc += tr; info += inf
        return obs, rew, term, trunc, info
```

- **Ports:** `BASE_PORT + collector_index`. Keep them unique across the whole
  trainer (Ray: derive from `worker_index`).
- **Threads vs Ray:** the per-collector body is identical — wrap `GodotEnv` in a
  `threading.Thread` target, or a `@ray.remote` actor. Sends/recvs overlap, so a
  thread blocked on a socket releases the GIL.
- **Action packing (`_slice_for`):** give each collector its `N`-agent slice in
  the same heads-major layout `GodotEnv.step` wants (Section 5). Mirror
  `StableBaselinesGodotEnv.step`, which slices `action[i*N:(i+1)*N]` from the
  policy's batched output.
- **Spaces:** every agent in every process has the same obs/action space, so the
  flat vector is homogeneous.

---

## 8. Checklist

- [ ] Build the binary (`README.md` → "Building the binary for a trainer").
- [ ] Trainer listens on `BASE_PORT + i`; launch one binary per collector with a
      matching `--port`.
- [ ] Handshake → `env_info`; read `n_agents` as the per-process env count.
- [ ] Decode `map_2d` from hex to `uint8[6,25,25]`; send actions as per-agent
      `{"act": int}` (or `[[…]]` heads-major via `GodotEnv.step`).
- [ ] Treat each sub-env as auto-resetting on its `done`; full `reset` resets all.
- [ ] Aggregate K processes into one flat `K×N` vector.
