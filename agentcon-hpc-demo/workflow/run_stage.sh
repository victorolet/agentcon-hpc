#!/usr/bin/env bash
# Run one MD stage (minimize | equilibrate | production) inside the GROMACS
# container, on the GPU. Outputs JSON to stdout for the agent to parse.
#
# Usage:
#   run_stage.sh <run_dir> <stage> [nsteps]
#
# Stages:
#   minimize     -> em.tpr   -> em.{gro,edr,log}
#   equilibrate  -> nvt.tpr  -> nvt.{gro,edr,log,xtc}   (NVT, position-restrained)
#   production   -> md.tpr   -> md.{gro,edr,log,xtc}
#
# nsteps overrides the default in the corresponding .mdp via grompp's
# -t/-r mechanism is overkill; instead we substitute into a per-run .mdp.
set -euo pipefail

RUN_DIR=${1:?run_dir required}
STAGE=${2:?stage required}
NSTEPS=${3:-}

WORKFLOW_DIR=$(cd "$(dirname "$0")" && pwd)
MDP_DIR="$WORKFLOW_DIR/mdp"
IMAGE=${GMX_IMAGE:-gromacs-demo:latest}

# shellcheck source=workflow/_runtime.sh
source "$WORKFLOW_DIR/_runtime.sh"

cd "$RUN_DIR"

gmx() {
  docker run --rm "${DOCKER_GPU_ARGS[@]}" -v /data:/data -w "$RUN_DIR" "$IMAGE" gmx "$@"
}

# Helper: optionally rewrite nsteps in an mdp.
write_mdp() {
  local src=$1 dst=$2
  if [[ -n "$NSTEPS" ]]; then
    sed "s/^nsteps.*/nsteps = $NSTEPS/" "$src" > "$dst"
  else
    cp "$src" "$dst"
  fi
}

start_ts=$(date +%s.%N)

case "$STAGE" in
  minimize)
    mkdir -p em
    write_mdp "$MDP_DIR/minim.mdp" em/em.mdp
    gmx grompp -f em/em.mdp -c neutral.gro -p topology/topol.top -o em/em.tpr -maxwarn 1 >/dev/null
    # Minimization is short; even on GPU mdrun runs it largely on CPU.
    # Use only the -nb part of the GPU args if present (drop -bonded/-update
    # which require a real MD integrator). We hand-roll for clarity.
    if [[ ${#MDRUN_GPU_ARGS[@]} -gt 0 ]]; then
      gmx mdrun -deffnm em/em -nb gpu -ntomp "$(nproc)" >/dev/null 2>&1
    else
      gmx mdrun -deffnm em/em -ntomp "$(nproc)" >/dev/null 2>&1
    fi
    OUT_EDR=em/em.edr
    OUT_GRO=em/em.gro
    LOG=em/em.log
    ;;

  equilibrate)
    mkdir -p nvt
    write_mdp "$MDP_DIR/nvt.mdp" nvt/nvt.mdp
    gmx grompp -f nvt/nvt.mdp -c em/em.gro -r em/em.gro \
      -p topology/topol.top -o nvt/nvt.tpr -maxwarn 2 >/dev/null
    gmx mdrun -deffnm nvt/nvt "${MDRUN_GPU_ARGS[@]}" \
      -ntomp "$(nproc)" >/dev/null 2>&1
    OUT_EDR=nvt/nvt.edr
    OUT_GRO=nvt/nvt.gro
    LOG=nvt/nvt.log
    ;;

  production)
    mkdir -p prod
    write_mdp "$MDP_DIR/md.mdp" prod/md.mdp
    gmx grompp -f prod/md.mdp -c nvt/nvt.gro -t nvt/nvt.cpt \
      -p topology/topol.top -o prod/md.tpr -maxwarn 2 >/dev/null
    gmx mdrun -deffnm prod/md "${MDRUN_GPU_ARGS[@]}" \
      -ntomp "$(nproc)" >/dev/null 2>&1
    OUT_EDR=prod/md.edr
    OUT_GRO=prod/md.gro
    LOG=prod/md.log
    ;;

  *)
    echo "Unknown stage: $STAGE" >&2; exit 2 ;;
esac

end_ts=$(date +%s.%N)
walltime=$(awk -v s="$start_ts" -v e="$end_ts" 'BEGIN{printf "%.2f", e-s}')

# Pull a couple of useful numbers out of the log.
NSDAY=$(grep -oE "Performance: *[0-9.]+ *ns/day" "$LOG" | awk '{print $2}' | tail -1 || echo "")
# Last "Potential" energy from the log table (not always present at minimize).
FINAL_POT=$(grep -E "Potential" "$LOG" | tail -1 | awk '{print $NF}' || echo "")

python3 - <<PYEOF
import json
print(json.dumps({
    "stage": "$STAGE",
    "walltime_s": float("$walltime"),
    "ns_per_day": float("$NSDAY") if "$NSDAY" else None,
    "final_potential_kJ_mol": float("$FINAL_POT") if "$FINAL_POT" else None,
    "log": "$LOG",
    "trajectory": "$OUT_GRO" if "$STAGE" == "minimize" else "${OUT_GRO%.gro}.xtc"
}))
PYEOF
