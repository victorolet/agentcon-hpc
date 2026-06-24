#!/usr/bin/env bash
# Run this ON the VM, as $ADMIN_USER, after first SSH.
#
# CPU-only path. No GPU driver, no container runtime toolkit. Just:
#   - Docker Engine + buildx
#   - Python 3.11
#   - /data directory writable by the user
#
# Use this when:
#   - The AMD path on NV*as_v4 couldn't see the GPU (rocminfo found nothing)
#   - You want a guaranteed-working safety net for the demo
#   - You're prototyping on a non-GPU SKU
#
# Pair with: docker build -f container/Dockerfile.cpu -t gromacs-demo:cpu container/
# And in agent/.env: GPU_VENDOR=cpu, GMX_IMAGE=gromacs-demo:cpu
#
# No reboot. Idempotent.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run as the regular user, not root. The script will sudo where needed." >&2
  exit 1
fi

UBUNTU_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

# ---- Docker --------------------------------------------------------------
if ! command -v docker >/dev/null; then
  echo "==> Installing Docker Engine"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg

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

# ---- Python --------------------------------------------------------------
sudo apt-get install -y python3.11 python3.11-venv python3-pip jq

# ---- data dir ------------------------------------------------------------
sudo mkdir -p /data
sudo chown "$USER:$USER" /data

# ---- smoke test ----------------------------------------------------------
if docker info >/dev/null 2>&1; then
  echo "==> Smoke testing Docker"
  docker run --rm hello-world >/dev/null && echo "    Docker is healthy."
else
  echo "Docker not accessible without sudo — log out/in and re-run this script." >&2
  exit 1
fi

cat <<EOF

==> CPU-only VM setup complete.

Next:
  cd ~/agentcon-hpc-demo/container && docker build -f Dockerfile.cpu -t gromacs-demo:cpu .

  cd ~/agentcon-hpc-demo/agent
  cp .env.example .env && \$EDITOR .env
  # In .env, set:
  #   GPU_VENDOR=cpu
  #   GMX_IMAGE=gromacs-demo:cpu
  pip install -r requirements.txt
  python agent.py

Performance note: lysozyme 50 ps production MD takes ~90–180 s on 8 vCPU.
For a snappier live demo, shorten production by passing nsteps=12500 to
run_stage (25 ps, ~45–90 s).
EOF
