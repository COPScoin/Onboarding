#!/bin/bash
###############################################################################
# SATELLITE MINER SETUP — CPU + GPU (AMD MI25 / Vega 10)
# TARGET OS: Debian 12 (Bookworm)
#
# Architecture:
#   [This VM: xmrig CPU+GPU] → [This VM: p2pool :3333] → [Main Node: monerod :18081/:18083]
#
# xmrig mines to LOCAL p2pool (127.0.0.1:3333)
# p2pool connects to REMOTE monerod (main node)
#
# Main Node IP: 20.62.43.171
# GPU: AMD Vega 10 (Instinct MI25 / MxGPU)
#
# Usage: sudo bash setup-satellite-gpu.sh
###############################################################################

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIG — EDIT THESE IF NEEDED
# ═══════════════════════════════════════════════════════════════════════════════
MAIN_NODE_IP="20.62.43.171"          # Where monerod runs
MONEROD_RPC_PORT="18081"             # monerod RPC
MONEROD_ZMQ_PORT="18083"             # monerod ZMQ pub
WALLET_ADDRESS="42ykwPdhRp9YNaXVJ3jrXnKzF84CneMdoPTTC4SFzqUVHkXmUocKG9FYo8wWymMgApCiyKkYfCb9USPvV9Er67ce86xu7Ho"
P2POOL_STRATUM_PORT="3333"           # LOCAL p2pool stratum (xmrig connects here)
P2POOL_P2P_PORT="37889"              # p2pool sidechain p2p
XMRIG_VERSION="6.22.2"
P2POOL_VERSION="4.5"
INSTALL_DIR="/opt/mining"
USE_MINI="--mini"                    # Use mini sidechain (better for low hashrate)
ROCM_VERSION="6.4.1"                 # ROCm version for Debian 12
# ═══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

[ "$EUID" -ne 0 ] && { err "Run as root: sudo bash setup-satellite-gpu.sh"; exit 1; }

# Check we're on Debian 12
if ! grep -q "bookworm\|12" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Debian 12 (Bookworm)"
    read -p "Continue anyway? [y/N] " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

HOSTNAME=$(hostname)
NEEDS_REBOOT=false

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  SATELLITE MINER SETUP — CPU + GPU (AMD MI25)"
echo "  Target OS:  Debian 12 (Bookworm)"
echo "  This VM:    $HOSTNAME ($(hostname -I 2>/dev/null | awk '{print $1}'))"
echo "  Main Node:  $MAIN_NODE_IP (monerod)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── STEP 1: System Info ────────────────────────────────────────────────────
log "System info:"
echo "  OS:       $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo "  Kernel:   $(uname -r)"
echo "  CPU:      $(lscpu | grep 'Model name' | sed 's/Model name:\s*//')"
echo "  Cores:    $(nproc)"
echo "  RAM:      $(free -h | awk '/Mem:/{print $2}')"
GPU_INFO=$(lspci | grep -i "VGA\|Display\|3D" | grep -i "AMD\|ATI" || echo "NONE")
echo "  GPU:      $GPU_INFO"
echo ""

if [ "$GPU_INFO" = "NONE" ]; then
    err "No AMD GPU detected! Use setup-satellite.sh (CPU-only) instead."
    exit 1
fi

# ─── STEP 2: Test connectivity to main node ─────────────────────────────────
info "Testing connectivity to main node ($MAIN_NODE_IP)..."

if ping -c 1 -W 3 "$MAIN_NODE_IP" > /dev/null 2>&1; then
    log "Main node is reachable (ping OK)"
else
    warn "Ping failed — may be blocked by firewall, continuing..."
fi

apt-get update -qq
apt-get install -y -qq netcat-openbsd > /dev/null 2>&1 || true

