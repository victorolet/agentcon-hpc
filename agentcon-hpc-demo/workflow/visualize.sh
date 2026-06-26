#!/usr/bin/env bash
# Produce a viewable trajectory: a centered, PBC-corrected PDB and a
# self-contained HTML viewer that renders it in any browser via NGL.js.
#
# Usage:
#   visualize.sh <run_dir>
#
# Outputs (under <run_dir>/analysis/):
#   trajectory.pdb   <- multi-MODEL PDB, opens in VMD/PyMOL/ChimeraX/VS Code
#   viewer.html      <- standalone HTML, loads trajectory.pdb via NGL.js CDN
#
# Emits a single JSON line on stdout for the agent.
set -euo pipefail

RUN_DIR=${1:?run_dir required}
WORKFLOW_DIR=$(cd "$(dirname "$0")" && pwd)
IMAGE=${GMX_IMAGE:-gromacs-demo:latest}

# shellcheck source=workflow/_runtime.sh
source "$WORKFLOW_DIR/_runtime.sh"

cd "$RUN_DIR"
mkdir -p analysis

# Docker wrapper, same pattern as the other scripts. -i for piped stdin.
gmx() {
  docker run --rm -i "${DOCKER_GPU_ARGS[@]}" -v /data:/data -w "$RUN_DIR" "$IMAGE" gmx "$@"
}

# Stage 1: remove periodic-boundary wrapping and center on protein. This
# keeps the protein whole and at the centre of the box across all frames.
# trjconv asks two questions: which group to center on, then which group
# to output. "Protein" / "Protein" gives a clean protein-only trajectory.
printf "Protein\nProtein\n" | gmx trjconv \
    -s prod/md.tpr -f prod/md.xtc \
    -o analysis/trajectory.pdb \
    -pbc mol -center -ur compact \
    >/tmp/trjconv.log 2>&1 || {
      echo "gmx trjconv failed:" >&2
      tail -50 /tmp/trjconv.log >&2
      exit 1
    }

# Stage 2: write a small standalone HTML viewer next to the PDB.
# Uses NGL.js from a CDN; no install on the host or the viewer's machine.
cat > analysis/viewer.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Lysozyme MD trajectory</title>
<style>
  html, body { margin: 0; padding: 0; height: 100%; background: #111; color: #ddd;
               font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  #stage    { width: 100vw; height: calc(100vh - 36px); }
  #controls { height: 36px; display: flex; align-items: center; padding: 0 12px;
              border-top: 1px solid #333; gap: 12px; background: #1a1a1a; }
  button { padding: 4px 10px; background: #2a2a2a; color: #ddd;
           border: 1px solid #444; border-radius: 3px; cursor: pointer; }
  button:hover { background: #333; }
  #frame { font-variant-numeric: tabular-nums; font-size: 13px; min-width: 80px; }
</style>
<script src="https://unpkg.com/ngl@2.0.0-dev.39/dist/ngl.js"></script>
</head>
<body>
<div id="stage"></div>
<div id="controls">
  <button id="play">play</button>
  <button id="pause">pause</button>
  <span id="frame">frame 0</span>
</div>
<script>
const stage = new NGL.Stage("stage", { backgroundColor: "#111" });
window.addEventListener("resize", () => stage.handleResize());
stage.loadFile("./trajectory.pdb", { asTrajectory: true }).then(comp => {
  comp.addRepresentation("cartoon", { color: "residueindex" });
  comp.addRepresentation("licorice", { sele: "hetero and not water" });
  comp.autoView();
  const traj = comp.trajList[0];
  const player = new NGL.TrajectoryPlayer(traj, { timeout: 100, mode: "loop" });
  document.getElementById("play").onclick  = () => player.play();
  document.getElementById("pause").onclick = () => player.pause();
  traj.signals.frameChanged.add(i => {
    document.getElementById("frame").textContent = "frame " + i;
  });
  player.play();
});
</script>
</body>
</html>
HTMLEOF

# Stage 3: emit summary JSON for the agent.
N_FRAMES=$(grep -c "^MODEL" analysis/trajectory.pdb || echo 0)
PDB_SIZE=$(stat -c%s analysis/trajectory.pdb 2>/dev/null || echo 0)

python3 - <<PYEOF
import json
print(json.dumps({
    "trajectory_pdb": "analysis/trajectory.pdb",
    "viewer_html": "analysis/viewer.html",
    "n_frames": int("$N_FRAMES"),
    "pdb_size_bytes": int("$PDB_SIZE"),
    "open_locally": [
        "VMD: vmd analysis/trajectory.pdb",
        "PyMOL: pymol analysis/trajectory.pdb",
        "browser: open analysis/viewer.html",
        "VS Code: install 'Molecular Visualization' extension, open analysis/trajectory.pdb"
    ]
}))
PYEOF
