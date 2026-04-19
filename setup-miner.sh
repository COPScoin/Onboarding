#!/bin/bash
###############################################################################
# XMRig + P2Pool Remote Miner Setup Script
# 
# This sets up a Debian-based VM to mine Monero via:
#   - P2Pool (running locally on this VM, connecting to remote monerod)
#   - XMRig (mining to local P2Pool)
#
# Remote Monero Node: 20.62.43.171:18081
#
# Usage: sudo bash setup-miner.sh
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
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    err "Run as root: sudo bash setup-miner.sh"
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
echo "  NUMA:      $(lscpu | grep 'NUMA node(s)' | awk '{print $3}')"
echo "═══════════════════════════════════════════════════"

# ─── STEP 2: Install Dependencies ───────────────────────────────────────────
log "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq build-essential cmake git libuv1-dev libssl-dev libhwloc-dev wget curl > /dev/null 2>&1

# ─── STEP 3: Configure Huge Pages ───────────────────────────────────────────
log "Configuring huge pages..."

# Calculate: RandomX needs 2080 MB for dataset + some overhead
# Each huge page = 2MB, so we need ~1168 pages for dataset + threads
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
NUM_CORES=$(nproc)

# RandomX dataset = 2080MB = 1040 huge pages
# Each thread needs ~2MB scratchpad = 1 huge page per thread
# Add buffer
HUGEPAGES=$((1040 + NUM_CORES + 128))

# Don't use more than 80% of RAM for huge pages
MAX_HUGEPAGES=$(( (TOTAL_RAM_MB * 80 / 100) / 2 ))
if [ "$HUGEPAGES" -gt "$MAX_HUGEPAGES" ]; then
    HUGEPAGES=$MAX_HUGEPAGES
fi

log "Setting $HUGEPAGES huge pages ($(( HUGEPAGES * 2 ))MB)..."

# Set now
sysctl -w vm.nr_hugepages=$HUGEPAGES > /dev/null

# Make persistent
if grep -q "vm.nr_hugepages" /etc/sysctl.conf; then
    sed -i "s/vm.nr_hugepages=.*/vm.nr_hugepages=$HUGEPAGES/" /etc/sysctl.conf
else
    echo "vm.nr_hugepages=$HUGEPAGES" >> /etc/sysctl.conf
fi

# 1GB pages (optional, for supported CPUs)
if grep -q pdpe1gb /proc/cpuinfo; then
    log "CPU supports 1GB pages — enabling..."
    if ! grep -q "hugepagesz=1G" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 hugepagesz=1G hugepages=3"/' /etc/default/grub
        update-grub 2>/dev/null || true
        warn "1GB pages require reboot to activate"
    fi
    GB_PAGES=true
else
    GB_PAGES=false
fi

# Verify
ACTUAL_HP=$(cat /proc/meminfo | grep HugePages_Total | awk '{print $2}')
log "Huge pages active: $ACTUAL_HP (requested: $HUGEPAGES)"

# ─── STEP 4: MSR Module (for RandomX boost) ─────────────────────────────────
log "Configuring MSR module..."
modprobe msr 2>/dev/null || true
if ! grep -q "^msr$" /etc/modules 2>/dev/null; then
    echo "msr" >> /etc/modules
fi

# ─── STEP 5: Create install directory ───────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ─── STEP 6: Download & Build XMRig ─────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/xmrig/build/xmrig" ]; then
    log "Downloading XMRig v${XMRIG_VERSION}..."
    if [ -d xmrig ]; then rm -rf xmrig; fi
    git clone --depth 1 --branch v${XMRIG_VERSION} https://github.com/xmrig/xmrig.git > /dev/null 2>&1

    log "Building XMRig (this takes a few minutes)..."
    cd xmrig
    
    # Remove donate (set to 0)
    sed -i 's/constexpr const int kDefaultDonateLevel = 1;/constexpr const int kDefaultDonateLevel = 0;/' src/donate.h
    sed -i 's/constexpr const int kMinimumDonateLevel = 1;/constexpr const int kMinimumDonateLevel = 0;/' src/donate.h
    
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON > /dev/null 2>&1
    make -j$(nproc) > /dev/null 2>&1
    
    if [ -f xmrig ]; then
        log "XMRig built successfully!"
    else
        err "XMRig build failed!"
        exit 1
    fi
    cd "$INSTALL_DIR"
else
    log "XMRig already built, skipping..."
fi

# ─── STEP 7: Download P2Pool ────────────────────────────────────────────────
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

# ─── STEP 8: Generate optimized XMRig config ────────────────────────────────
log "Generating optimized xmrig.json..."

# Detect thread config
THREADS=$(nproc)
L3_CACHE_KB=$(lscpu | grep 'L3 cache' | awk '{print $3}' | sed 's/[^0-9]//g')
# If L3 is in MiB, convert
L3_UNIT=$(lscpu | grep 'L3 cache' | awk '{print $4}')
if echo "$L3_UNIT" | grep -qi "MiB\|MB"; then
    L3_CACHE_KB=$((L3_CACHE_KB * 1024))