if command -v nc &>/dev/null; then
    if nc -zw3 "$MAIN_NODE_IP" "$MONEROD_RPC_PORT" 2>/dev/null; then
        log "monerod RPC port $MONEROD_RPC_PORT reachable ✓"
    else
        err "Cannot reach $MAIN_NODE_IP:$MONEROD_RPC_PORT!"
        err "Check Azure NSG rules — need inbound TCP 18081 and 18083"
        read -p "Continue anyway? [y/N] " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    if nc -zw3 "$MAIN_NODE_IP" "$MONEROD_ZMQ_PORT" 2>/dev/null; then
        log "monerod ZMQ port $MONEROD_ZMQ_PORT reachable ✓"
    else
        err "Cannot reach $MAIN_NODE_IP:$MONEROD_ZMQ_PORT!"
        read -p "Continue anyway? [y/N] " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
fi
echo ""

# ─── STEP 3: Install Base Dependencies ──────────────────────────────────────
log "Installing base dependencies..."
apt-get install -y -qq build-essential cmake git libuv1-dev libssl-dev libhwloc-dev \
    wget curl gnupg2 ca-certificates \
    ocl-icd-opencl-dev ocl-icd-libopencl1 clinfo \
    > /dev/null 2>&1
log "Base dependencies installed"

# ─── STEP 4: Install AMD GPU Firmware ────────────────────────────────────────
log "Checking GPU firmware..."

