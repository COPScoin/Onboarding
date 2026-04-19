#!/bin/bash
###############################################################################
# XMRig + P2Pool Remote Miner Setup — GPU EDITION (AMD Vega / MI25)
# 
# This sets up a Debian-based VM with AMD GPU to mine Monero via:
#   - P2Pool (running locally, connecting to remote monerod)
#   - XMRig (CPU + OpenCL GPU mining to local P2Pool)
#
# Remote Monero Node: 20.62.43.171:18081
# GPU: AMD Vega 10 (Instinct MI25 / V340 MxGPU)
#
# Usage: sudo bash setup-miner-gpu.sh
###############################################################################

set -euo pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
MONERO_NODE_IP="20.62.43.171"
MONERO_NODE_PORT="18081"
MONERO_ZMQ_PORT="18083"
WALLET_ADDRESS="42ykwPdhRp9YNaXVJ3jrXnKzF84CneMdoPTTC4SFzqUVHkXmUocKG9FYo8wWymMgApCiyKkYfCb9USPvV9Er67ce86xu7Ho"
P2POOL_STRATUM_PORT="3333"
XMRIG_VERSION="6.22.2"
P2POOL_VERSION="4.5"
INSTALL_DIR="/opt/mining"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    err "Run as root: sudo bash setup-miner-gpu.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(whoami)}"

# ─── STEP 1: System Info ────────────────────────────────────────────────────
log "Gathering system info..."
echo "═══════════════════════════════════════════════════"
echo "  Hostname:  $(hostname)"
echo "  OS:        $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "  Kernel:    $(uname -r)"
echo "  Arch:      $(uname -m)"
echo "  CPU:       $(lscpu | grep 'Model name' | sed 's/Model name:\s*//')"
echo "  Cores:     $(nproc)"
echo "  Threads:   $(lscpu | grep '^CPU(s):' | awk '{print $2}')"
echo "  RAM:       $(free -h | awk '/Mem:/{print $2}')"
echo "  L3 Cache:  $(lscpu | grep 'L3 cache' | awk '{print $3, $4}')"
echo "═══════════════════════════════════════════════════"

# ─── STEP 2: Detect GPU ─────────────────────────────────────────────────────
log "Detecting AMD GPU..."
GPU_INFO=$(lspci | grep -i "VGA\|Display\|3D" | grep -i "AMD\|ATI" || true)
if [ -z "$GPU_INFO" ]; then
    err "No AMD GPU detected! Use setup-miner.sh (CPU-only) instead."
    exit 1
fi
echo "  GPU: $GPU_INFO"

# Check for Vega specifically
if echo "$GPU_INFO" | grep -qi "vega\|MI25\|V340"; then
    log "Vega/MI25 GPU confirmed — excellent for RandomX!"
    GPU_TYPE="vega"
else
    warn "Non-Vega AMD GPU detected — OpenCL mining may still work"
    GPU_TYPE="other"
fi

# ─── STEP 3: Install Dependencies ───────────────────────────────────────────
log "Installing dependencies (including OpenCL)..."
apt-get update -qq

# Core build deps
apt-get install -y -qq build-essential cmake git libuv1-dev libssl-dev libhwloc-dev wget curl > /dev/null 2>&1

# AMD OpenCL / ROCm dependencies
# Try to install the AMD OpenCL ICD (needed for xmrig OpenCL backend)
log "Installing AMD OpenCL runtime..."

# Method 1: Try mesa OpenCL (works on most Debian systems)
apt-get install -y -qq mesa-opencl-icd ocl-icd-opencl-dev ocl-icd-libopencl1 clinfo 2>/dev/null || true

# Method 2: Check if ROCm is available
if [ -f /etc/apt/sources.list.d/rocm.list ] || [ -d /opt/rocm ]; then
    log "ROCm repository detected"
    apt-get install -y -qq rocm-opencl-runtime 2>/dev/null || true
