# Recording walkthrough — asciinema build tour

This document is a sequenced set of recording sessions. Each one is a self-contained chapter you can stop, rest, and pick up again. The recordings replicate the *build* of the demo against a parallel "recording" environment, so your working environment is never touched.

## Up-front: one-time setup (5 minutes)

### Decide your namespaces

```bash
# Recording infrastructure (parallel to your working agentcon-hpc-demo).
# Use these for the rest of the walkthrough.
export REC_RG=agentcon-hpc-record
export REC_VM=record-vm
export REC_LOCATION=eastus
export REC_VM_SIZE=Standard_NC4as_T4_v3 
#export REC_VM_SIZE=Standard_D4as_v5    # CPU-only, ~$0.05/hr, fast image build
```

### Install asciinema where you'll record

asciinema runs on the machine being recorded.

- For Recording 1 (Azure CLI from your laptop): `sudo apt-get install -y asciinema` in WSL
- For Recordings 2 and 4 (on a VM): you'll install it once inside each VM, instructions below

### Where casts get saved

```bash
mkdir -p ~/casts        # both on WSL and on each VM, when you get there
```

### Recording flags you'll use throughout

```bash
asciinema rec --idle-time-limit=1.5 --title "<chapter title>" ~/casts/<name>.cast
# --idle-time-limit=1.5 caps any pause in the playback to 1.5 seconds.
# Lets you think between commands without the recording feeling slow.
# Ctrl-D ends the recording cleanly.
```

---

## Recording 1 — Provisioning the Azure VM (3–4 min on tape)

**What the audience sees:** Azure CLI creates a resource group, a network, and a GPU-class VM. The story is "one script, ~3 minutes of Azure-side work, a VM exists."

### Pre-flight (do this BEFORE pressing record)

```bash
# In WSL
cd "/mnt/c/Users/victo/OneDrive/Claude/AgentCon Talk/agentcon-hpc-demo"
az account show --query name -o tsv     # confirm you're in the right subscription
```

### Press record

```bash
asciinema rec --idle-time-limit=1.5 --title "1. Provision the Azure VM" ~/casts/01-provision.cast
```

### Type these, in order, narrating as you go

```bash
# Show the namespace we're using (audience sees you're working in a separate RG)
echo "RG=$REC_RG  VM=$REC_VM  SIZE=$REC_VM_SIZE"

# Show the provisioning script (cat is fine; less if you want to scroll)
cat infra/provision-vm.sh | head -40

# Run the script with our recording-environment overrides
RG=$REC_RG VM_NAME=$REC_VM LOCATION=$REC_LOCATION VM_SIZE=$REC_VM_SIZE \
  ./infra/provision-vm.sh

# When it finishes, prove the VM is there
az vm show -d -g $REC_RG -n $REC_VM --query "{name:name, ip:publicIps, state:powerState}" -o table
```

### Stop

`Ctrl-D` to end the recording.

### What to narrate on stage (when you play this back)

- "One script. Azure CLI. About three minutes. Single GPU VM, NSG locked to my IP."
- During the long `az vm create` step (it streams a JSON response when done), say: "While this provisions, notice nothing about this is unique to AI agents. This is standard Azure infrastructure. The agent layer is going to sit on top of it."
- Skip to 2x speed during the JSON output to compress dead time.

---

## Recording 2 — Setting up the VM and building the GROMACS image (6–8 min on tape)

**What the audience sees:** SSH into the new VM, install Docker, build the GROMACS container, prove it runs.

### Pre-flight

```bash
# In WSL, get the new VM's IP
REC_IP=$(az vm show -d -g $REC_RG -n $REC_VM --query publicIps -o tsv)
echo "IP: $REC_IP"

# SSH in
ssh azureuser@$REC_IP

# On the VM, install asciinema and clone the repo
sudo apt-get update && sudo apt-get install -y asciinema git
git clone <your-repo-url> ~/agentcon-hpc-demo
# OR scp the repo over from WSL:
# (from another WSL terminal) scp -r /mnt/c/Users/victo/OneDrive/Claude/AgentCon\ Talk/agentcon-hpc-demo azureuser@$REC_IP:~/

mkdir -p ~/casts
cd ~/agentcon-hpc-demo
```

### Press record (on the VM)

```bash
asciinema rec --idle-time-limit=1.5 --title "2. Build the GROMACS image" ~/casts/02-build.cast
```

### Type these, in order

```bash
# Show that the VM is bare — no Docker yet
docker --version 2>&1 || echo "docker not installed yet"

# Run the on-VM setup (Docker + Python). For the recording, we use the
# CPU-only setup since we're building the CPU image (faster).
./infra/setup-vm-cpu.sh

# After setup, prove Docker works
docker version --format 'Client: {{.Client.Version}} / Server: {{.Server.Version}}'

# Show the Dockerfile we're about to build
head -30 container/Dockerfile.cpu

# Actually build the image. With the CPU image, this is ~6 minutes.
# During the build, you'll narrate over the compile output.
docker build -f container/Dockerfile.cpu -t gromacs-demo:cpu container/

# When build finishes, prove the image works
docker images gromacs-demo
docker run --rm gromacs-demo:cpu gmx --version | head -5
```

### Stop

`Ctrl-D`.

### What to narrate on stage