# Debian 12 has firmware-amd-graphics in non-free
if ! dpkg -l | grep -q firmware-amd-graphics 2>/dev/null; then
    info "Adding non-free repos for firmware..."
    
    # Ensure non-free and non-free-firmware are in sources
    if ! grep -q "non-free-firmware" /etc/apt/sources.list 2>/dev/null; then
        # Add non-free-firmware to existing bookworm lines
        sed -i 's/bookworm main.*/bookworm main contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true
        
        # Also check sources.list.d
        for f in /etc/apt/sources.list.d/*.list; do
            [ -f "$f" ] && sed -i 's/bookworm main.*/bookworm main contrib non-free non-free-firmware/' "$f" 2>/dev/null || true
        done
        
        # Handle .sources format (deb822)
        for f in /etc/apt/sources.list.d/*.sources; do
            if [ -f "$f" ] && ! grep -q "non-free-firmware" "$f"; then
                sed -i '/^Components:/ s/$/ contrib non-free non-free-firmware/' "$f" 2>/dev/null || true
            fi
        done
        
        apt-get update -qq
    fi
    
    apt-get install -y -qq firmware-amd-graphics > /dev/null 2>&1 && \
        log "firmware-amd-graphics installed ✓" || \
        warn "firmware-amd-graphics install failed — will try manual download"
fi

# Verify the critical firmware file exists
FIRMWARE_DIR="/lib/firmware/amdgpu"
if [ ! -f "$FIRMWARE_DIR/vega10_gpu_info.bin" ]; then
    warn "vega10_gpu_info.bin missing — downloading from kernel.org..."
    mkdir -p "$FIRMWARE_DIR"
    
    BASE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amdgpu"
    
    for fw in vega10_gpu_info.bin vega10_smc.bin vega10_sos.bin vega10_asd.bin \
              vega10_ce.bin vega10_me.bin vega10_mec.bin vega10_mec2.bin \
              vega10_pfp.bin vega10_rlc.bin vega10_sdma.bin vega10_sdma1.bin \
              vega10_uvd.bin vega10_vce.bin vega10_acg_smc.bin; do
        if [ ! -f "$FIRMWARE_DIR/$fw" ]; then
            wget -q --timeout=10 -O "$FIRMWARE_DIR/$fw" "$BASE_URL/$fw" 2>/dev/null || true
            # Remove if it downloaded an HTML error page
            if [ -f "$FIRMWARE_DIR/$fw" ] && file "$FIRMWARE_DIR/$fw" | grep -qi "html\|text"; then
                rm -f "$FIRMWARE_DIR/$fw"
            fi
        fi
    done
    
    update-initramfs -u -k all > /dev/null 2>&1 || true
    NEEDS_REBOOT=true
    log "Firmware downloaded — reboot will be needed"
else
    log "Vega10 firmware present ✓"
fi

# ─── STEP 5: Install ROCm OpenCL (Debian 12 Official) ───────────────────────
log "Setting up ROCm OpenCL for Debian 12..."

# Check if ROCm is already installed
if clinfo 2>/dev/null | grep -qi "gfx900\|vega"; then
    log "ROCm OpenCL already working — GPU visible ✓"
else
    info "Installing ROCm OpenCL runtime..."
    
    # Add AMD GPG key
    mkdir -p /etc/apt/keyrings
    wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | \
        gpg --dearmor -o /etc/apt/keyrings/rocm.gpg 2>/dev/null || true
    
    # Add amdgpu driver repo (for Debian 12 / Bookworm)
    cat > /etc/apt/sources.list.d/amdgpu.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${ROCM_VERSION}/ubuntu/jammy/ jammy main
EOF
    
    # Add ROCm repo
    cat > /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION}/ jammy main
EOF
    
    # Pin priority — don't let ROCm override system packages
    cat > /etc/apt/preferences.d/rocm-pin-600 << EOF
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF
    
    apt-get update -qq 2>/dev/null || true
    
    # Install ONLY the OpenCL runtime — minimal footprint
    # Do NOT install amdgpu-dkms — Debian 12's kernel already has amdgpu
    apt-get install -y -qq rocm-opencl-runtime --no-install-recommends 2>/dev/null || {
        warn "ROCm package install failed — trying alternative..."
        # Fallback: try mesa OpenCL
        apt-get install -y -qq mesa-opencl-icd 2>/dev/null || true
    }
    
    log "OpenCL runtime installed"
fi

# ─── STEP 6: Load GPU Driver ────────────────────────────────────────────────
log "Loading amdgpu driver..."

# Ensure amdgpu loads on boot
echo "amdgpu" | tee /etc/modules-load.d/amdgpu.conf > /dev/null

# Load the driver
if ! lsmod | grep -q amdgpu; then
    modprobe amdgpu 2>/dev/null || true
    sleep 2
fi

# GPU groups
usermod -aG video,render root 2>/dev/null || true
REAL_USER="${SUDO_USER:-root}"
[ "$REAL_USER" != "root" ] && usermod -aG video,render "$REAL_USER" 2>/dev/null || true

# Check GPU status
if [ -e /dev/dri/renderD128 ]; then
    log "/dev/dri/renderD128 exists — GPU compute ready ✓"
elif [ -e /dev/kfd ]; then
    warn "/dev/kfd exists but no renderD128 — may need reboot for firmware"
    NEEDS_REBOOT=true
else
    warn "No GPU compute devices — reboot needed after firmware install"
    NEEDS_REBOOT=true
fi

# ─── STEP 7: Huge Pages ─────────────────────────────────────────────────────
log "Configuring huge pages..."
NUM_CORES=$(nproc)
# Reserve some headroom for GPU driver
HUGEPAGES=$((1040 + NUM_CORES + 128))
TOTAL_RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
MAX_HP=$(( (TOTAL_RAM_MB * 70 / 100) / 2 ))  # 70% — leave room for GPU
[ "$HUGEPAGES" -gt "$MAX_HP" ] && HUGEPAGES=$MAX_HP

sysctl -w vm.nr_hugepages=$HUGEPAGES > /dev/null
if grep -q "vm.nr_hugepages" /etc/sysctl.conf; then
    sed -i "s/vm.nr_hugepages=.*/vm.nr_hugepages=$HUGEPAGES/" /etc/sysctl.conf
else
    echo "vm.nr_hugepages=$HUGEPAGES" >> /etc/sysctl.conf
fi

GB_PAGES=false
if grep -q pdpe1gb /proc/cpuinfo; then
    GB_PAGES=true
    if ! grep -q "hugepagesz=1G" /etc/default/grub 2>/dev/null; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 hugepagesz=1G hugepages=3"/' /etc/default/grub 2>/dev/null || true
        update-grub 2>/dev/null || true
    fi
