#!/usr/bin/env bash
# ==============================================================================
# Create PrintGuard GPU LXC Container on Proxmox VE Host
# Run this script directly on the Proxmox VE host (e.g. via ssh or PVE shell).
#
# Hardware: AMD Strix Halo GPU sharing (/dev/dri/renderD128 + /dev/kfd)
# OS: Ubuntu 24.04 LTS (noble)
# ==============================================================================

set -euo pipefail

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
    log_err "This script must be run as root on the Proxmox VE host."
    exit 1
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Create PrintGuard LXC Container (Proxmox VE)   ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo ""

# Verify host AMD GPU devices exist
log_info "Verifying host AMD GPU devices..."
if [ ! -e /dev/kfd ] || [ ! -e /dev/dri/renderD128 ]; then
    log_warn "Host GPU device nodes /dev/kfd or /dev/dri/renderD128 are not present!"
    log_warn "Ensure the AMD GPU driver is loaded on the Proxmox host."
    read -r -p "Continue anyway? [y/N]: " CONT
    if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    log_ok "Host AMD GPU detected (/dev/kfd and /dev/dri/renderD128 present)."
fi

# Configuration parameters
read -r -p "Enter container ID [128]: " CT_ID
CT_ID=${CT_ID:-128}

read -r -p "Enter container hostname [printguard]: " CT_HOSTNAME
CT_HOSTNAME=${CT_HOSTNAME:-printguard}

read -r -p "Enter container RAM in MB [4096]: " CT_RAM
CT_RAM=${CT_RAM:-4096}

read -r -p "Enter container CPU cores [2]: " CT_CORES
CT_CORES=${CT_CORES:-2}

read -r -p "Enter disk size in GB [24]: " CT_DISK
CT_DISK=${CT_DISK:-24}
CT_DISK_SIZE="${CT_DISK//[!0-9]/}"

read -r -p "Enter storage pool [local-lvm]: " CT_STORAGE
CT_STORAGE=${CT_STORAGE:-local-lvm}

read -r -p "Enter network bridge [vmbr0]: " CT_BRIDGE
CT_BRIDGE=${CT_BRIDGE:-vmbr0}

read -r -p "Enter container IPv4 with CIDR [192.168.178.228/24]: " CT_IP
CT_IP=${CT_IP:-192.168.178.228/24}

read -r -p "Enter IPv4 gateway [192.168.178.1]: " CT_GW
CT_GW=${CT_GW:-192.168.178.1}

# Locate or download Ubuntu 24.04 template
TEMPLATE_DIR="/var/lib/vz/template/cache"
TEMPLATE_NAME=$(pveam list local 2>/dev/null | grep -o 'ubuntu-24.04-standard.*\.tar\.zst' | head -n1 || true)

if [ -z "$TEMPLATE_NAME" ]; then
    log_info "Downloading Ubuntu 24.04 template..."
    pveam update
    pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst || pveam download local ubuntu-24.04-standard_24.04-1_amd64.tar.zst
    TEMPLATE_NAME=$(pveam list local | grep -o 'ubuntu-24.04-standard.*\.tar\.zst' | head -n1)
fi

log_info "Using template: local:vztmpl/${TEMPLATE_NAME}"

# Create unprivileged container
log_info "Creating container ${CT_ID} (${CT_HOSTNAME})..."
pct create "${CT_ID}" "local:vztmpl/${TEMPLATE_NAME}" \
    --hostname "${CT_HOSTNAME}" \
    --cores "${CT_CORES}" \
    --memory "${CT_RAM}" \
    --swap 512 \
    --ostype ubuntu \
    --rootfs "${CT_STORAGE}:${CT_DISK_SIZE}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW},firewall=0" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --tags "3d-printing,amd,printguard"

# Configure AMD GPU device sharing in /etc/pve/lxc/<id>.conf
CONF_FILE="/etc/pve/lxc/${CT_ID}.conf"
log_info "Configuring AMD GPU device sharing in ${CONF_FILE}..."

cat <<'EOF' >> "${CONF_FILE}"
# AMD GPU device sharing (Strix Halo / gfx1151)
dev0: path=/dev/dri/renderD128,gid=44,mode=0660
dev1: path=/dev/kfd,gid=44,mode=0660
EOF

log_ok "GPU passthrough configured."

# Start container
log_info "Starting container ${CT_ID}..."
pct start "${CT_ID}"
sleep 5

# Wait for network
log_info "Waiting for network connectivity inside container..."
for i in {1..15}; do
    if pct exec "${CT_ID}" -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        log_ok "Network is online inside CT ${CT_ID}."
        break
    fi
    sleep 2
done

echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}Container ${CT_ID} created and started successfully!${NC}"
echo -e "${GREEN}IP: ${CT_IP%/*}${NC}"
echo ""
echo -e "To install PrintGuard natively inside CT ${CT_ID}:"
echo -e "1) Enter the container:"
echo -e "   ${BLUE}pct enter ${CT_ID}${NC}"
echo -e "2) Clone your PrintGuard repository into /opt/printguard:"
echo -e "   ${BLUE}git clone <repo-url> /opt/printguard${NC}"
echo -e "3) Run the native installer:"
echo -e "   ${BLUE}cd /opt/printguard && bash proxmox/install-printguard-lxc.sh${NC}"
echo -e "${GREEN}====================================================${NC}"