else
    # Method 3: Try to add ROCm repo for proper AMD OpenCL
    info "Attempting to add ROCm repository for AMD OpenCL..."
    
    # Check Debian version
    DEBIAN_VER=$(cat /etc/debian_version 2>/dev/null | cut -d. -f1)
    
    if [ -n "$DEBIAN_VER" ] && [ "$DEBIAN_VER" -ge 11 ]; then
        # Add AMD ROCm repo
        wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg 2>/dev/null || true
        
        if [ "$DEBIAN_VER" -ge 12 ]; then
            ROCM_CODENAME="jammy"  # ROCm uses Ubuntu codenames, jammy works for Debian 12
        else
            ROCM_CODENAME="focal"
        fi
        
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/latest ${ROCM_CODENAME} main" > /etc/apt/sources.list.d/rocm.list 2>/dev/null || true
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq rocm-opencl-runtime 2>/dev/null || true
    fi
fi

# Verify OpenCL is available
if command -v clinfo &> /dev/null; then
    OPENCL_DEVICES=$(clinfo --list 2>/dev/null | grep -c "Device" || echo "0")
    if [ "$OPENCL_DEVICES" -gt 0 ]; then
        log "OpenCL devices found: $OPENCL_DEVICES"
        clinfo --list 2>/dev/null || true
    else
        warn "OpenCL installed but no devices found — GPU mining may not work"
        warn "You may need to install ROCm manually: https://rocm.docs.amd.com/"
    fi
else
    warn "clinfo not available — can't verify OpenCL"
fi

# ─── STEP 4: Configure Huge Pages ───────────────────────────────────────────
log "Configuring huge pages..."

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
NUM_CORES=$(nproc)

# RandomX dataset = 2080MB = 1040 huge pages
# Each CPU thread needs ~2MB scratchpad = 1 huge page per thread
# GPU also uses the dataset from RAM
HUGEPAGES=$((1040 + NUM_CORES + 128))

# Don't use more than 70% of RAM (leave room for GPU driver overhead)
MAX_HUGEPAGES=$(( (TOTAL_RAM_MB * 70 / 100) / 2 ))
if [ "$HUGEPAGES" -gt "$MAX_HUGEPAGES" ]; then
    HUGEPAGES=$MAX_HUGEPAGES
fi

log "Setting $HUGEPAGES huge pages ($(( HUGEPAGES * 2 ))MB)..."

sysctl -w vm.nr_hugepages=$HUGEPAGES > /dev/null

if grep -q "vm.nr_hugepages" /etc/sysctl.conf; then
    sed -i "s/vm.nr_hugepages=.*/vm.nr_hugepages=$HUGEPAGES/" /etc/sysctl.conf
else
    echo "vm.nr_hugepages=$HUGEPAGES" >> /etc/sysctl.conf
fi

# 1GB pages check
GB_PAGES=false
if grep -q pdpe1gb /proc/cpuinfo; then
    log "CPU supports 1GB pages — enabling..."
    if ! grep -q "hugepagesz=1G" /etc/default/grub 2>/dev/null; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 hugepagesz=1G hugepages=3"/' /etc/default/grub 2>/dev/null || true
        update-grub 2>/dev/null || true
        warn "1GB pages require reboot to activate"
    fi
    GB_PAGES=true
fi

ACTUAL_HP=$(cat /proc/meminfo | grep HugePages_Total | awk '{print $2}')
log "Huge pages active: $ACTUAL_HP (requested: $HUGEPAGES)"

# ─── STEP 5: MSR Module ─────────────────────────────────────────────────────
log "Configuring MSR module..."
modprobe msr 2>/dev/null || true
if ! grep -q "^msr$" /etc/modules 2>/dev/null; then
    echo "msr" >> /etc/modules
fi

# ─── STEP 6: GPU Power Management ───────────────────────────────────────────
log "Configuring GPU power management..."

