#!/usr/bin/env bash
# Prepare a solvated, neutralized GROMACS system from a PDB ID.
#
# Usage:
#   prepare_system.sh <run_dir> <pdb_id> <force_field> <water_model> <box_nm>
#
# Example:
#   prepare_system.sh /data/run-7c41 1AKI oplsaa spc 1.0
#
# Produces, under <run_dir>:
#   protein.pdb           cleaned (no crystal waters)
#   topology/             pdb2gmx output
#   solvated.gro          solvated box
#   ions.tpr              ready for genion
#   neutral.gro           neutralized
#   em.tpr                ready for minimize stage
#
# Stdout: a single JSON line summarizing the prep result. The agent's
# tools.py reads this to populate the tool result.
set -euo pipefail

RUN_DIR=${1:?run_dir required}
PDB_ID=${2:?pdb_id required}
FF=${3:-oplsaa}
WATER=${4:-spc}
BOX=${5:-1.0}

WORKFLOW_DIR=$(cd "$(dirname "$0")" && pwd)
MDP_DIR="$WORKFLOW_DIR/mdp"
IMAGE=${GMX_IMAGE:-gromacs-demo:latest}

# shellcheck source=workflow/_runtime.sh
source "$WORKFLOW_DIR/_runtime.sh"

mkdir -p "$RUN_DIR/topology"
cd "$RUN_DIR"

# 1. Fetch PDB. RCSB rejects non-https; use direct https endpoint.
if [[ ! -f raw.pdb ]]; then
  curl -fsSL "https://files.rcsb.org/download/${PDB_ID}.pdb" -o raw.pdb
fi

# 2. Strip crystal waters (the ones marked HOH); keep ligands? — for the
# lysozyme demo there are none we care about.
grep -v '^HETATM.*HOH' raw.pdb > protein.pdb

# Helper to run gmx in the container with /data mounted at /data.
# DOCKER_GPU_ARGS is set by _runtime.sh based on GPU_VENDOR. None of the
# preparation steps actually use the GPU, but we pass the args anyway so a
# single image works for both prep and mdrun stages.
gmx() {
  docker run --rm \
    "${DOCKER_GPU_ARGS[@]}" \
    -v /data:/data \
    -w "$RUN_DIR" \
    "$IMAGE" \
    gmx "$@"
}

# 3. pdb2gmx → topology + processed.gro
gmx pdb2gmx -f protein.pdb -o topology/processed.gro -p topology/topol.top \
  -i topology/posre.itp -ff "$FF" -water "$WATER" <<<"" >/tmp/pdb2gmx.log 2>&1 || {
    echo "pdb2gmx failed:" >&2; tail -50 /tmp/pdb2gmx.log >&2; exit 1; }

# 4. Box: cubic, $BOX nm distance from solute.
gmx editconf -f topology/processed.gro -o boxed.gro -c -d "$BOX" -bt cubic >/dev/null

# 5. Solvate.
gmx solvate -cp boxed.gro -cs spc216.gro -o solvated.gro -p topology/topol.top >/dev/null

# 6. Add ions to neutralize.
cp "$MDP_DIR/ions.mdp" ions.mdp
gmx grompp -f ions.mdp -c solvated.gro -p topology/topol.top -o ions.tpr -maxwarn 1 >/dev/null
# Group 13 = SOL by convention in this topology; pipe it in.
echo "SOL" | gmx genion -s ions.tpr -o neutral.gro -p topology/topol.top \
  -pname NA -nname CL -neutral >/dev/null

# 7. Stage the minimization tpr so the next tool call is just an mdrun.
cp "$MDP_DIR/minim.mdp" em.mdp
gmx grompp -f em.mdp -c neutral.gro -p topology/topol.top -o em.tpr >/dev/null

# 8. Summarize for the agent.
N_ATOMS=$(awk 'NR==2 {print $1}' neutral.gro)
BOX_LINE=$(tail -1 neutral.gro)

python3 - <<PYEOF
import json
n = $N_ATOMS
box = "$BOX_LINE".split()
print(json.dumps({
    "run_id": "$(basename "$RUN_DIR")",
    "pdb_id": "$PDB_ID",
    "force_field": "$FF",
    "water_model": "$WATER",
    "n_atoms": n,
    "box_nm": [float(box[0]), float(box[1]), float(box[2])],
    "files": ["topology/topol.top", "neutral.gro", "em.tpr"]
}))
PYEOF
