#!/usr/bin/env bash
# Delete the demo resource group. Asks for confirmation.
set -euo pipefail

: "${RG:=agentcon-hpc-demo}"

if ! az group show -n "$RG" >/dev/null 2>&1; then
  echo "Resource group $RG does not exist. Nothing to do."
  exit 0
fi

read -r -p "Delete resource group '$RG' and everything in it? [type the RG name to confirm] " CONFIRM
if [[ "$CONFIRM" != "$RG" ]]; then
  echo "Aborted."
  exit 1
fi

az group delete -n "$RG" --yes --no-wait
echo "Delete in progress (async). Check with: az group show -n $RG"
