#!/usr/bin/env bash
# One-time setup for a fresh Ubuntu 24.04 (arm64 or x86_64) EC2 instance.
# Paste into EC2 "User data" at launch, or run once:  sudo bash ec2-bootstrap.sh
# Installs Docker + Compose, adds swap, and prepares /opt/1apply. Safe to re-run.
set -euo pipefail

APP_DIR=/opt/1apply
APP_USER="${APP_USER:-ubuntu}"
REPO_RAW="https://raw.githubusercontent.com/ZuhaibAkhtarKhan/1apply.ai/main"

export DEBIAN_FRONTEND=noninteractive

# --- Docker Engine + Compose plugin (official apt repo) ---------------------
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Rotate container logs so the 20 GB disk doesn't fill up.
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
JSON
fi
systemctl enable --now docker
systemctl restart docker
usermod -aG docker "$APP_USER"

# --- 2 GB swap (t4g.small has 2 GB RAM) -------------------------------------
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
fi

# --- App directory -----------------------------------------------------------
mkdir -p "$APP_DIR"
curl -fsSL "$REPO_RAW/.env.example" -o "$APP_DIR/.env.example" || true
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

echo "Bootstrap complete. Next: create $APP_DIR/.env (see deploy/README.md)."