fi

ACTUAL_HP=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
log "Huge pages: $ACTUAL_HP active"

# ─── STEP 8: MSR Module ─────────────────────────────────────────────────────
modprobe msr 2>/dev/null || true
grep -q "^msr$" /etc/modules 2>/dev/null || echo "msr" >> /etc/modules

# ─── STEP 9: Build XMRig WITH OpenCL ────────────────────────────────────────
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

NEED_REBUILD=false
if [ ! -f "$INSTALL_DIR/xmrig/build/xmrig" ]; then
    NEED_REBUILD=true
elif ! "$INSTALL_DIR/xmrig/build/xmrig" --version 2>&1 | grep -qi "opencl"; then
    warn "Existing xmrig was built without OpenCL — rebuilding..."
    NEED_REBUILD=true
fi

if [ "$NEED_REBUILD" = true ]; then
    log "Building XMRig v${XMRIG_VERSION} WITH OpenCL..."
    rm -rf xmrig
    git clone --depth 1 --branch v${XMRIG_VERSION} https://github.com/xmrig/xmrig.git > /dev/null 2>&1
    cd xmrig
    # Remove donation
    sed -i 's/constexpr const int kDefaultDonateLevel = 1;/constexpr const int kDefaultDonateLevel = 0;/' src/donate.h
    sed -i 's/constexpr const int kMinimumDonateLevel = 1;/constexpr const int kMinimumDonateLevel = 0;/' src/donate.h
    mkdir -p build && cd build
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_HWLOC=ON \
        -DWITH_OPENCL=ON \
        -DWITH_CUDA=OFF \
        > /dev/null 2>&1
    make -j$(nproc) > /dev/null 2>&1
    [ -f xmrig ] && log "XMRig built with OpenCL ✓" || { err "XMRig build failed!"; exit 1; }
    cd "$INSTALL_DIR"
else
    log "XMRig already built with OpenCL ✓"
fi

# ─── STEP 10: Download P2Pool ───────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/p2pool/p2pool" ]; then
    log "Downloading P2Pool v${P2POOL_VERSION}..."
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && P2POOL_ARCH="linux-x64" || P2POOL_ARCH="linux-aarch64"
    mkdir -p p2pool && cd p2pool
    wget -q "https://github.com/SChernykh/p2pool/releases/download/v${P2POOL_VERSION}/p2pool-v${P2POOL_VERSION}-${P2POOL_ARCH}.tar.gz" -O p2pool.tar.gz
    tar xzf p2pool.tar.gz --strip-components=1
    rm -f p2pool.tar.gz
    chmod +x p2pool
    cd "$INSTALL_DIR"
    [ -f "$INSTALL_DIR/p2pool/p2pool" ] && log "P2Pool downloaded ✓" || { err "P2Pool download failed!"; exit 1; }
else
    log "P2Pool already installed ✓"
fi

# ─── STEP 11: XMRig Config (CPU + GPU) ──────────────────────────────────────
log "Generating xmrig.json (CPU + GPU)..."

THREADS=$(nproc)
L3_KB=$(lscpu | grep 'L3 cache' | awk '{print $3}' | sed 's/[^0-9]//g')
L3_UNIT=$(lscpu | grep 'L3 cache' | awk '{print $4}')
echo "$L3_UNIT" | grep -qi "MiB\|MB" && L3_KB=$((L3_KB * 1024))

# Reserve 1 thread for GPU driver overhead
OPTIMAL_THREADS=$(( (L3_KB / 1024 / 2) - 1 ))
[ "$OPTIMAL_THREADS" -gt "$((THREADS - 1))" ] && OPTIMAL_THREADS=$((THREADS - 1))
[ "$OPTIMAL_THREADS" -lt 1 ] && OPTIMAL_THREADS=1

