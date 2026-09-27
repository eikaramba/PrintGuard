#!/usr/bin/env bash
# ==============================================================================
# PrintGuard Native LXC Installer (Proxmox VE + AMD Strix Halo / ROCm)
# Run inside an Ubuntu 24.04 LTS (noble) LXC container.
#
# Hardware: AMD Strix Halo (gfx1151) sharing /dev/dri/renderD128 and /dev/kfd
# Runtime: Python 3.12 venv, AMD ROCm 7.2.4 + MIGraphX, onnxruntime-migraphx, MediaMTX
# ==============================================================================

set -euo pipefail
export PATH="/usr/local/bin:$PATH"

# Visual formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err() { echo -e "${RED}[ERROR]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then
    log_err "This installer must be run as root inside the LXC container."
    exit 1
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}    PrintGuard Native LXC Installer (AMD ROCm)    ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Device check
log_info "Checking AMD GPU device nodes..."
if [ ! -e /dev/kfd ]; then
    log_warn "/dev/kfd is missing! Verify container configuration (/etc/pve/lxc/<id>.conf):"
    log_warn "  dev0: path=/dev/dri/renderD128,gid=44,mode=0660"
    log_warn "  dev1: path=/dev/kfd,gid=44,mode=0660"
else
    log_ok "Found /dev/kfd ($(stat -c 'mode=%a gid=%g' /dev/kfd))"
fi

if [ -e /dev/dri/renderD128 ]; then
    log_ok "Found /dev/dri/renderD128 ($(stat -c 'mode=%a gid=%g' /dev/dri/renderD128))"
else
    log_warn "/dev/dri/renderD128 not found. Falling back to CPU until device is mapped."
fi

# Ensure render/video group permissions
if getent group render >/dev/null; then
    usermod -aG render root 2>/dev/null || true
fi
if getent group video >/dev/null; then
    usermod -aG video root 2>/dev/null || true
fi

# 2. System updates and prerequisites
log_info "Installing core build and runtime packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    git \
    lsb-release \
    build-essential \
    pkg-config \
    python3 \
    python3-dev \
    python3-venv \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    pciutils \
    tar \
    jq

# 3. Add AMD ROCm 7.2.4 repository
log_info "Configuring AMD ROCm 7.2.4 apt repository..."
mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/rocm.gpg ]; then
    curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
fi

cat <<'EOF' > /etc/apt/sources.list.d/rocm.list
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.4 noble main
EOF

# Pin ROCm packages to prevent breaking partial upgrades
cat <<'EOF' > /etc/apt/preferences.d/rocm
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 600
EOF

apt-get update
log_info "Installing ROCm and MIGraphX..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    rocm-core \
    migraphx \
    rocm-smi \
    rocminfo || {
        log_warn "ROCm apt packages encountered a warning; continuing."
    }

# 4. Install Node.js 22 (for frontend build)
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d'.' -f1 | tr -d 'v')" -lt 20 ]; then
    log_info "Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
fi
log_ok "Node.js $(node -v) installed."

# 5. Install Astral uv
if ! command -v uv >/dev/null 2>&1; then
    log_info "Installing Astral uv..."
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
fi
log_ok "uv $(uv --version) ready."

# 6. Install MediaMTX binary
MEDIAMTX_VERSION="1.18.2"
if [ ! -x /usr/local/bin/mediamtx ]; then
    log_info "Installing MediaMTX v${MEDIAMTX_VERSION}..."
    TMP_MTX=$(mktemp -d)
    curl -fsSL "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_linux_amd64.tar.gz" -o "${TMP_MTX}/mediamtx.tar.gz"
    tar -xzf "${TMP_MTX}/mediamtx.tar.gz" -C /usr/local/bin mediamtx
    chmod +x /usr/local/bin/mediamtx
    rm -rf "${TMP_MTX}"
fi
log_ok "MediaMTX binary ready at /usr/local/bin/mediamtx."

# 7. Setup Application Directory
INSTALL_DIR="/opt/printguard"
DATA_DIR="/var/lib/printguard"
mkdir -p "${DATA_DIR}/cache/migraphx" "${DATA_DIR}/recordings" "${DATA_DIR}/snapshots"
chmod 750 "${DATA_DIR}"

if [ ! -d "${INSTALL_DIR}/.git" ] && [ ! -f "${INSTALL_DIR}/pyproject.toml" ]; then
    log_info "Creating /opt/printguard..."
    mkdir -p "${INSTALL_DIR}"
fi

cd "${INSTALL_DIR}"

# 8. Setup Python virtual environment
log_info "Setting up Python virtual environment with uv..."
uv venv --seed --python python3.12 "${INSTALL_DIR}/.venv"

