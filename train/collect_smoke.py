#!/usr/bin/env python
"""Reference harness for driving the Bridge game's vectorized environments.

This is a *template* for the custom trainer, not the trainer itself. It uses
godot_rl's stable `GodotEnv` protocol (the same one the custom env wrapper
mirrors) to validate the two parallelism axes the project now supports:

  1. In-process vectorization
       One Godot process hosts N environments (N agents in the "AGENT" group).
       `env.num_envs == N`. Pass `--n_envs N`; the value is forwarded to the
       launched binary as `--n_envs=N` (voxel_terrain.gd reads it).

  2. Parallel collectors
       Several `GodotEnv` instances, each launching its own headless binary on
       a unique port (`base_port + i`), one per collector thread. Mirrors the
       "collectors in different threads / ray processes" setup -- swap
       threading.Thread for ray.remote actors and the per-collector body is
       identical.

Total environments = collectors x n_envs.

Examples
--------
Editor mode (press Play in Godot first; single process, N baked into the scene):
    python train/collect_smoke.py

Exported binary, 1 process x 8 in-process envs:
    python train/collect_smoke.py --env_path build/bridge --n_envs 8

Exported binary, 4 collector threads x 8 envs each (= 32 envs), 8x speedup:
    python train/collect_smoke.py --env_path build/bridge \
        --n_envs 8 --collectors 4 --speedup 8

Run with the godot_rl venv:
    ~/Godot/godot_rl_agents/.venv/bin/python train/collect_smoke.py ...
"""

import argparse
import random
import threading

from godot_rl.core.godot_env import GodotEnv


def run_collector(collector_id: int, args) -> None:
    """One collector: own GodotEnv (own port + own headless binary), N envs."""
    port = GodotEnv.DEFAULT_PORT + collector_id

    # `n_envs` is forwarded to the binary as `--n_envs=<N>` (a GodotEnv kwarg
    # becomes a `--key=value` launch arg). It only takes effect when a binary is
    # launched; in editor mode the scene's NUM_ENVS constant decides instead.
    kwargs = {}
    if args.env_path is not None:
        kwargs["n_envs"] = args.n_envs

    env = GodotEnv(
        env_path=args.env_path,
        port=port,
        show_window=False,
        seed=collector_id,
        speedup=args.speedup if args.env_path is not None else None,
        convert_action_space=False,
        **kwargs,
    )

    n = env.num_envs  # number of in-process agents this process exposes
    print(f"[collector {collector_id}] connected on port {port}, num_envs={n}")
    print(f"[collector {collector_id}] obs space: {env.observation_space}")
    print(f"[collector {collector_id}] action space: {env.action_space}")

    env.reset()
    for step in range(args.steps):
        # Action layout expected by GodotEnv.step: one list per action head,
        # each holding one value per agent. Bridge has a single discrete head
        # "act" of size 6 -> a single inner list of N ints.
        action = [[random.randint(0, 5) for _ in range(n)]]
        obs, reward, term, trunc, info = env.step(action)
        assert len(reward) == n, f"expected {n} rewards, got {len(reward)}"
        assert len(term) == n
        if step == 0:
            shape = obs[0]["map_2d"].shape
            print(f"[collector {collector_id}] step ok: obs map_2d shape={shape}, "
                  f"reward len={len(reward)}")

    env.close()
    print(f"[collector {collector_id}] done ({args.steps} steps)")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--env_path", default=None,
                   help="Path to the exported binary (without suffix, e.g. "
                        "build/bridge). Omit to connect to the editor (Play).")
    p.add_argument("--n_envs", type=int, default=4,
                   help="In-process environments per collector (forwarded to "
                        "the binary as --n_envs). Ignored in editor mode.")
    p.add_argument("--collectors", type=int, default=1,
                   help="Parallel collector threads, each its own process/port.")
    p.add_argument("--speedup", type=int, default=1,
                   help="Physics speedup for launched binaries.")
    p.add_argument("--steps", type=int, default=50,
                   help="Random steps each collector takes.")
    args = p.parse_args()

    if args.env_path is None and args.collectors > 1:
        p.error("--collectors > 1 requires --env_path (cannot launch the editor "
                "multiple times; press Play once for a single collector).")

    if args.collectors == 1:
        run_collector(0, args)
        return

    threads = [threading.Thread(target=run_collector, args=(i, args))
               for i in range(args.collectors)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    total = args.collectors * args.n_envs
    print(f"all collectors done: {args.collectors} x {args.n_envs} = {total} envs")


if __name__ == "__main__":
    main()
