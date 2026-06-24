#!/usr/bin/env python3
"""Compute a single analysis metric and emit a PNG + JSON summary.

Usage:
    analyze.py <run_dir> <metric>

Metrics:
    rmsd        backbone RMSD vs minimized structure, from prod/md.xtc
    potential   potential energy time series from prod/md.edr
    temperature temperature time series from prod/md.edr

The script invokes `gmx rms` / `gmx energy` inside the GROMACS container so
we don't need MDAnalysis or any Python MD libs on the host. We then plot
the resulting xvg files with matplotlib.

Output goes to <run_dir>/analysis/{metric}.png and is summarized on stdout
as a single JSON line for the agent to parse.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


IMAGE = os.environ.get("GMX_IMAGE", "gromacs-demo:latest")
GPU_VENDOR = os.environ.get("GPU_VENDOR", "nvidia")

# Pick docker --device / --gpus flags based on the GPU vendor. Mirrors
# workflow/_runtime.sh so we don't end up with the host trying to attach
# an NVIDIA runtime to an AMD image (or vice versa). Analysis doesn't need
# GPU, but the image expects to be runnable regardless.
_DOCKER_GPU_ARGS: dict[str, list[str]] = {
    "nvidia": ["--gpus", "all"],
    "amd": [
        "--device=/dev/kfd",
        "--device=/dev/dri",
        "--group-add", "video",
        "--security-opt", "seccomp=unconfined",
    ],
    "cpu": [],
}


def gmx(run_dir: Path, *args: str, stdin: str = "") -> str:
    cmd = [
        "docker", "run", "--rm",
        *_DOCKER_GPU_ARGS.get(GPU_VENDOR, []),
        "-v", "/data:/data",
        "-w", str(run_dir),
        "-i", IMAGE,
        "gmx", *args,
    ]
    res = subprocess.run(cmd, input=stdin, text=True, capture_output=True, check=True)
    return res.stdout


def load_xvg(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Read a 2-column GROMACS xvg, ignoring header/comment lines."""
    rows = []
    with path.open() as f:
        for line in f:
            if line.startswith(("#", "@")):
                continue
            parts = line.split()
            if len(parts) >= 2:
                rows.append((float(parts[0]), float(parts[1])))
    arr = np.array(rows)
    return arr[:, 0], arr[:, 1]


def analyze_rmsd(run_dir: Path) -> dict:
    """Backbone RMSD vs the minimized reference structure."""
    out = run_dir / "analysis"
    out.mkdir(exist_ok=True)
    xvg = out / "rmsd.xvg"

    # group 4 = Backbone for both selections (reference and fit)
    gmx(
        run_dir,
        "rms",
        "-s", "prod/md.tpr",
        "-f", "prod/md.xtc",
        "-o", str(xvg.relative_to(run_dir)),
        "-tu", "ps",
        stdin="4\n4\n",
    )
    t, r = load_xvg(xvg)
    plot_path = out / "rmsd.png"
    plt.figure(figsize=(6, 4))
    plt.plot(t, r, lw=1.2)
    plt.xlabel("time (ps)")
    plt.ylabel("backbone RMSD (nm)")
    plt.title("Backbone RMSD")
    plt.tight_layout()
    plt.savefig(plot_path, dpi=120)
    plt.close()

    return {
        "metric": "rmsd",
        "plot_path": str(plot_path),
        "summary": {
            "mean_nm": float(r.mean()),
            "stdev_nm": float(r.std()),
            "max_nm": float(r.max()),
            "n_frames": int(len(r)),
        },
    }


def analyze_energy(run_dir: Path, term: str) -> dict:
    """Pull a single energy term from the .edr."""
    out = run_dir / "analysis"
    out.mkdir(exist_ok=True)
    xvg = out / f"{term}.xvg"

    # gmx energy is interactive; pipe in the term name then a blank line.
    label = {"potential": "Potential", "temperature": "Temperature"}[term]
    gmx(
        run_dir,
        "energy",
        "-f", "prod/md.edr",
        "-o", str(xvg.relative_to(run_dir)),
        stdin=f"{label}\n\n",
    )
    t, e = load_xvg(xvg)
    plot_path = out / f"{term}.png"
    plt.figure(figsize=(6, 4))
    plt.plot(t, e, lw=1.0)
    plt.xlabel("time (ps)")
    plt.ylabel({"potential": "Potential energy (kJ/mol)", "temperature": "Temperature (K)"}[term])
    plt.title(label)
    plt.tight_layout()
    plt.savefig(plot_path, dpi=120)
    plt.close()

    return {
        "metric": term,
        "plot_path": str(plot_path),
        "summary": {
            "mean": float(e.mean()),
            "stdev": float(e.std()),
            "n_frames": int(len(e)),
        },
    }


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: analyze.py <run_dir> <metric>", file=sys.stderr)
        return 2
    run_dir = Path(sys.argv[1]).resolve()
    metric = sys.argv[2]
    if not run_dir.is_dir():
        print(f"run_dir not found: {run_dir}", file=sys.stderr)
        return 1

    if metric == "rmsd":
        result = analyze_rmsd(run_dir)
    elif metric in ("potential", "temperature"):
        result = analyze_energy(run_dir, metric)
    else:
        print(f"unknown metric: {metric}", file=sys.stderr)
        return 2

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
