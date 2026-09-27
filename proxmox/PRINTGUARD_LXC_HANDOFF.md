# PrintGuard GPU LXC on AMD Strix Halo - Setup and Operational Handoff

Last updated: 2026-09-27. This document lives in `proxmox/PRINTGUARD_LXC_HANDOFF.md` and should be copied to `/root/PRINTGUARD_LXC_HANDOFF.md` in Proxmox CT 128.

## What this is

PrintGuard runs as a native self-hosted systemd service inside an unprivileged Ubuntu 24.04 Proxmox LXC container (CT 128, `192.168.178.228:8000`), offloading on-device vision failure detection to the host's AMD Strix Halo GPU (gfx1151) via ROCm 7.2.4 and ONNX Runtime with AMD MIGraphX (`MIGraphXExecutionProvider`).

MediaMTX runs as a native standalone binary (`/usr/local/bin/mediamtx`), managing WebRTC, RTSP, and low-latency HLS video streaming without Docker.

The hub connects over LAN to OctoPrint running on a Raspberry Pi beside the Prusa 3D printer, monitoring print jobs, pulling camera frames, and taking fail-safe action (pause/cancel/alert) if print defects occur.

```
+-----------------------------------------------------------------------------------------+
| Proxmox Host (AMD Strix Halo APU, gfx1151)                                              |
|   Shared Character Devices: /dev/dri/renderD128 + /dev/kfd (gid 44)                     |
+--------------------------------------------+--------------------------------------------+
                                             |
                                             v
+-----------------------------------------------------------------------------------------+
| CT 128: PrintGuard Native LXC (Ubuntu 24.04 noble, 192.168.178.228)                     |
|                                                                                         |
|   +---------------------------------------------------------------------------------+   |
|   | printguard.service (/opt/printguard/.venv/bin/printguard)                       |   |
|   |   - FastAPI dashboard & REST API (:8000)                                        |   |
|   |   - ONNX Runtime 1.23.2 with MIGraphXExecutionProvider -> AMD GPU (Strix Halo) |   |
|   |   - Embedded MediaMTX binary (/usr/local/bin/mediamtx, ports 8554 / 8888 / 9997)|   |
|   |   - OctoPrintAdapter: polls /api/job, auto-discovers webcam, controls printer   |   |
|   +---------------------------------------------------------------------------------+   |
+--------------------------------------------+--------------------------------------------+
                                             |
                               LAN HTTP / MJPEG
                                             |
                                             v
+-----------------------------------------------------------------------------------------+
| OctoPrint on Raspberry Pi (near Prusa 3D Printer)                                       |
|   - OctoPrint REST API (:5000)                                                          |
|   - USB Webcam / Camera Stream                                                          |
+-----------------------------------------------------------------------------------------+
```

## Hardware and GPU sharing boundary

- The Strix Halo APU is shared with other containers (CT 102 LocalAI, CT 110 Lemonade, CT 112 AI, CT 126 OnnxTR) via `/dev/dri/renderD128` and `/dev/kfd`.
- **Never** perform exclusive PCI/VFIO passthrough, do not install kernel DKMS drivers inside the LXC, and do not modify host GPU kernel parameters.
- Container device mapping in `/etc/pve/lxc/128.conf`:
  ```
  dev0: path=/dev/dri/renderD128,gid=44,mode=0660
  dev1: path=/dev/kfd,gid=44,mode=0660
  ```

## Container Specifications

- **Container ID:** 128 (recommended, fits network scheme)
- **Hostname:** `printguard`
- **Template:** `ubuntu-24.04-standard_24.04-2_amd64.tar.zst`
- **Type:** Unprivileged LXC (`unprivileged: 1`, `features: nesting=1`)
- **Resources:** 4 CPU cores, 8192 MB RAM, 512 MB swap, 24 GB rootfs
- **Network:** Static IPv4 `192.168.178.228/24`, Gateway `192.168.178.1`, Bridge `vmbr0`
- **Ports exposed:**
  - `8000`: PrintGuard web dashboard, REST API, WebSocket, HLS video
  - `8554`: RTSP video in (for standalone cameras pushing RTSP)
  - `8888`: HLS internal streaming port
  - `9997`: MediaMTX internal control API

## Deployment Procedure

### Step 1: Create Container on Proxmox VE Host

Execute on the Proxmox host:

