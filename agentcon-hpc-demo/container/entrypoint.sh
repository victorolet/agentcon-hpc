#!/usr/bin/env bash
# Thin entrypoint: source the GROMACS GMXRC, then exec the command.
#
# We intentionally do NOT use `set -u` (nounset). GROMACS' GMXRC and
# GMXRC.bash reference $shell and $GMXLDLIB without first checking, and
# fail under nounset with "unbound variable" errors before the GROMACS
# environment is established. -e and pipefail are still on.
set -eo pipefail
# shellcheck disable=SC1091
source /opt/gromacs/bin/GMXRC
exec "$@"