fi

# RandomX uses 2MB per thread — optimal threads = L3_cache_MB / 2
if [ -n "$L3_CACHE_KB" ] && [ "$L3_CACHE_KB" -gt 0 ]; then
    OPTIMAL_THREADS=$((L3_CACHE_KB / 1024 / 2))
else
    OPTIMAL_THREADS=$THREADS
fi

# Don't exceed physical threads
if [ "$OPTIMAL_THREADS" -gt "$THREADS" ]; then
    OPTIMAL_THREADS=$THREADS
fi
# At least 1
if [ "$OPTIMAL_THREADS" -lt 1 ]; then
    OPTIMAL_THREADS=1
fi

log "Optimal mining threads: $OPTIMAL_THREADS (of $THREADS available, based on L3 cache)"

# Build rx thread array
RX_ARRAY=""
for ((i=0; i<OPTIMAL_THREADS; i++)); do
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
        "priority": 5,
        "memory-pool": true,
        "yield": false,
        "max-threads-hint": 100,
        "asm": true,
        "argon2-impl": null,
        "rx": [${RX_ARRAY}]
    },
    "opencl": {
        "enabled": false
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
            "url": "20.62.43.171:${P2POOL_STRATUM_PORT}",
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

# ─── STEP 9: Create systemd services ────────────────────────────────────────
log "Creating systemd services..."

# P2Pool service
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

# XMRig service
cat > /etc/systemd/system/xmrig.service << 'XMRIG_SVC'
[Unit]
Description=XMRig Monero Miner
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

[Install]
WantedBy=multi-user.target
XMRIG_SVC

systemctl daemon-reload

# ─── STEP 10: Firewall (if ufw is active) ───────────────────────────────────
if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
    log "Configuring firewall..."
    ufw allow 37889/tcp comment "P2Pool p2p" > /dev/null 2>&1
    # Stratum only on localhost, no rule needed
fi

# ─── STEP 11: Print summary ─────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "${GREEN}  ✅ SETUP COMPLETE${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Monero Node:     ${MONERO_NODE_IP}:${MONERO_NODE_PORT} (remote)"
echo "  P2Pool:          localhost:${P2POOL_STRATUM_PORT} (mini sidechain)"
echo "  XMRig:           $OPTIMAL_THREADS threads → P2Pool → monerod"
echo "  Wallet:          ${WALLET_ADDRESS:0:12}...${WALLET_ADDRESS: -8}"
echo "  Huge Pages:      $ACTUAL_HP × 2MB = $((ACTUAL_HP * 2))MB"
echo "  1GB Pages:       $GB_PAGES"
echo "  Install Dir:     $INSTALL_DIR"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  COMMANDS:                                              │"
echo "  │                                                         │"
echo "  │  Start P2Pool:   sudo systemctl start p2pool            │"
echo "  │  Start XMRig:    sudo systemctl start xmrig             │"
echo "  │  Start Both:     sudo systemctl start p2pool xmrig      │"
echo "  │  Enable on Boot: sudo systemctl enable p2pool xmrig     │"
echo "  │  Check Status:   sudo systemctl status p2pool xmrig     │"
echo "  │  View Logs:      journalctl -u xmrig -f                 │"
echo "  │  P2Pool Logs:    journalctl -u p2pool -f                │"
echo "  │  XMRig Stats:    curl http://127.0.0.1:37841/2/summary  │"
echo "  │                                                         │"
echo "  │  Manual Start:                                          │"
echo "  │  P2Pool: cd /opt/mining/p2pool && ./p2pool \\            │"
echo "  │    --host 20.62.43.171 --rpc-port 18081 \\               │"
echo "  │    --zmq-port 18083 --mini \\                             │"
echo "  │    --wallet <YOUR_WALLET>                                │"
echo "  │  XMRig:  cd /opt/mining && ./xmrig/build/xmrig \\        │"
echo "  │    --config xmrig.json                                   │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── IMPORTANT REMINDER ─────────────────────────────────────────────────────
warn "IMPORTANT: Your Monero node at ${MONERO_NODE_IP} must have:"
echo "  1. RPC open on port ${MONERO_NODE_PORT} (--rpc-bind-ip=0.0.0.0 --confirm-external-bind)"
echo "  2. ZMQ open on port ${MONERO_ZMQ_PORT} (--zmq-pub=tcp://0.0.0.0:${MONERO_ZMQ_PORT})"
echo "  3. Restricted RPC is fine (--restricted-rpc)"
echo ""
warn "If monerod isn't configured for remote access, run on the node VM:"
echo "  monerod --rpc-bind-ip=0.0.0.0 --rpc-bind-port=18081 \\"
echo "    --confirm-external-bind --restricted-rpc \\"
echo "    --zmq-pub=tcp://0.0.0.0:18083 \\"
echo "    --data-dir=/path/to/blockchain --detach"
echo ""
