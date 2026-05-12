#!/usr/bin/env bash
# Run this ON THE VM, as $ADMIN_USER, after first SSH.
#
# Installs:
#   - NVIDIA driver (the cuda-drivers metapackage)
#   - Docker Engine + buildx
#   - NVIDIA Container Toolkit (for `docker run --gpus all`)
#   - Python 3.11 + venv
#
# Idempotent: re-running is safe.
#
# Reboots once after the driver install. Re-run after reboot to finish.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run as the regular user, not root. The script will sudo where needed." >&2
  exit 1
fi

STAMP=/var/lib/agentcon-setup
sudo mkdir -p "$STAMP"

# ---- stage 1: NVIDIA driver ---------------------------------------------
if [[ ! -f "$STAMP/driver-installed" ]]; then
  echo "==> Installing NVIDIA driver (will reboot at end of stage 1)"
  sudo apt-get update
  sudo apt-get install -y build-essential dkms curl ca-certificates gnupg

  # NVIDIA CUDA repo for Ubuntu 22.04
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    -o /tmp/cuda-keyring.deb
  sudo dpkg -i /tmp/cuda-keyring.deb
  sudo apt-get update
  sudo apt-get install -y cuda-drivers

  sudo touch "$STAMP/driver-installed"
  echo "==> Driver installed. Rebooting in 10s. Re-run this script after reboot."
  sleep 10
  sudo reboot
  exit 0
fi

# ---- stage 2: verify driver ---------------------------------------------
if ! command -v nvidia-smi >/dev/null; then
  echo "nvidia-smi not found after reboot. Driver install may have failed." >&2
  exit 1
fi
echo "==> GPU detected:"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader

# ---- stage 3: Docker -----------------------------------------------------
if ! command -v docker >/dev/null; then
  echo "==> Installing Docker Engine"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  sudo usermod -aG docker "$USER"
  echo "==> Added $USER to the docker group. You will need a fresh shell for this to take effect."
fi

# ---- stage 4: NVIDIA Container Toolkit ----------------------------------
if [[ ! -f /etc/docker/daemon.json ]] || ! grep -q nvidia /etc/docker/daemon.json; then
  echo "==> Installing NVIDIA Container Toolkit"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
fi

# ---- stage 5: Python -----------------------------------------------------
sudo apt-get install -y python3.11 python3.11-venv python3-pip jq

# ---- stage 6: data dir ---------------------------------------------------
sudo mkdir -p /data
sudo chown "$USER:$USER" /data

# ---- stage 7: smoke test the GPU container ------------------------------
echo "==> Smoke testing GPU container access"
if docker info >/dev/null 2>&1; then
  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi || {
    echo "GPU container smoke test failed. You may need to log out/in for docker group membership." >&2
    exit 1
  }
else
  echo "Docker daemon not accessible without sudo yet — log out and back in, then re-run this script." >&2
  exit 1
fi

cat <<EOF

==> VM setup complete.

Next:
  cd ~/agentcon-hpc-demo/container && docker build -t gromacs-demo:latest .
  cd ~/agentcon-hpc-demo/agent && cp .env.example .env && \$EDITOR .env
  pip install -r requirements.txt
  python agent.py
EOF