- "I'm on a fresh VM. No Docker. Two scripts to get to a working GROMACS container."
- During the long `docker build`, say: "GROMACS is being compiled inside the container. CMake, then several thousand compile units. This is where the heavy lifting of HPC normally lives. On the real demo VM, this is the CUDA build — same flow, longer compile."
- When `gmx --version` prints: "And there's the result. One pinned container, reproducible, ready to be driven by the agent."
- Use 2x during the compile output if the audience is getting restless. The cmake configure step (first 30s) is more interesting than the compile loop.

### Optional time-saver

If 6 minutes of compile is more than you want even at 2x, you can stop the recording right after typing the `docker build` command (Ctrl-D about 5 seconds into the build). Then start a SECOND short cast that just runs the inspection bit:

```bash
asciinema rec --idle-time-limit=1 --title "2b. Image is ready" ~/casts/02b-image-ready.cast
docker images gromacs-demo
docker run --rm gromacs-demo:cpu gmx --version | head -5
docker history gromacs-demo:cpu --format "table {{.CreatedSince}}\t{{.Size}}" --no-trunc | head -10
# Ctrl-D
```

Show the two clips back to back on stage. You skip the boring middle entirely.

---

## Recording 3 — Foundry RBAC dance (1–2 min on tape)

**What the audience sees:** the role-name discovery + grant story you actually lived through. Short and punchy.

### Pre-flight

You're in WSL. You're going to demonstrate the role-discovery script against your *existing* Foundry resource (no need to create a new one for the recording).

### Press record

```bash
asciinema rec --idle-time-limit=1.5 --title "3. Foundry RBAC discovery" ~/casts/03-foundry-rbac.cast
```

### Type these, in order

```bash
# Show what roles exist in this tenant
az role definition list \
  --query "[?contains(roleName, 'Foundry')].roleName" -o tsv

# Show the helper script's fallback chain
grep -A8 "CANDIDATES=" infra/grant-foundry-access.sh

# Show the current assignments on the existing Foundry resource
# (replace with your actual principal + resource name)
RESOURCE_ID=$(az cognitiveservices account list \
  --query "[?name=='foundtry-agent-con-resource'].id | [0]" -o tsv)
az role assignment list \
  --assignee 4635d6aa-2c6a-4fba-875b-f65e641ea1b9 \
  --scope "$RESOURCE_ID" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

### Stop

`Ctrl-D`.

### What to narrate on stage

- "Foundry has its own role pack. The role names changed mid-rollout — I started looking for `Azure AI User`, found that didn't exist, fell through to `Azure AI Developer`, then realised the actual Foundry-specific role is just `Foundry User`."
- "This is the kind of debugging tax you pay every time you wire up a new cloud service. The script just encodes the fallback chain so future-me doesn't have to relive it."

---

## Recording 4 — End-to-end agent run (90 s on tape, the BACKUP)

**What the audience sees:** the full demo executing from natural language to plots. This is your safety net if the live demo dies on stage.

### Pre-flight

This is recorded on your **working VM**, not the recording one, because we want a real end-to-end run with real data.

```bash
# In WSL
ssh azureuser@<working-vm-ip>

# On the working VM
sudo apt-get install -y asciinema       # one-time on working VM too
mkdir -p ~/casts
cd ~/agentcon-hpc/agentcon-hpc-demo
rm -rf /data/run-*          # clean slate; not strictly required
```

### Press record

```bash
asciinema rec --idle-time-limit=1.5 --title "4. End-to-end demo (backup)" ~/casts/04-demo.cast
```

### Type these, in order

```bash
# Set the explicit env prefix (or rely on .env if you've fixed it)
WORKFLOW_DIR=/home/azureuser/agentcon-hpc/agentcon-hpc-demo/workflow \
GMX_IMAGE=gromacs-demo:cuda \
GPU_VENDOR=nvidia \
python3 agent/agent.py
```

When the prompt appears, type:

```
Run a short molecular dynamics simulation of lysozyme in water.
```

Let the agent run. When it finishes and prints the summary, press `Ctrl-D` to exit the agent, then `Ctrl-D` again to end the asciinema recording.

### Stop

`Ctrl-D` twice.

### What to narrate on stage (if the live demo fails)

- "If you're seeing this, my live network had a bad moment. Same prompt, same agent, same VM. This was yesterday's run."
- "Notice the tool calls in sequence — same six steps the live agent would have made."

---

## Putting it all together — running the talk

You now have four `.cast` files:

```
~/casts/01-provision.cast       (≈3 min)
~/casts/02-build.cast           (≈6 min — use 2x or skip the middle)
~/casts/02b-image-ready.cast    (optional, ≈30 s)
~/casts/03-foundry-rbac.cast    (≈1 min)
~/casts/04-demo.cast            (≈90 s — your fallback)
```

### Playing during the talk

```bash
# In a terminal window, full-screened, with large font
asciinema play -s 1.5 ~/casts/01-provision.cast
# Press space to pause when you want to narrate over a section
# Press . to step a single frame
# Type a number (1-9) to skip to that percentage
```

`-s 1.5` plays at 1.5x speed throughout. Good default. You can also `-s 2` for the compile sections.

### Cleanup (after the talk)

```bash
# Delete the recording RG entirely
RG=$REC_RG ./infra/teardown.sh
```

Cost for the entire recording session: ~$0.50–$2 depending on how long you take.