RX_ARRAY=""
for ((i=0; i<OPTIMAL_THREADS; i++)); do
    [ $i -gt 0 ] && RX_ARRAY="$RX_ARRAY, "
    RX_ARRAY="$RX_ARRAY$i"
done

log "CPU threads for mining: $OPTIMAL_THREADS (1 reserved for GPU driver)"

cat > "$INSTALL_DIR/xmrig.json" << XMRIG_EOF
{
    "api": { "id": null, "worker-id": "${HOSTNAME}" },
    "http": {
        "enabled": true,
        "host": "127.0.0.1",
        "port": 37841,
        "access-token": null,
        "restricted": true
    },
    "autosave": true,
    "background": false,
    "colors": true,
    "title": true,
    "randomx": {
        "init": -1,
        "init-avx2": -1,
        "mode": "fast",
        "1gb-pages": ${GB_PAGES},
        "rdmsr": true,
        "wrmsr": true,
        "cache_qos": true,
        "numa": true,
        "scratchpad_prefetch_mode": 1
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "hw-aes": null,
        "priority": 4,
        "memory-pool": true,
        "yield": false,
        "max-threads-hint": 87,
        "asm": true,
        "argon2-impl": null,
        "rx": [${RX_ARRAY}]
    },
    "opencl": {
        "enabled": true,
        "cache": true,
        "loader": null,
        "platform": 0,
        "adl": true
    },
    "cuda": { "enabled": false },
    "log-file": "/tmp/xmrig.log",
    "donate-level": 0,
    "donate-over-proxy": 0,
    "pools": [
        {
            "algo": "rx/0",
            "coin": "XMR",
            "url": "127.0.0.1:${P2POOL_STRATUM_PORT}",
            "user": "${WALLET_ADDRESS}",
            "pass": "",
            "rig-id": "${HOSTNAME}",
            "nicehash": false,
            "keepalive": true,
            "enabled": true,
            "tls": false,
            "daemon": false
        }
    ],
    "retries": 5,
    "retry-pause": 3,
    "print-time": 30,
    "health-print-time": 60,
    "dmi": true,
    "syslog": false,
    "verbose": 1,
    "watch": true,
    "pause-on-battery": false,
    "pause-on-active": false
}
XMRIG_EOF

log "xmrig.json written ✓"
info "  xmrig (CPU+GPU) → 127.0.0.1:${P2POOL_STRATUM_PORT} (LOCAL p2pool)"

# ─── STEP 12: Systemd Services ──────────────────────────────────────────────
log "Creating systemd services..."

# P2Pool — connects to REMOTE monerod on main node
cat > /etc/systemd/system/p2pool.service << P2POOL_SVC
[Unit]
Description=P2Pool (connects to monerod at ${MAIN_NODE_IP})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/p2pool/p2pool \\
    --host ${MAIN_NODE_IP} \\
    --rpc-port ${MONEROD_RPC_PORT} \\
    --zmq-port ${MONEROD_ZMQ_PORT} \\
    --wallet ${WALLET_ADDRESS} \\
    --stratum 0.0.0.0:${P2POOL_STRATUM_PORT} \\
    --p2p 0.0.0.0:${P2POOL_P2P_PORT} \\
    --loglevel 2 \\
    ${USE_MINI}
WorkingDirectory=${INSTALL_DIR}/p2pool
Restart=always
RestartSec=10
Nice=-10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
P2POOL_SVC

