#!/usr/bin/env bash
# Run this ON the VM, as $ADMIN_USER, after first SSH to an Azure NV*as_v4
# (AMD MI25 / Vega 10 / gfx900 via MxGPU virtualization).
#
# Installs:
#   - amdgpu-dkms (open AMD kernel driver)
#   - ROCm 5.7 runtime (last release with first-class gfx900 support)
#   - Docker Engine + buildx
#   - Python 3.11 + venv
#
# Then verifies the GPU is visible to ROCm via rocminfo.
#
# Idempotent: re-runs are safe.
# Reboots once after driver install. Re-run after reboot to finish.
#
# IMPORTANT: NV*as_v4 is not officially supported for ROCm/compute by Azure.
# This script gets ROCm onto the box; whether the MxGPU layer lets ROCm
# actually see the GPU is the open question. See docs/gpu-vendors.md.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run as the regular user, not root. The script will sudo where needed." >&2
  exit 1
fi

STAMP=/var/lib/agentcon-setup
sudo mkdir -p "$STAMP"

ROCM_VERSION=5.7.1
UBUNTU_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

# ---- stage 1: AMDGPU + ROCm repo + kernel driver ------------------------
if [[ ! -f "$STAMP/amd-driver-installed" ]]; then
  echo "==> Adding AMD repos and installing amdgpu-dkms + ROCm $ROCM_VERSION"

  sudo apt-get update
  sudo apt-get install -y wget gnupg ca-certificates lsb-release \
       build-essential dkms linux-headers-"$(uname -r)" curl

  # AMDGPU installer package gives us a clean way to add both repos.
  wget -qO /tmp/amdgpu-install.deb \
    "https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${UBUNTU_CODENAME}/amdgpu-install_5.7.50701-1_all.deb"
  sudo apt-get install -y /tmp/amdgpu-install.deb

  # --usecase=rocm pulls the compute stack; --no-dkms because we'll
  # install dkms separately to control kernel module rebuilds.
  sudo amdgpu-install -y --usecase=rocm --no-dkms
  sudo apt-get install -y amdgpu-dkms

  # Permission groups so a non-root user can use the device.
  sudo usermod -a -G render,video "$USER"

  sudo touch "$STAMP/amd-driver-installed"
  echo "==> AMDGPU + ROCm installed. Rebooting in 10s. Re-run after reboot."
  sleep 10
  sudo reboot
  exit 0
fi

# ---- stage 2: verify ROCm sees the GPU ----------------------------------
echo "==> Verifying ROCm device visibility"
if ! command -v /opt/rocm/bin/rocminfo >/dev/null; then
  echo "/opt/rocm/bin/rocminfo missing. ROCm install may have failed." >&2
  exit 1
fi

ROCMINFO_OUT=$(/opt/rocm/bin/rocminfo 2>&1 || true)
if echo "$ROCMINFO_OUT" | grep -qE "Name: *gfx[0-9]+"; then
  GFX=$(echo "$ROCMINFO_OUT" | grep -oE "gfx[0-9]+" | head -1)
  echo "==> ROCm sees GPU: $GFX"
  if [[ "$GFX" != "gfx900" ]]; then
    echo "    (expected gfx900 for MI25; got $GFX — adjust HSA_OVERRIDE_GFX_VERSION if needed)"
  fi
else
  echo "WARNING: rocminfo found no GPU agents." >&2
  echo "         NV*as_v4's MxGPU layer may be blocking compute access." >&2
  echo "         See docs/gpu-vendors.md for fallback paths." >&2
  echo "         Continuing setup so the CPU fallback still works." >&2
fi

# ---- stage 3: Docker -----------------------------------------------------
if ! command -v docker >/dev/null; then
  echo "==> Installing Docker Engine"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  sudo usermod -aG docker "$USER"
  echo "==> Added $USER to the docker group. Log out/in for it to take effect."
fi

# ---- stage 4: Python -----------------------------------------------------
sudo apt-get install -y python3.11 python3.11-venv python3-pip jq

# ---- stage 5: data dir ---------------------------------------------------
sudo mkdir -p /data
sudo chown "$USER:$USER" /data

# ---- stage 6: smoke test the ROCm container -----------------------------
# Unlike NVIDIA, there's no special container runtime to install. ROCm
# uses --device=/dev/kfd --device=/dev/dri --group-add video to expose
# the GPU to a container.
if docker info >/dev/null 2>&1; then
  echo "==> Smoke testing ROCm container access"
  if docker run --rm \
        --device=/dev/kfd --device=/dev/dri \
        --group-add video \
        --security-opt seccomp=unconfined \
        rocm/rocm-terminal:5.7 \
        /opt/rocm/bin/rocminfo 2>&1 | grep -qE "Name: *gfx[0-9]+"; then
    echo "    ROCm container can see the GPU. You're in business."
  else
    echo "    ROCm container could NOT see the GPU." >&2
    echo "    Use GPU_VENDOR=cpu for the demo (see docs/gpu-vendors.md)." >&2
  fi
else
  echo "Docker not accessible without sudo — log out/in and re-run this script." >&2
  exit 1
fi

cat <<EOF

==> VM setup complete.

Next:
  # If ROCm saw the GPU:
  cd ~/agentcon-hpc-demo/container && docker build -f Dockerfile.rocm -t gromacs-demo:rocm .
  # In agent/.env, set: GPU_VENDOR=amd  GMX_IMAGE=gromacs-demo:rocm

  # If ROCm did NOT see the GPU (CPU fallback):
  cd ~/agentcon-hpc-demo/container && docker build -f Dockerfile.cpu -t gromacs-demo:cpu .
  # In agent/.env, set: GPU_VENDOR=cpu  GMX_IMAGE=gromacs-demo:cpu

  Then:
  cd ~/agentcon-hpc-demo/agent
  cp .env.example .env && \$EDITOR .env
  pip install -r requirements.txt
  python agent.py
EOF
