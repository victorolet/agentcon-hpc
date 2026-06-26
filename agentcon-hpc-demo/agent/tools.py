"""Tool implementations exposed to the Azure AI Foundry agent."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from typing import Literal

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
WORKFLOW_DIR = Path(os.environ.get("WORKFLOW_DIR", "./workflow")).resolve()
GMX_IMAGE = os.environ.get("GMX_IMAGE", "gromacs-demo:latest")
GPU_VENDOR = os.environ.get("GPU_VENDOR", "nvidia").lower()

PDB_ID_RE = re.compile(r"^[0-9A-Za-z]{4}$")
ALLOWED_FF = {"oplsaa", "amber99sb-ildn", "charmm27"}
ALLOWED_WATER = {"spc", "spce", "tip3p", "tip4p"}


def _run(cmd: list[str], cwd: str | None = None, timeout: int = 600) -> str:
    try:
        res = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True,
                             timeout=timeout, check=True)
        return res.stdout
    except subprocess.CalledProcessError as e:
        tail = (e.stderr or "")[-2000:]
        raise RuntimeError(f"{' '.join(cmd)} failed: {tail}") from e
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"{' '.join(cmd)} timed out after {timeout}s") from e


def _probe_gpu_nvidia() -> tuple[bool, str]:
    out = subprocess.run(
        ["docker", "run", "--rm", "--gpus", "all",
         "nvidia/cuda:12.4.1-base-ubuntu22.04",
         "nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
        text=True, capture_output=True, timeout=30,
    )
    if out.returncode == 0 and out.stdout.strip():
        return True, out.stdout.strip().splitlines()[0]
    return False, ""


def _probe_gpu_amd() -> tuple[bool, str]:
    out = subprocess.run(
        ["docker", "run", "--rm",
         "--device=/dev/kfd", "--device=/dev/dri",
         "--group-add", "video", "--security-opt", "seccomp=unconfined",
         "rocm/rocm-terminal:5.7", "/opt/rocm/bin/rocminfo"],
        text=True, capture_output=True, timeout=60,
    )
    if out.returncode != 0:
        return False, ""
    gfx = ""
    marketing = ""
    for line in out.stdout.splitlines():
        s = line.strip()
        if s.startswith("Name:") and "gfx" in s:
            gfx = s.split()[-1]
        if s.startswith("Marketing Name:"):
            marketing = s.split(":", 1)[1].strip()
    if gfx:
        return True, f"{marketing or 'AMD GPU'} ({gfx})"
    return False, ""


def check_environment() -> str:
    """Verify Docker and the GPU runtime are available.

    image_present is always reported true (no pre-check); rely on
    prepare_system errors to surface a missing image cleanly.
    """
    docker_ok = shutil.which("docker") is not None
    image_present = True
    image_tag = GMX_IMAGE
    gpu_ok = False
    gpu_name = ""

    if docker_ok:
        try:
            if GPU_VENDOR == "nvidia":
                gpu_ok, gpu_name = _probe_gpu_nvidia()
            elif GPU_VENDOR == "amd":
                gpu_ok, gpu_name = _probe_gpu_amd()
            elif GPU_VENDOR == "cpu":
                gpu_ok, gpu_name = True, "CPU (no GPU offload configured)"
        except (subprocess.TimeoutExpired, FileNotFoundError):
            gpu_ok, gpu_name = False, ""

    return json.dumps({
        "docker_ok": docker_ok,
        "gpu_vendor": GPU_VENDOR,
        "gpu_ok": gpu_ok,
        "gpu_name": gpu_name,
        "image_present": image_present,
        "image_tag": image_tag,
    })


def prepare_system(
    pdb_id: str,
    force_field: str = "oplsaa",
    water_model: str = "spc",
    box_nm: float = 1.0,
) -> str:
    """Fetch a PDB structure, build topology, solvate, and neutralize.

    Args:
        pdb_id: 4-character RCSB PDB identifier, e.g. "1AKI".
        force_field: GROMACS force field. One of: oplsaa, amber99sb-ildn, charmm27.
        water_model: Water model. One of: spc, spce, tip3p, tip4p.
        box_nm: Distance from solute to box edge in nm, 0.5-2.0.
    """
    if not PDB_ID_RE.match(pdb_id):
        raise ValueError(f"Invalid PDB ID: {pdb_id!r}")
    if force_field not in ALLOWED_FF:
        raise ValueError(f"force_field must be one of {sorted(ALLOWED_FF)}")
    if water_model not in ALLOWED_WATER:
        raise ValueError(f"water_model must be one of {sorted(ALLOWED_WATER)}")
    try:
        box_nm = float(box_nm)
    except (TypeError, ValueError):
        raise ValueError(f"box_nm must be a number, got {box_nm!r}")
    if not (0.5 <= box_nm <= 2.0):
        raise ValueError("box_nm must be between 0.5 and 2.0")

    run_id = f"run-{uuid.uuid4().hex[:4]}"
    run_dir = DATA_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    out = _run(
        [str(WORKFLOW_DIR / "prepare_system.sh"),
         str(run_dir), pdb_id.upper(), force_field, water_model, str(box_nm)],
        timeout=600,
    )
    return out.strip().splitlines()[-1]


def run_stage(
    run_id: str,
    stage: Literal["minimize", "equilibrate", "production"],
    nsteps: int | None = None,
) -> str:
    """Run one MD stage on the GPU.

    Args:
        run_id: ID returned by prepare_system.
        stage: "minimize", "equilibrate", or "production".
        nsteps: Optional step count override.
    """
    if stage not in ("minimize", "equilibrate", "production"):
        raise ValueError(f"unknown stage: {stage}")
    run_dir = DATA_DIR / run_id
    if not run_dir.is_dir():
        raise FileNotFoundError(f"run not found: {run_id}")
    if nsteps is not None:
        try:
            nsteps = int(nsteps)
        except (TypeError, ValueError):
            raise ValueError(f"nsteps must be an integer, got {nsteps!r}")
        if not (1 <= nsteps <= 250000):
            raise ValueError("nsteps out of range (1..250000)")

    args = [str(WORKFLOW_DIR / "run_stage.sh"), str(run_dir), stage]
    if nsteps is not None:
        args.append(str(nsteps))
    out = _run(args, timeout=900)
    return out.strip().splitlines()[-1]


def analyze(
    run_id: str,
    metric: Literal["rmsd", "potential", "temperature"],
) -> str:
    """Compute one analysis metric and write a PNG.

    Args:
        run_id: ID returned by prepare_system.
        metric: "rmsd", "potential", or "temperature".
    """
    if metric not in ("rmsd", "potential", "temperature"):
        raise ValueError(f"unknown metric: {metric}")
    run_dir = DATA_DIR / run_id
    if not run_dir.is_dir():
        raise FileNotFoundError(f"run not found: {run_id}")

    out = _run(
        ["python3", str(WORKFLOW_DIR / "analyze.py"), str(run_dir), metric],
        timeout=300,
    )
    return out.strip().splitlines()[-1]


def visualize_trajectory(run_id: str) -> str:
    """Produce a viewable trajectory file and an HTML viewer.

    Runs gmx trjconv to center the protein and correct periodic boundary
    conditions, then writes:
      - analysis/trajectory.pdb (multi-MODEL PDB, opens in VMD, PyMOL,
        ChimeraX, or VS Code's Molecular Visualization extension)
      - analysis/viewer.html (standalone HTML viewer using NGL.js, opens
        in any browser, no install)

    Args:
        run_id: ID returned by prepare_system.
    """
    run_dir = DATA_DIR / run_id
    if not run_dir.is_dir():
        raise FileNotFoundError(f"run not found: {run_id}")

    out = _run(
        [str(WORKFLOW_DIR / "visualize.sh"), str(run_dir)],
        timeout=300,
    )
    return out.strip().splitlines()[-1]


def get_run_status(run_id: str) -> str:
    """Report progress of an in-flight stage by tailing its log file."""
    run_dir = DATA_DIR / run_id
    if not run_dir.is_dir():
        raise FileNotFoundError(f"run not found: {run_id}")
    candidates = list(run_dir.glob("*/[en]*.log")) + list(run_dir.glob("prod/md.log"))
    if not candidates:
        return json.dumps({"stage": None, "last_log_line": None, "walltime_so_far_s": 0})
    log = max(candidates, key=lambda p: p.stat().st_mtime)
    last = log.read_text().splitlines()[-1] if log.stat().st_size else ""
    return json.dumps({
        "stage": log.parent.name,
        "last_log_line": last,
        "walltime_so_far_s": int(time.time() - log.stat().st_mtime),
    })


def report(run_id: str) -> str:
    """Bundle the final results of a completed run."""
    run_dir = DATA_DIR / run_id
    analysis = run_dir / "analysis"
    if not analysis.is_dir():
        raise FileNotFoundError("no analysis output yet - call analyze() first")

    plots = sorted(str(p) for p in analysis.glob("*.png"))
    viewer = analysis / "viewer.html"
    pdb = analysis / "trajectory.pdb"
    files = {
        "topology": str(run_dir / "topology" / "topol.top"),
        "trajectory_xtc": str(run_dir / "prod" / "md.xtc"),
        "production_gro": str(run_dir / "prod" / "md.gro"),
        "trajectory_pdb": str(pdb) if pdb.exists() else None,
        "viewer_html": str(viewer) if viewer.exists() else None,
    }
    return json.dumps({
        "run_id": run_id,
        "plots": plots,
        "files": {k: v for k, v in files.items() if v},
        "data_dir": str(run_dir),
    })


ALL_TOOLS = {
    check_environment,
    prepare_system,
    run_stage,
    analyze,
    visualize_trajectory,
    get_run_status,
    report,
}