```bash
# Option A: Automated host script
cd /root  # or directory where the repository / setup scripts are available
bash proxmox/create-printguard-lxc.sh

# Option B: Manual creation via pct
pct create 128 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname printguard \
  --cores 4 \
  --memory 8192 \
  --swap 512 \
  --ostype ubuntu \
  --rootfs local-lvm:24 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.178.228/24,gw=192.168.178.1,firewall=0 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --tags "3d-printing,amd,printguard"

# Append GPU character devices to container config
cat <<'EOF' >> /etc/pve/lxc/128.conf
dev0: path=/dev/dri/renderD128,gid=44,mode=0660
dev1: path=/dev/kfd,gid=44,mode=0660
EOF

pct start 128
```

### Step 2: Install PrintGuard Natively inside CT 128

Enter the container from the host:

```bash
pct enter 128
```

Inside the container:

```bash
# Clone repository
git clone https://github.com/oliverbravery/printguard /opt/printguard
cd /opt/printguard

# Run native installer
bash proxmox/install-printguard-lxc.sh
```

The installer takes care of:
1. AMD ROCm 7.2.4 apt repository configuration and pinning in `/etc/apt/preferences.d/rocm`.
2. Installation of `rocm-core`, `migraphx`, and `rocm-smi`.
3. Installation of Node.js 22 and Astral `uv`.
4. Standalone binary download of MediaMTX 1.18.2 to `/usr/local/bin/mediamtx`.
5. Creation of Python 3.12 virtualenv at `/opt/printguard/.venv`.
6. Installation of `onnxruntime-migraphx==1.23.2` wheel from AMD's ROCm release repository.
7. Installation of PrintGuard dependencies via `uv pip`.
8. Building the React/Vite web dashboard in `web/dist`.
9. Environment configuration in `/etc/default/printguard`.
10. Enabling and starting `printguard.service`.

## Service Configuration & Environment

Environment variables in `/etc/default/printguard`:

```bash
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
```

MIGraphX caches compiled model execution plans (`.mxr`) inside `/var/lib/printguard/cache/migraphx`. Initial model load takes a few seconds for graph compilation; subsequent launches load the cached plan in milliseconds.

## Connecting OctoPrint and the Prusa Camera

1. Open PrintGuard dashboard in browser: `http://192.168.178.228:8000`
2. Navigate to **Settings** (gear icon) > **Printers** > **Add Printer**.
3. Select **OctoPrint** from the adapter dropdown.
4. Enter:
   - **Base URL:** `http://<octoprint-ip>:5000` (or `http://octopi.local:5000`)
   - **API key:** API key generated in OctoPrint under **Settings** > **Application Keys**.
5. Save the printer. PrintGuard immediately polls the job status and queries `/api/settings`.
6. The webcam configured in OctoPrint (`plugins.classicwebcam.stream` or `webcam.streamUrl`) is automatically discovered and registered under **Cameras**.
7. In **Monitors**, create or verify a monitor pairing the Prusa printer with the discovered camera stream. Set the defect pause sensitivity and push alert destinations as desired.

## Verification Checklist for the Testing Agent

When verifying the deployed container end-to-end, execute these checks:

### 1. GPU Accessibility
Inside CT 128:
```bash
ls -la /dev/dri/renderD128 /dev/kfd
# Both should be present with read/write permissions for root / video group (gid 44)

rocm-smi
# Shows AMD Strix Halo GPU temperature, power, and memory metrics

rocminfo | grep gfx
# Expects gfx1151
```

### 2. ONNX Runtime & MIGraphX Providers
Inside CT 128:
```bash
/opt/printguard/.venv/bin/python -c "import onnxruntime as ort; print('Available providers:', ort.get_available_providers())"
# Must include 'MIGraphXExecutionProvider' and 'CPUExecutionProvider'
```

### 3. PrintGuard Service Health
```bash
systemctl status printguard --no-pager
journalctl -u printguard -n 50 --no-pager
```
Look for lines confirming:
- `hub starting (data=/var/lib/printguard, ...)`
- MediaMTX started successfully on ports 8554 / 8888 / 9997
- Inference runtime initialized with device `AMD GPU`:
  `INFO printguard.server.inference: active compute: AMD GPU`

### 4. API & Active Compute Verification
```bash
curl -s http://127.0.0.1:8000/api/health
# Returns HTTP 200

curl -s http://127.0.0.1:8000/api/v1/status | jq .
# Field "inference_device" must report "AMD GPU"
```

### 5. MediaMTX Video Streaming
```bash
curl -s http://127.0.0.1:9997/v3/paths/list
# Returns MediaMTX active streams
```

## Maintenance & Updates

To update PrintGuard inside the container:
```bash
bash /opt/printguard/proxmox/update-printguard.sh
```

To restart the service:
```bash
systemctl restart printguard
```

To review real-time logs:
```bash
journalctl -u printguard -f
```
