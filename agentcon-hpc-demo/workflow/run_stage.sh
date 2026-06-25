#!/usr/bin/env bash
# Run one MD stage (minimize | equilibrate | production) inside the GROMACS
# container, on the GPU. Outputs JSON to stdout for the agent to parse.
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
  docker run --rm -i "${DOCKER_GPU_ARGS[@]}" -v /data:/data -w "$RUN_DIR" "$IMAGE" gmx "$@"
}

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
    gmx grompp -f em/em.mdp -c neutral.gro -p topology/topol.top -o em/em.tpr -maxwarn 1 \
      >em/grompp.out 2>&1 || { echo "grompp failed:" >&2; tail -50 em/grompp.out >&2; exit 1; }
    if [[ ${#MDRUN_GPU_ARGS[@]} -gt 0 ]]; then
      MDRUN_CMD=(mdrun -deffnm em/em -nb gpu -ntmpi 1 -ntomp "$(nproc)")
    else
      MDRUN_CMD=(mdrun -deffnm em/em -ntmpi 1 -ntomp "$(nproc)")
    fi
    gmx "${MDRUN_CMD[@]}" >em/mdrun.out 2>&1 || {
      echo "mdrun (minimize) failed:" >&2
      tail -50 em/mdrun.out >&2
      [[ -f em/em.log ]] && { echo "--- em.log tail ---" >&2; tail -80 em/em.log >&2; }
      exit 1
    }
    OUT_GRO=em/em.gro
    LOG=em/em.log
    ;;

  equilibrate)
    mkdir -p nvt
    write_mdp "$MDP_DIR/nvt.mdp" nvt/nvt.mdp
    gmx grompp -f nvt/nvt.mdp -c em/em.gro -r em/em.gro -p topology/topol.top -o nvt/nvt.tpr -maxwarn 2 \
      >nvt/grompp.out 2>&1 || { echo "grompp (nvt) failed:" >&2; tail -50 nvt/grompp.out >&2; exit 1; }
    gmx mdrun -deffnm nvt/nvt "${MDRUN_GPU_ARGS[@]}" -ntmpi 1 -ntomp "$(nproc)" \
      >nvt/mdrun.out 2>&1 || {
        echo "mdrun (equilibrate) failed:" >&2
        tail -50 nvt/mdrun.out >&2
        [[ -f nvt/nvt.log ]] && { echo "--- nvt.log tail ---" >&2; tail -80 nvt/nvt.log >&2; }
        exit 1
      }
    OUT_GRO=nvt/nvt.gro
    LOG=nvt/nvt.log
    ;;

  production)
    mkdir -p prod
    write_mdp "$MDP_DIR/md.mdp" prod/md.mdp
    gmx grompp -f prod/md.mdp -c nvt/nvt.gro -t nvt/nvt.cpt -p topology/topol.top -o prod/md.tpr -maxwarn 2 \
      >prod/grompp.out 2>&1 || { echo "grompp (prod) failed:" >&2; tail -50 prod/grompp.out >&2; exit 1; }
    gmx mdrun -deffnm prod/md "${MDRUN_GPU_ARGS[@]}" -ntmpi 1 -ntomp "$(nproc)" \
      >prod/mdrun.out 2>&1 || {
        echo "mdrun (production) failed:" >&2
        tail -50 prod/mdrun.out >&2
        [[ -f prod/md.log ]] && { echo "--- md.log tail ---" >&2; tail -80 prod/md.log >&2; }
        exit 1
      }
    OUT_GRO=prod/md.gro
    LOG=prod/md.log
    ;;

  *)
    echo "Unknown stage: $STAGE" >&2; exit 2 ;;
esac

end_ts=$(date +%s.%N)
walltime=$(awk -v s="$start_ts" -v e="$end_ts" 'BEGIN{printf "%.2f", e-s}')

NSDAY=$(grep -E "^Performance:" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}' || echo "")
FINAL_POT=$(grep -E "Potential" "$LOG" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "")

python3 - <<PYEOF
import json
def fl(s):
    try: return float(s)
    except (TypeError, ValueError): return None
print(json.dumps({
    "stage": "$STAGE",
    "walltime_s": fl("$walltime"),
    "ns_per_day": fl("$NSDAY"),
    "final_potential_kJ_mol": fl("$FINAL_POT"),
    "log": "$LOG",
    "trajectory": "$OUT_GRO" if "$STAGE" == "minimize" else "${OUT_GRO%.gro}.xtc"
}))
PYEOF
