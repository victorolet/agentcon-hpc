# shellcheck shell=bash
# Sourced helper. Sets DOCKER_GPU_ARGS and MDRUN_GPU_ARGS based on GPU_VENDOR.
#
# Use:
#   source "$(dirname "$0")/_runtime.sh"
#   docker run --rm "${DOCKER_GPU_ARGS[@]}" ... image gmx mdrun "${MDRUN_GPU_ARGS[@]}" ...
#
# GPU_VENDOR values:
#   nvidia (default) -> --gpus all  + GPU-offload mdrun flags
#   amd              -> --device=/dev/kfd --device=/dev/dri --group-add video --security-opt seccomp=unconfined
#                       + GPU-offload mdrun flags
#   cpu              -> no docker GPU args, no mdrun GPU flags

GPU_VENDOR=${GPU_VENDOR:-nvidia}

case "$GPU_VENDOR" in
  nvidia)
    DOCKER_GPU_ARGS=(--gpus all)
    MDRUN_GPU_ARGS=(-nb gpu -bonded gpu -update gpu)
    ;;
  amd)
    DOCKER_GPU_ARGS=(
      --device=/dev/kfd
      --device=/dev/dri
      --group-add video
      --security-opt seccomp=unconfined
    )
    MDRUN_GPU_ARGS=(-nb gpu -bonded gpu -update gpu)
    ;;
  cpu)
    DOCKER_GPU_ARGS=()
    MDRUN_GPU_ARGS=()
    ;;
  *)
    echo "unknown GPU_VENDOR: $GPU_VENDOR (expected nvidia|amd|cpu)" >&2
    exit 1
    ;;
esac
