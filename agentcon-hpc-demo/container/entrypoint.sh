#!/usr/bin/env bash
# Thin entrypoint: source the GROMACS GMXRC to set env vars, then exec.
set -euo pipefail
# shellcheck disable=SC1091
source /opt/gromacs/bin/GMXRC
exec "$@"
