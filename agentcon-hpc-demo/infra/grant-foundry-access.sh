#!/usr/bin/env bash
# Grant a principal a role on a Foundry resource so the agent can create
# agents, threads, runs, and messages.
#
# Usage:
#   ./infra/grant-foundry-access.sh <principal-id> <foundry-resource-name> [role-name]
#
#   role-name defaults to: try "Azure AI User", then "Azure AI Developer",
#                          then "Cognitive Services Contributor"
#
#   These names vary by tenant. To see what's available in yours:
#     az role definition list \
#       --query "[?contains(roleName, 'AI ') || contains(roleName, 'Cognitive')].roleName" -o tsv
#
# Idempotent: re-running is a no-op once the assignment exists.
set -euo pipefail

PRINCIPAL_ID=${1:?usage: grant-foundry-access.sh <principal-id> <resource-name> [role]}
RESOURCE_NAME=${2:-${FOUNDRY_RESOURCE_NAME:-}}
EXPLICIT_ROLE=${3:-}

if [[ -z "$RESOURCE_NAME" ]]; then
  echo "Pass the Foundry resource name as arg 2, or set FOUNDRY_RESOURCE_NAME." >&2
  exit 2
fi

RESOURCE_ID=$(az cognitiveservices account list \
  --query "[?name=='${RESOURCE_NAME}'].id | [0]" -o tsv)
if [[ -z "$RESOURCE_ID" ]]; then
  echo "Could not find Foundry/CognitiveServices account '${RESOURCE_NAME}' in this subscription." >&2
  exit 1
fi

if az ad user show --id "$PRINCIPAL_ID" >/dev/null 2>&1; then
  PRINCIPAL_TYPE=User
else
  PRINCIPAL_TYPE=ServicePrincipal
fi

# Try the named role first; if it doesn't exist in this tenant, fall back
# through known equivalents. All three include
# Microsoft.CognitiveServices/accounts/AIServices/agents/write.
if [[ -n "$EXPLICIT_ROLE" ]]; then
  CANDIDATES=("$EXPLICIT_ROLE")
else
  CANDIDATES=(
    "Azure AI Foundry User"
    "Foundry User"
    "Azure AI User"
    "Azure AI Developer"
    "Cognitive Services Contributor"
  )
fi

try_grant() {
  local role=$1
  echo "==> Trying role: '$role'"
  if az role assignment create \
      --assignee-object-id "$PRINCIPAL_ID" \
      --assignee-principal-type "$PRINCIPAL_TYPE" \
      --role "$role" \
      --scope "$RESOURCE_ID" \
      -o table 2>/tmp/az-grant.err; then
    echo "==> Granted '$role'."
    return 0
  fi
  if grep -q "already exists" /tmp/az-grant.err; then
    echo "==> Assignment for '$role' already existed; nothing to do."
    return 0
  fi
  if grep -qE "doesn't exist|does not exist|RoleDefinition.+not found" /tmp/az-grant.err; then
    echo "    role '$role' not defined in this tenant — trying next"
    return 2
  fi
  echo "==> Unexpected failure granting '$role':" >&2
  cat /tmp/az-grant.err >&2
  return 1
}

SUCCESS=0
for role in "${CANDIDATES[@]}"; do
  if try_grant "$role"; then
    SUCCESS=1
    break
  fi
done

if [[ $SUCCESS -eq 0 ]]; then
  echo
  echo "None of the candidate roles were granted. Available role names in your tenant:" >&2
  az role definition list \
    --query "[?contains(roleName, 'AI ') || contains(roleName, 'Cognitive')].roleName" -o tsv >&2
  echo
  echo "Pass one of those as the third arg, e.g.:" >&2
  echo "  $0 $PRINCIPAL_ID $RESOURCE_NAME 'Cognitive Services User'" >&2
  exit 1
fi

echo
echo "==> Current assignments for this principal at this scope:"
az role assignment list \
  --assignee "$PRINCIPAL_ID" \
  --scope "$RESOURCE_ID" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table

echo
echo "Propagation can take 1-5 minutes. Re-run agent.py after that."
