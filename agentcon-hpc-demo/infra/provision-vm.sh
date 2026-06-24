#!/usr/bin/env bash
# Provision a single Azure GPU VM for the AgentCon HPC demo.
#
# Creates: resource group, VNet+subnet, NSG (SSH from $MY_IP only), public IP,
# NIC, system-assigned managed identity, and an Ubuntu 22.04 GPU VM.
#
# Idempotent: re-running with the same RG name will not duplicate resources;
# az will report "already exists" and continue.
#
# Required: azure-cli >= 2.55, logged in (`az login`), an active subscription
# with quota for the chosen VM size in the chosen region.
set -euo pipefail

# --- configuration --------------------------------------------------------
: "${RG:=agentcon-hpc-demo}"
: "${LOCATION:=eastus}"
: "${VM_NAME:=hpc-agent-vm}"
: "${VM_SIZE:=Standard_NC4as_T4_v3}"   # 8 vCPU, 28 GB, 1/8 of an AMD MI25 (Vega 10 / gfx900). See docs/gpu-vendors.md.
: "${ADMIN_USER:=azureuser}"
: "${SSH_KEY_PATH:=$HOME/.ssh/agentcon.pub}"
# Lock SSH down to your current public IP. Override MY_IP if you know better.
: "${MY_IP:=$(curl -fsSL https://api.ipify.org || echo "0.0.0.0/0")}"

if [[ "$MY_IP" == "0.0.0.0/0" ]]; then
  echo "WARN: could not detect your public IP. SSH will be open to the world." >&2
  echo "      Set MY_IP=x.x.x.x explicitly to lock it down." >&2
fi

# --- preflight ------------------------------------------------------------
command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
[[ -f "$SSH_KEY_PATH" ]] || { echo "SSH key not found at $SSH_KEY_PATH"; exit 1; }
az account show >/dev/null || { echo "run: az login"; exit 1; }

echo "==> Subscription: $(az account show --query name -o tsv)"
echo "==> Region:       $LOCATION"
echo "==> VM size:      $VM_SIZE"
echo "==> SSH allowed from: $MY_IP"

# --- resource group -------------------------------------------------------
az group create -n "$RG" -l "$LOCATION" -o none

# --- network --------------------------------------------------------------
az network vnet create \
  -g "$RG" -n "${VM_NAME}-vnet" \
  --address-prefix 10.42.0.0/16 \
  --subnet-name default --subnet-prefix 10.42.0.0/24 \
  -o none

az network nsg create -g "$RG" -n "${VM_NAME}-nsg" -o none
az network nsg rule create \
  -g "$RG" --nsg-name "${VM_NAME}-nsg" -n allow-ssh-from-me \
  --priority 100 --access Allow --direction Inbound --protocol Tcp \
  --source-address-prefixes "$MY_IP" --source-port-ranges '*' \
  --destination-port-ranges 22 \
  -o none

# --- VM -------------------------------------------------------------------
# Ubuntu 22.04 LTS Gen2; assign system identity for keyless Foundry auth.
az vm create \
  -g "$RG" -n "$VM_NAME" \
  --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_KEY_PATH" \
  --vnet-name "${VM_NAME}-vnet" --subnet default \
  --nsg "${VM_NAME}-nsg" \
  --public-ip-sku Standard \
  --assign-identity \
  --os-disk-size-gb 128 \
  -o none

PUBLIC_IP=$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)
PRINCIPAL=$(az vm identity show -g "$RG" -n "$VM_NAME" --query principalId -o tsv)

cat <<EOF

==> Done.

  Public IP:        $PUBLIC_IP
  Managed identity: $PRINCIPAL

Next steps:
  1. SSH in:
       ssh ${ADMIN_USER}@${PUBLIC_IP}
  2. Clone this repo onto the VM, then run infra/setup-vm.sh.
  3. Grant the managed identity access to your Foundry project (Cognitive
     Services User role on the Foundry resource), so the agent can auth via
     DefaultAzureCredential without secrets.

To tear everything down later:
       ./infra/teardown.sh

EOF