# For MI25/Vega, set performance mode if sysfs is available
GPU_SYSFS=$(find /sys/class/drm/card*/device -name "power_dpm_force_performance_level" 2>/dev/null | head -1)
if [ -n "$GPU_SYSFS" ]; then
    echo "high" > "$GPU_SYSFS" 2>/dev/null || true
    log "GPU performance level set to HIGH"
    
    # Show GPU info
    GPU_DIR=$(dirname "$GPU_SYSFS")
    if [ -f "$GPU_DIR/mem_info_vram_total" ]; then
        VRAM_BYTES=$(cat "$GPU_DIR/mem_info_vram_total" 2>/dev/null || echo "0")
        VRAM_MB=$((VRAM_BYTES / 1024 / 1024))
        log "GPU VRAM: ${VRAM_MB}MB"
    fi
    if [ -f "$GPU_DIR/pp_dpm_sclk" ]; then
        log "GPU clock states:"
        cat "$GPU_DIR/pp_dpm_sclk" 2>/dev/null | sed 's/^/    /'
    fi
    if [ -f "$GPU_DIR/pp_dpm_mclk" ]; then
        log "GPU memory states:"
        cat "$GPU_DIR/pp_dpm_mclk" 2>/dev/null | sed 's/^/    /'
    fi
else
    warn "GPU sysfs not found — power management not configured"
fi

# ─── STEP 7: Create install directory ───────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ─── STEP 8: Download & Build XMRig (with OpenCL support) ───────────────────
if [ ! -f "$INSTALL_DIR/xmrig/build/xmrig" ]; then
    log "Downloading XMRig v${XMRIG_VERSION}..."
    if [ -d xmrig ]; then rm -rf xmrig; fi
    git clone --depth 1 --branch v${XMRIG_VERSION} https://github.com/xmrig/xmrig.git > /dev/null 2>&1

    log "Building XMRig WITH OpenCL support (this takes a few minutes)..."
    cd xmrig
    
    # Remove donate
    sed -i 's/constexpr const int kDefaultDonateLevel = 1;/constexpr const int kDefaultDonateLevel = 0;/' src/donate.h
    sed -i 's/constexpr const int kMinimumDonateLevel = 1;/constexpr const int kMinimumDonateLevel = 0;/' src/donate.h
    
    mkdir -p build && cd build
    # CRITICAL: -DWITH_OPENCL=ON enables GPU mining
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_HWLOC=ON \
        -DWITH_OPENCL=ON \
        -DWITH_CUDA=OFF \
        > /dev/null 2>&1
    make -j$(nproc) > /dev/null 2>&1
    
    if [ -f xmrig ]; then
        log "XMRig built successfully with OpenCL!"
    else
        err "XMRig build failed!"
        exit 1
    fi
    cd "$INSTALL_DIR"
else
    log "XMRig already built, skipping..."
    warn "If you need OpenCL support, delete /opt/mining/xmrig and re-run"
fi

# ─── STEP 9: Download P2Pool ────────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/p2pool/p2pool" ]; then
    log "Downloading P2Pool v${P2POOL_VERSION}..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        P2POOL_ARCH="linux-x64"
    elif [ "$ARCH" = "aarch64" ]; then
        P2POOL_ARCH="linux-aarch64"
    else
        err "Unsupported architecture: $ARCH"
        exit 1
    fi
    
    mkdir -p p2pool && cd p2pool
    wget -q "https://github.com/SChernykh/p2pool/releases/download/v${P2POOL_VERSION}/p2pool-v${P2POOL_VERSION}-${P2POOL_ARCH}.tar.gz" -O p2pool.tar.gz
    tar xzf p2pool.tar.gz --strip-components=1
    rm -f p2pool.tar.gz
    chmod +x p2pool
    cd "$INSTALL_DIR"
    
    if [ -f "$INSTALL_DIR/p2pool/p2pool" ]; then
        log "P2Pool downloaded successfully!"
    else
        err "P2Pool download failed!"
        exit 1
    fi
else
    log "P2Pool already installed, skipping..."
fi

# ─── STEP 10: Generate GPU-optimized XMRig config ───────────────────────────
log "Generating GPU-optimized xmrig.json..."

THREADS=$(nproc)
L3_CACHE_KB=$(lscpu | grep 'L3 cache' | awk '{print $3}' | sed 's/[^0-9]//g')
L3_UNIT=$(lscpu | grep 'L3 cache' | awk '{print $4}')
if echo "$L3_UNIT" | grep -qi "MiB\|MB"; then
    L3_CACHE_KB=$((L3_CACHE_KB * 1024))