# XMRig — connects to LOCAL p2pool, with GPU access
cat > /etc/systemd/system/xmrig.service << 'XMRIG_SVC'
[Unit]
Description=XMRig Miner (CPU+GPU → local P2Pool)
After=p2pool.service
Wants=p2pool.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/opt/mining/xmrig/build/xmrig --config /opt/mining/xmrig.json
WorkingDirectory=/opt/mining
Restart=always
RestartSec=10
Nice=-10
LimitNOFILE=65535
LimitMEMLOCK=infinity
SupplementaryGroups=video render
DeviceAllow=/dev/dri/* rw
DeviceAllow=/dev/kfd rw

[Install]
WantedBy=multi-user.target
XMRIG_SVC

systemctl daemon-reload
log "Services created ✓"

# ─── STEP 13: Firewall ──────────────────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow ${P2POOL_P2P_PORT}/tcp comment "P2Pool p2p sidechain" > /dev/null 2>&1
    log "UFW: port ${P2POOL_P2P_PORT} opened"
fi

# ─── STEP 14: GPU Status Check ──────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  GPU STATUS CHECK"
echo "═══════════════════════════════════════════════════════════════"

if [ -e /dev/dri/renderD128 ]; then
    log "/dev/dri/renderD128 exists — GPU compute available"
    
    OPENCL_DEVICES=$(clinfo 2>/dev/null | grep -c "Device Name" || echo "0")
    if [ "$OPENCL_DEVICES" -gt 0 ]; then
        log "OpenCL sees $OPENCL_DEVICES device(s) — GPU mining READY ✓"
        clinfo 2>/dev/null | grep "Device Name" | sed 's/^/  /'
    else
        warn "OpenCL sees 0 devices"
        info "This usually resolves after a reboot once ROCm is installed"
        NEEDS_REBOOT=true
    fi
else
    warn "/dev/dri/renderD128 does NOT exist"
    NEEDS_REBOOT=true
fi

if [ -e /dev/kfd ]; then
    log "/dev/kfd exists — ROCm kernel interface available ✓"
else
    warn "/dev/kfd missing — ROCm kernel driver not active"
    NEEDS_REBOOT=true
fi

# ─── DONE ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "${GREEN}  ✅ GPU SATELLITE MINER SETUP COMPLETE (Debian 12)${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  DATA FLOW:                                             │"
echo "  │                                                         │"
echo "  │  xmrig CPU+GPU (this VM)                                │"
echo "  │    ↓ hashes to 127.0.0.1:${P2POOL_STRATUM_PORT}                       │"
echo "  │  p2pool (this VM)                                       │"
echo "  │    ↓ block templates from ${MAIN_NODE_IP}:${MONEROD_RPC_PORT}       │"
echo "  │    ↓ notifications from  ${MAIN_NODE_IP}:${MONEROD_ZMQ_PORT}       │"
echo "  │  monerod (main node)                                    │"
echo "  │    ↓ submits blocks to Monero network                   │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

if [ "$NEEDS_REBOOT" = true ]; then
    echo -e "  ${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}║  ⚠  REBOOT REQUIRED                                 ║${NC}"
    echo -e "  ${YELLOW}║                                                       ║${NC}"
    echo -e "  ${YELLOW}║  GPU firmware and/or ROCm need a reboot to activate. ║${NC}"
    echo -e "  ${YELLOW}║                                                       ║${NC}"
    echo -e "  ${YELLOW}║  Run:  sudo reboot                                   ║${NC}"
    echo -e "  ${YELLOW}║  Then: sudo systemctl start p2pool xmrig             ║${NC}"
    echo -e "  ${YELLOW}║        sudo systemctl enable p2pool xmrig            ║${NC}"
    echo -e "  ${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
else
    echo "  QUICK START:"
    echo "    sudo systemctl start p2pool xmrig"
    echo "    sudo systemctl enable p2pool xmrig"
fi

echo ""
echo "  COMMANDS:"
echo "    sudo systemctl status p2pool xmrig   # Check status"
echo "    journalctl -u p2pool -f              # P2Pool logs"
echo "    journalctl -u xmrig -f               # XMRig logs"
echo "    clinfo | grep 'Device Name'          # Verify GPU visible"
echo "    tail -f /tmp/xmrig.log               # XMRig log file"
echo ""
echo "  VERIFY GPU MINING:"
echo "    # After starting, look for 'OpenCL' lines in xmrig output"
echo "    # You should see both CPU and GPU hashrates"
echo "    journalctl -u xmrig --no-pager -n 30 | grep -iE 'opencl|gpu|hashrate'"
echo ""