# 9. Install onnxruntime-migraphx wheel from AMD ROCm repository
log_info "Installing onnxruntime-migraphx for ROCm 7.2.4..."
MIGRAPHX_WHEEL_URL="https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2.4/onnxruntime_migraphx-1.23.2-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"
FALLBACK_WHEEL_URL="https://github.com/Looong01/onnxruntime-rocm-build/releases/download/v1.23.2/onnxruntime_migraphx-1.23.2-cp312-cp312-manylinux_2_34_x86_64.whl"

# Install AMD wheel without pulling standard onnxruntime
"${INSTALL_DIR}/.venv/bin/pip" install --no-deps "${MIGRAPHX_WHEEL_URL}" || \
"${INSTALL_DIR}/.venv/bin/pip" install --no-deps "${FALLBACK_WHEEL_URL}" || {
    log_err "Failed to install onnxruntime-migraphx wheel!"
    exit 1
}

# 10. Install project dependencies via uv
log_info "Syncing PrintGuard dependencies..."
if [ -f "${INSTALL_DIR}/pyproject.toml" ]; then
    # Install dependencies without overwriting onnxruntime-migraphx
    VIRTUAL_ENV="${INSTALL_DIR}/.venv" uv pip install -e . --no-deps
    # Install remaining requirements
    VIRTUAL_ENV="${INSTALL_DIR}/.venv" uv pip install \
        "ai-edge-litert>=2.1.5" \
        "aiomqtt>=2.5.1" \
        "av>=14.0" \
        "coloredlogs" \
        "fastapi>=0.136.3" \
        "fastmcp>=3.4.2" \
        "httpx>=0.28" \
        "ml-dtypes>=0.5.1" \
        "numpy>=2.1,<2.2" \
        "packaging>=24.0" \
        "paho-mqtt>=2.1" \
        "flatbuffers" \
        "pillow>=10" \
        "protobuf" \
        "pycentauri>=0.7.0" \
        "pydantic-settings>=2.14.2" \
        "pyprusalink>=3.0" \
        "starlette>=1.3.1" \
        "sympy" \
        "uvicorn[standard]>=0.49.0" \
        "wasmtime>=47.0"
fi

# 11. Build Web Dashboard
if [ -d "${INSTALL_DIR}/web" ]; then
    log_info "Building web dashboard..."
    cd "${INSTALL_DIR}/web"
    npm ci || npm install
    npm run build
    cd "${INSTALL_DIR}"
    log_ok "Web frontend built."
fi

# 12. Environment file
log_info "Writing /etc/default/printguard..."
cat <<'EOF' > /etc/default/printguard
# PrintGuard Native LXC Environment (AMD Strix Halo / ROCm)
DATA_DIR=/var/lib/printguard
MODEL_DIR=/opt/printguard/models
STATIC_DIR=/opt/printguard/web/dist
MEDIAMTX_BINARY=/usr/local/bin/mediamtx
MEDIAMTX_CONFIG=/opt/printguard/mediamtx.yml
PORT=8000
RTSP_PORT=8554
HLS_PORT=8888
MEDIAMTX_API=http://localhost:9997
MEDIAMTX_RTSP=rtsp://localhost:8554
PRINTGUARD_VARIANT=linux-amd

# AMD Strix Halo / ROCm optimizations
HSA_OVERRIDE_GFX_VERSION=11.5.1
ROCBLAS_USE_HIPBLASLT=1
HSA_XNACK=1
HSA_ENABLE_SDMA=0
ORT_MIGRAPHX_MODEL_CACHE_PATH=/var/lib/printguard/cache/migraphx
OMP_NUM_THREADS=1
EOF

# 13. Systemd service
log_info "Installing systemd service /etc/systemd/system/printguard.service..."
cat <<'EOF' > /etc/systemd/system/printguard.service
[Unit]
Description=PrintGuard 3D Printer Watchdog
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/printguard
EnvironmentFile=-/etc/default/printguard
ExecStart=/opt/printguard/.venv/bin/printguard
Restart=always
RestartSec=3
LimitNOFILE=65535
MemoryMax=6G

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable printguard.service
if [ -f "${INSTALL_DIR}/proxmox/PRINTGUARD_LXC_HANDOFF.md" ]; then
    cp "${INSTALL_DIR}/proxmox/PRINTGUARD_LXC_HANDOFF.md" /root/PRINTGUARD_LXC_HANDOFF.md
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}PrintGuard installation complete!${NC}"
echo -e "${GREEN}Start service with: systemctl start printguard${NC}"
echo -e "${GREEN}Check status with:  systemctl status printguard${NC}"
echo -e "${GREEN}View logs with:    journalctl -u printguard -f${NC}"
echo -e "${GREEN}Dashboard URL:     http://<container-ip>:8000${NC}"
echo -e "${GREEN}====================================================${NC}"
