#!/usr/bin/env bash
# ==============================================================================
# Update PrintGuard Native LXC Installation
# Run inside the container (e.g. /opt/printguard/proxmox/update-printguard.sh)
# ==============================================================================

set -euo pipefail

INSTALL_DIR="/opt/printguard"
cd "${INSTALL_DIR}"

echo ">>> Pulling latest changes from git..."
git pull

echo ">>> Rebuilding web frontend..."
cd "${INSTALL_DIR}/web"
npm run build

echo ">>> Updating Python dependencies..."
cd "${INSTALL_DIR}"
VIRTUAL_ENV="${INSTALL_DIR}/.venv" uv pip install -e . --no-deps

echo ">>> Restarting printguard service..."
systemctl restart printguard
systemctl status printguard --no-pager
