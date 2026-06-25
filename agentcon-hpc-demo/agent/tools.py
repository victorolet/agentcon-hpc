"""Tool implementations exposed to the Azure AI Foundry agent.

Each function:
  - takes JSON-serializable arguments,
  - returns a JSON-serializable dict,
  - shells out to scripts under workflow/ for anything that touches GROMACS.

Foundry's FunctionTool turns these Python callables (with their type hints
and docstrings) into the JSON tool schemas the model sees. Keep the
docstrings tight and the argument types explicit.
"""
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

# Docker GPU args by vendor. Mirrors workflow/_runtime.sh so the agent's
# in-process GPU probe uses the same wiring the workflow scripts use.
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


def _run(cmd: list[str], cwd: str | None = None, timeout: int = 600) -> str:
    """Run a shell command, return stdout. Raise with stderr on failure."""
    try:
        res = subprocess.run(
            cmd, cwd=cwd, text=True, capture_output=True,
            timeout=timeout, check=True,
        )
        return res.stdout
    except subprocess.CalledProcessError as e:
        tail = (e.stderr or "")[-2000:]
        raise RuntimeError(f"{' '.join(cmd)} failed: {tail}") from e
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"{' '.join(cmd)} timed out after {timeout}s") from e


# --------------------------------------------------------------------------
# Tools
# --------------------------------------------------------------------------

def _probe_gpu_nvidia() -> tuple[bool, str]:
    """Run nvidia-smi inside a tiny CUDA container."""
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
    """Run rocminfo inside a ROCm container and pick out the gfx code/name."""
    out = subprocess.run(
        ["docker", "run", "--rm",
         "--device=/dev/kfd", "--device=/dev/dri",
         "--group-add", "video",
         "--security-opt", "seccomp=unconfined",
         "rocm/rocm-terminal:5.7",
         "/opt/rocm/bin/rocminfo"],
        text=True, capture_output=True, timeout=60,
    )
    if out.returncode != 0:
        return False, ""
    # rocminfo prints lines like "  Name:                    gfx900"
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
    """Verify Docker, the GPU runtime, and the GROMACS image are available.

    Probes the right GPU runtime for the configured GPU_VENDOR (nvidia, amd,
    or cpu). If GPU_VENDOR=cpu, gpu_ok is reported as true with gpu_name="CPU".

    Returns a JSON object with fields docker_ok, gpu_ok, gpu_name,
    image_present, image_tag, gpu_vendor.
    """
    docker_ok = shutil.which("docker") is not None
    image_present = False
    image_tag = ""
    gpu_ok = False
    gpu_name = ""

    if docker_ok:
        out = subprocess.run(
            ["docker", "images", "--format", "{{.Repository}}:{{.Tag}}", GMX_IMAGE],
            text=True, capture_output=True,
        )
        if out.returncode == 0 and GMX_IMAGE in out.stdout:
            image_present = True
            image_tag = GMX_IMAGE

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
        force_field: GROMACS force field name. One of: oplsaa, amber99sb-ildn, charmm27.
        water_model: Water model. One of: spc, spce, tip3p, tip4p.
        box_nm: Distance from solute to box edge, in nm. Range 0.5–2.0.

    Returns a JSON object with run_id (used by later tools), pdb_id,
    n_atoms, n_water, box_nm, and the list of files produced.
    """
    if not PDB_ID_RE.match(pdb_id):
        raise ValueError(f"Invalid PDB ID: {pdb_id!r}")
    if force_field not in ALLOWED_FF:
        raise ValueError(f"force_field must be one of {sorted(ALLOWED_FF)}")
    if water_model not in ALLOWED_WATER:
        raise ValueError(f"water_model must be one of {sorted(ALLOWED_WATER)}")
    # LLMs sometimes serialize numeric tool args as strings; coerce defensively.
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
    return out.strip().splitlines()[-1]  # last line is the JSON summary


def run_stage(
    run_id: str,
    stage: Literal["minimize", "equilibrate", "production"],
    nsteps: int | None = None,
) -> str:
    """Run one MD stage on the GPU.

    Args:
        run_id: ID returned by prepare_system, e.g. "run-7c41".
        stage: One of "minimize", "equilibrate", "production".
        nsteps: Optional override for the stage's step count. Bounded by
            the schema; demo-safe defaults are in the MDP files.

    Returns a JSON object with stage, walltime_s, ns_per_day,
    final_potential_kJ_mol, log path, and trajectory path.
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
        metric: One of "rmsd", "potential", "temperature".

    Returns a JSON object with metric, plot_path, and summary stats.
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


def get_run_status(run_id: str) -> str:
    """Report progress of an in-flight stage by tailing its log file.

    Args:
        run_id: ID returned by prepare_system.

    Returns a JSON object with stage, last_log_line, and walltime_so_far_s.
    """
    run_dir = DATA_DIR / run_id
    if not run_dir.is_dir():
        raise FileNotFoundError(f"run not found: {run_id}")
    # Pick the most recently-modified log under em/, nvt/, prod/.
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
    """Bundle the final results of a completed run.

    Args:
        run_id: ID returned by prepare_system.

    Returns a JSON object with plot paths, file paths, and a
    human-readable summary stitched from the analysis artifacts.
    """
    run_dir = DATA_DIR / run_id
    analysis = run_dir / "analysis"
    if not analysis.is_dir():
        raise FileNotFoundError("no analysis output yet — call analyze() first")

    plots = sorted(str(p) for p in analysis.glob("*.png"))
    files = {
        "topology": str(run_dir / "topology" / "topol.top"),
        "trajectory": str(run_dir / "prod" / "md.xtc"),
        "production_gro": str(run_dir / "prod" / "md.gro"),
    }
    return json.dumps({
        "run_id": run_id,
        "plots": plots,
        "files": {k: v for k, v in files.items() if Path(v).exists()},
        "data_dir": str(run_dir),
    })


# Foundry's FunctionTool takes a set of callables.
ALL_TOOLS = {
    check_environment,
    prepare_system,
    run_stage,
    analyze,
    get_run_status,
    report,
}
