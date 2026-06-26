# Build journal — capturing the build process without rebuilding

The infrastructure for the demo took real effort to stand up: provisioning the GPU VM, getting Docker + NVIDIA Container Toolkit working, compiling GROMACS with CUDA, wiring Foundry RBAC, deploying the model. None of that should be redone for the talk. But the *story* of having built it is part of the message — the orchestration layer hides a lot of one-time setup, and audiences appreciate seeing what's underneath.

This journal lists, for each piece you built, the **inspection commands** (no rebuild required) and **portal pages** to grab screenshots from. Together they reconstruct the build story as a post-hoc artifact.

## How to use this

For each section below:
1. Run the listed command(s) on your live infrastructure
2. Screenshot the terminal output (or save to file with `> capture.txt`)
3. For portal sections, screenshot the indicated page
4. Drop all captures into a `docs/build-screenshots/` directory
5. Use the resulting cluster in Slide 19 (Behind the scenes) of the talk

Suggested screenshot dimensions: 1600x900 or so, dark-mode terminal, large font (16pt+) so projection reads cleanly.

---

## 1. Azure resource group + GPU VM

**Why show this:** "I provisioned a single GPU VM in Azure with one command."

```bash
# Resource group + everything in it
az group show -n agentcon-hpc-demo -o table
az resource list -g agentcon-hpc-demo --query "[].{name:name, type:type, location:location}" -o table

# The VM itself, with hardware details
az vm show -d -g agentcon-hpc-demo -n hpc-agent-vm \
  --query "{name:name, size:hardwareProfile.vmSize, os:storageProfile.osDisk.osType, ip:publicIps, status:powerState}" \
  -o table

# The Network Security Group rule (SSH locked to your IP)
az network nsg rule show -g agentcon-hpc-demo \
  --nsg-name hpc-agent-vm-nsg -n allow-ssh-from-me \
  --query "{port:destinationPortRange, source:sourceAddressPrefix, access:access}" -o table
```

**Portal screenshot:** Azure Portal → Resource group `agentcon-hpc-demo` → Overview. Shows the VM, NIC, public IP, NSG, disk, managed identity as a list.

## 2. NVIDIA driver + Docker + NVIDIA Container Toolkit (on the VM)

**Why show this:** "Three layers of GPU runtime to get a `gmx --version` line out."

```bash
# Driver (run on the VM)
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv

# Docker
docker version --format 'Client: {{.Client.Version}}\nServer: {{.Server.Version}}'

# NVIDIA Container Toolkit — proves --gpus all works
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi | head -8
```

## 3. The GROMACS container build

**Why show this:** "GROMACS compiled with CUDA, in a reproducible image."

```bash
# The image layers, by size
docker history gromacs-demo:cuda --format "table {{.CreatedSince}}\t{{.Size}}\t{{.Comment}}" --no-trunc | head -20

# Image labels and digest
docker image inspect gromacs-demo:cuda --format '{{.Id}} {{.Size}} bytes'

# Smoke test — proves the image actually runs
docker run --rm gromacs-demo:cuda gmx --version | head -5
```

**Screenshot:** Open `container/Dockerfile` in a syntax-highlighted editor (VS Code is fine) and capture the multi-stage CUDA build. The two-stage `builder`-then-runtime structure is visually distinctive and reads well at projection size.

## 4. Azure AI Foundry project + model deployment

**Why show this:** "Foundry hosts the agent runtime. One deployment of GPT-4o."

```bash
# Foundry resource
az cognitiveservices account show \
  -n foundtry-agent-con-resource -g <your-rg> \
  --query "{name:name, kind:kind, sku:sku.name, endpoint:properties.endpoint}" -o table

# Deployments (the gpt-4o one)
az cognitiveservices account deployment list \
  -n foundtry-agent-con-resource -g <your-rg> \
  --query "[].{name:name, model:properties.model.name, version:properties.model.version, status:properties.provisioningState}" -o table
```

**Portal screenshots (the most photogenic ones):**
- Azure AI Foundry portal → Project `foundtry-agent-con` → Overview (shows the project endpoint URL)
- Same project → Models + endpoints → Deployments (shows `gpt-4o` with status `Succeeded`)
- Project → Agents (shows the `hpc-orchestrator-demo` agent if it's still registered; if it was auto-deleted, mention that the agent is created per-session)

## 5. RBAC — the role grants

**Why show this:** "The managed identity has exactly the access it needs. Nothing more."

```bash
# Role assignments on the Foundry resource for the VM's managed identity
PRINCIPAL=4635d6aa-2c6a-4fba-875b-f65e641ea1b9
RESOURCE_ID=$(az cognitiveservices account list \
  --query "[?name=='foundtry-agent-con-resource'].id | [0]" -o tsv)
az role assignment list \
  --assignee "$PRINCIPAL" --scope "$RESOURCE_ID" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

**Talk note:** the role-name discovery process (Azure AI User → Azure AI Developer → Foundry User) is one of the more entertaining stories in the build journey. Worth a sentence on stage even if not its own slide.

## 6. The end-to-end run, evidence-of-work

**Why show this:** "Here's what one full simulation generates on disk."

```bash
# Run directory layout
tree /data/run-XXXX -L 2

# Sizes
du -sh /data/run-XXXX/*

# A few representative lines from the production log
head -20 /data/run-XXXX/prod/md.log
grep "Performance:" /data/run-XXXX/prod/md.log
```

The `tree` output is particularly good because it visually documents the workflow stages — `em/`, `nvt/`, `prod/`, `analysis/`, `topology/` — in one image.

## 7. Optional: an asciinema recording

If you want a small inline recording of an inspection run (NOT the full demo — that's live), you can `asciinema rec build-tour.cast` while you walk through commands 1, 3, 4, 6 above. The result is a single text file that plays back as a terminal animation, embeddable in slides via `asciinema-player` or as a screen capture exported to MP4.

```bash
sudo apt-get install -y asciinema
asciinema rec --idle-time-limit 2 build-tour.cast
# run your inspection commands, Ctrl-D when done
asciinema play build-tour.cast    # to review
```

This is *optional*. A handful of well-chosen screenshots tells the same story without the slide-show dependency on a player.

---

## Suggested Slide 19 layout

A single slide with a 2×3 grid of screenshots:

```
+----------------+----------------+----------------+
| Azure RG       | VM details +   | Foundry        |
| topology       | NSG rule       | project +      |
|                |                | deployment     |
+----------------+----------------+----------------+
| Dockerfile     | docker images  | /data/run-XXX  |
| (CUDA build)   | + smoke test   | tree           |
+----------------+----------------+----------------+
```

Each tile gets one caption (8–12 words). The slide title is **"Behind the scenes — what's underneath the prompt."** Underneath: *"≈25 minutes of one-time setup, hidden behind one natural-language request."*

---

## What you do NOT need to do

- Rebuild any image
- Reprovision the VM
- Re-grant any roles
- Reinstall any drivers

The point of this journal is that the artifacts already exist. You're just photographing the museum, not pouring new exhibits.