fi

if [ -n "$L3_CACHE_KB" ] && [ "$L3_CACHE_KB" -gt 0 ]; then
    OPTIMAL_CPU_THREADS=$((L3_CACHE_KB / 1024 / 2))
else
    OPTIMAL_CPU_THREADS=$THREADS
fi

# With GPU mining, we can use all CPU threads since GPU handles its own work
# But leave 1 thread free for GPU driver overhead
GPU_RESERVED_THREADS=1
OPTIMAL_CPU_THREADS=$((OPTIMAL_CPU_THREADS > GPU_RESERVED_THREADS ? OPTIMAL_CPU_THREADS - GPU_RESERVED_THREADS : OPTIMAL_CPU_THREADS))

if [ "$OPTIMAL_CPU_THREADS" -gt "$THREADS" ]; then
    OPTIMAL_CPU_THREADS=$THREADS
fi
if [ "$OPTIMAL_CPU_THREADS" -lt 1 ]; then
    OPTIMAL_CPU_THREADS=1
fi

log "CPU mining threads: $OPTIMAL_CPU_THREADS (reserving $GPU_RESERVED_THREADS for GPU driver)"

# Build rx thread array
RX_ARRAY=""
for ((i=0; i<OPTIMAL_CPU_THREADS; i++)); do
    if [ $i -gt 0 ]; then RX_ARRAY="$RX_ARRAY, "; fi
    RX_ARRAY="$RX_ARRAY$i"
done

HOSTNAME=$(hostname)

cat > "$INSTALL_DIR/xmrig.json" << XMRIG_EOF
{
    "api": {
        "id": null,
        "worker-id": "${HOSTNAME}"
    },
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
        "adl": true,
        "cn-gpu/0": false,
        "cn/0": false
    },
    "cuda": {
        "enabled": false
    },
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
            "sni": false,
            "tls-fingerprint": null,
            "daemon": false,
            "self-select": null,
            "submit-to-origin": false
        }
    ],
    "retries": 5,
    "retry-pause": 3,
    "print-time": 30,
    "health-print-time": 60,
    "dmi": true,
    "syslog": false,
    "tls": {
        "enabled": false
    },
    "dns": {
        "ipv6": false,
        "ttl": 30
    },
    "user-agent": null,
    "verbose": 1,
    "watch": true,
    "pause-on-battery": false,
    "pause-on-active": false
}
XMRIG_EOF

log "Config written to $INSTALL_DIR/xmrig.json"

# ─── STEP 11: Create systemd services ───────────────────────────────────────
log "Creating systemd services..."

# P2Pool service (same as CPU-only)
cat > /etc/systemd/system/p2pool.service << 'P2POOL_SVC'
[Unit]
Description=P2Pool Monero Mining (Remote Node)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/mining/p2pool/p2pool \
    --host 20.62.43.171 \
    --rpc-port 18081 \
    --zmq-port 18083 \
    --wallet 42ykwPdhRp9YNaXVJ3jrXnKzF84CneMdoPTTC4SFzqUVHkXmUocKG9FYo8wWymMgApCiyKkYfCb9USPvV9Er67ce86xu7Ho \
    --stratum 0.0.0.0:3333 \
    --p2p 0.0.0.0:37889 \
    --loglevel 2 \
    --mini
WorkingDirectory=/opt/mining/p2pool
Restart=always
RestartSec=10
Nice=-10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
P2POOL_SVC

