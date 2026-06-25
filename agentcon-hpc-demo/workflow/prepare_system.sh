#!/usr/bin/env bash
# Prepare a solvated, neutralized GROMACS system from a PDB ID.
#
# Usage:
#   prepare_system.sh <run_dir> <pdb_id> <force_field> <water_model> <box_nm>
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

# 1. Fetch PDB.
if [[ ! -f raw.pdb ]]; then
  curl -fsSL "https://files.rcsb.org/download/${PDB_ID}.pdb" -o raw.pdb
fi

# 2. Strip crystal waters.
grep -v '^HETATM.*HOH' raw.pdb > protein.pdb

# Docker wrapper. -i is required when stdin is piped (e.g. genion).
gmx() {
  docker run --rm -i \
    "${DOCKER_GPU_ARGS[@]}" \
    -v /data:/data \
    -w "$RUN_DIR" \
    "$IMAGE" \
    gmx "$@"
}

# Per-step logging-on-failure helper.
run_step() {
  local name=$1; shift
  local log=/tmp/prep-$name.log
  if ! "$@" >"$log" 2>&1; then
    echo "$name failed:" >&2
    tail -50 "$log" >&2
    exit 1
  fi
}

# 3. pdb2gmx
gmx pdb2gmx -f protein.pdb -o topology/processed.gro -p topology/topol.top \
  -i topology/posre.itp -ff "$FF" -water "$WATER" <<<"" >/tmp/pdb2gmx.log 2>&1 || {
    echo "pdb2gmx failed:" >&2; tail -50 /tmp/pdb2gmx.log >&2; exit 1; }

# pdb2gmx records #include "topology/posre.itp" (the -i arg), but grompp
# resolves include paths relative to topol.top's own directory, so it
# actually looks for topology/topology/posre.itp. Strip the prefix.
sed -i 's|"topology/posre.itp"|"posre.itp"|g' topology/topol.top

# 4. Box.
run_step editconf gmx editconf -f topology/processed.gro -o boxed.gro -c -d "$BOX" -bt cubic

# 5. Solvate.
run_step solvate gmx solvate -cp boxed.gro -cs spc216.gro -o solvated.gro -p topology/topol.top

# 6. Add ions to neutralize.
cp "$MDP_DIR/ions.mdp" ions.mdp
run_step grompp-ions gmx grompp -f ions.mdp -c solvated.gro -p topology/topol.top -o ions.tpr -maxwarn 1
if ! echo "SOL" | gmx genion -s ions.tpr -o neutral.gro -p topology/topol.top \
    -pname NA -nname CL -neutral >/tmp/prep-genion.log 2>&1; then
  echo "genion failed:" >&2; tail -50 /tmp/prep-genion.log >&2; exit 1
fi

# 7. Stage em.tpr.
cp "$MDP_DIR/minim.mdp" em.mdp
run_step grompp-em gmx grompp -f em.mdp -c neutral.gro -p topology/topol.top -o em.tpr

# 8. Summary JSON for the agent.
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