# XMRig service — with GPU access
cat > /etc/systemd/system/xmrig.service << 'XMRIG_SVC'
[Unit]
Description=XMRig Monero Miner (CPU + GPU)
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
# GPU access — needed for OpenCL
SupplementaryGroups=video render
# Ensure /dev/dri and /dev/kfd are accessible
DeviceAllow=/dev/dri/* rw
DeviceAllow=/dev/kfd rw

[Install]
WantedBy=multi-user.target
XMRIG_SVC

systemctl daemon-reload

# ─── STEP 12: GPU permissions ────────────────────────────────────────────────
log "Setting GPU permissions..."

# Add user to video and render groups (needed for OpenCL)
usermod -aG video root 2>/dev/null || true
usermod -aG render root 2>/dev/null || true
if [ "$REAL_USER" != "root" ]; then
    usermod -aG video "$REAL_USER" 2>/dev/null || true
    usermod -aG render "$REAL_USER" 2>/dev/null || true
fi

# Ensure /dev/kfd exists and is accessible (AMD GPU compute)
if [ -e /dev/kfd ]; then
    chmod 666 /dev/kfd 2>/dev/null || true
    log "/dev/kfd accessible"
else
    warn "/dev/kfd not found — ROCm may not be installed"
fi

# Ensure /dev/dri/renderD128 exists
if [ -e /dev/dri/renderD128 ]; then
    chmod 666 /dev/dri/renderD128 2>/dev/null || true
    log "/dev/dri/renderD128 accessible"
else
    warn "/dev/dri/renderD128 not found — GPU may not be properly initialized"
fi

# ─── STEP 13: Firewall ──────────────────────────────────────────────────────
if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
    log "Configuring firewall..."
    ufw allow 37889/tcp comment "P2Pool p2p" > /dev/null 2>&1
fi

# ─── STEP 14: Print summary ─────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "${GREEN}  ✅ GPU MINER SETUP COMPLETE${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Monero Node:     ${MONERO_NODE_IP}:${MONERO_NODE_PORT} (remote)"
echo "  P2Pool:          localhost:${P2POOL_STRATUM_PORT} (mini sidechain)"
echo "  CPU Mining:      $OPTIMAL_CPU_THREADS threads"
echo "  GPU Mining:      OpenCL ENABLED (AMD Vega/MI25)"
echo "  Wallet:          ${WALLET_ADDRESS:0:12}...${WALLET_ADDRESS: -8}"
echo "  Huge Pages:      $ACTUAL_HP × 2MB = $((ACTUAL_HP * 2))MB"
echo "  Install Dir:     $INSTALL_DIR"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  COMMANDS:                                              │"
echo "  │                                                         │"
echo "  │  Start:    sudo systemctl start p2pool xmrig            │"
echo "  │  Stop:     sudo systemctl stop xmrig p2pool             │"
echo "  │  Status:   sudo systemctl status p2pool xmrig           │"
echo "  │  Logs:     journalctl -u xmrig -f                       │"
echo "  │  P2Pool:   journalctl -u p2pool -f                      │"
echo "  │  Enable:   sudo systemctl enable p2pool xmrig           │"
echo "  │  Hashrate: curl -s http://127.0.0.1:37841/2/summary     │"
echo "  │                                                         │"
echo "  │  GPU Info: cat /sys/class/drm/card*/device/gpu_busy_*   │"
echo "  │  GPU Temp: cat /sys/class/drm/card*/device/hwmon/*/temp1_input │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  EXPECTED HASHRATE (MI25 Vega):                         │"
echo "  │                                                         │"
echo "  │  CPU (8 threads):  ~4,000-6,000 H/s                    │"
echo "  │  GPU (Vega 56):    ~800-1,200 H/s                      │"
echo "  │  COMBINED:         ~5,000-7,000 H/s                    │"
echo "  │                                                         │"
echo "  │  Note: RandomX is CPU-heavy. GPU adds ~15-25% on top.  │"
echo "  │  The MI25 has 16GB HBM2 which helps with the dataset.  │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo -e "${YELLOW}  ⚠  IMPORTANT:${NC}"
echo "  - If GPU hashrate shows 0, you may need ROCm drivers"
echo "  - Install ROCm: https://rocm.docs.amd.com/projects/install-on-linux/"
echo "  - After ROCm install, restart xmrig: sudo systemctl restart xmrig"
echo "  - Check OpenCL: clinfo | head -20"
echo ""
echo "  First run will take ~30s to initialize RandomX dataset + compile OpenCL kernels"
echo ""
