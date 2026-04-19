#!/bin/bash
###############################################################################
# SATELLITE MINER SETUP — CPU Only
#
# Architecture:
#   [This VM: xmrig] → [This VM: p2pool :3333] → [Main Node: monerod :18081/:18083]
#
# xmrig mines to LOCAL p2pool (127.0.0.1:3333)
# p2pool connects to REMOTE monerod (main node)
#
# Main Node IP: 20.62.43.171
# Wallet: 42ykwP...
#
# Usage: sudo bash setup-satellite.sh
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
# ═══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

[ "$EUID" -ne 0 ] && { err "Run as root: sudo bash setup-satellite.sh"; exit 1; }

HOSTNAME=$(hostname)

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  SATELLITE MINER SETUP — CPU Only"
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
echo "  L3 Cache: $(lscpu | grep 'L3 cache' | awk '{print $3, $4}')"
echo ""

# ─── STEP 2: Test connectivity to main node ─────────────────────────────────
info "Testing connectivity to main node ($MAIN_NODE_IP)..."

if ping -c 1 -W 3 "$MAIN_NODE_IP" > /dev/null 2>&1; then
    log "Main node is reachable (ping OK)"
else
    warn "Ping failed — may be blocked by firewall, continuing anyway..."
fi

# Test RPC port
if command -v nc &>/dev/null; then
    if nc -zw3 "$MAIN_NODE_IP" "$MONEROD_RPC_PORT" 2>/dev/null; then
        log "monerod RPC port $MONEROD_RPC_PORT is reachable ✓"
    else
        err "Cannot reach $MAIN_NODE_IP:$MONEROD_RPC_PORT — check firewall/NSG!"
        err "P2Pool will NOT work without this. Fix networking first."
        read -p "Continue anyway? [y/N] " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    if nc -zw3 "$MAIN_NODE_IP" "$MONEROD_ZMQ_PORT" 2>/dev/null; then
        log "monerod ZMQ port $MONEROD_ZMQ_PORT is reachable ✓"
    else
        err "Cannot reach $MAIN_NODE_IP:$MONEROD_ZMQ_PORT — check firewall/NSG!"
        err "P2Pool will NOT work without this. Fix networking first."
        read -p "Continue anyway? [y/N] " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
else
    warn "nc not installed, skipping connectivity test"
fi
echo ""

# ─── STEP 3: Install Dependencies ───────────────────────────────────────────
log "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq build-essential cmake git libuv1-dev libssl-dev libhwloc-dev wget curl netcat-openbsd > /dev/null 2>&1
log "Dependencies installed"

# ─── STEP 4: Huge Pages ─────────────────────────────────────────────────────
log "Configuring huge pages..."
NUM_CORES=$(nproc)
HUGEPAGES=$((1040 + NUM_CORES + 128))
TOTAL_RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
MAX_HP=$(( (TOTAL_RAM_MB * 80 / 100) / 2 ))
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
log "Huge pages: $ACTUAL_HP active (${HUGEPAGES} requested)"

# ─── STEP 5: MSR Module ─────────────────────────────────────────────────────
modprobe msr 2>/dev/null || true
grep -q "^msr$" /etc/modules 2>/dev/null || echo "msr" >> /etc/modules

# ─── STEP 6: Build XMRig ────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

if [ ! -f "$INSTALL_DIR/xmrig/build/xmrig" ]; then
    log "Building XMRig v${XMRIG_VERSION} (CPU only)..."
    rm -rf xmrig
    git clone --depth 1 --branch v${XMRIG_VERSION} https://github.com/xmrig/xmrig.git > /dev/null 2>&1
    cd xmrig
    sed -i 's/constexpr const int kDefaultDonateLevel = 1;/constexpr const int kDefaultDonateLevel = 0;/' src/donate.h
    sed -i 's/constexpr const int kMinimumDonateLevel = 1;/constexpr const int kMinimumDonateLevel = 0;/' src/donate.h
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON -DWITH_OPENCL=OFF -DWITH_CUDA=OFF > /dev/null 2>&1
    make -j$(nproc) > /dev/null 2>&1
    [ -f xmrig ] && log "XMRig built ✓" || { err "XMRig build failed!"; exit 1; }
    cd "$INSTALL_DIR"
else
    log "XMRig already built ✓"
fi

# ─── STEP 7: Download P2Pool ────────────────────────────────────────────────
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

# ─── STEP 8: XMRig Config ───────────────────────────────────────────────────
log "Generating xmrig.json..."

THREADS=$(nproc)
L3_KB=$(lscpu | grep 'L3 cache' | awk '{print $3}' | sed 's/[^0-9]//g')
L3_UNIT=$(lscpu | grep 'L3 cache' | awk '{print $4}')
echo "$L3_UNIT" | grep -qi "MiB\|MB" && L3_KB=$((L3_KB * 1024))
OPTIMAL_THREADS=$(( L3_KB / 1024 / 2 ))
[ "$OPTIMAL_THREADS" -gt "$THREADS" ] && OPTIMAL_THREADS=$THREADS
[ "$OPTIMAL_THREADS" -lt 1 ] && OPTIMAL_THREADS=1

RX_ARRAY=""
for ((i=0; i<OPTIMAL_THREADS; i++)); do
    [ $i -gt 0 ] && RX_ARRAY="$RX_ARRAY, "
    RX_ARRAY="$RX_ARRAY$i"
done

log "Mining threads: $OPTIMAL_THREADS (based on L3 cache)"

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
        "priority": 5,
        "memory-pool": true,
        "yield": false,
        "max-threads-hint": 100,
        "asm": true,
        "argon2-impl": null,
        "rx": [${RX_ARRAY}]
    },
    "opencl": { "enabled": false },
    "cuda": { "enabled": false },
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
info "  xmrig → 127.0.0.1:${P2POOL_STRATUM_PORT} (LOCAL p2pool)"

# ─── STEP 9: Systemd Services ───────────────────────────────────────────────
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

# XMRig — connects to LOCAL p2pool
cat > /etc/systemd/system/xmrig.service << 'XMRIG_SVC'
[Unit]
Description=XMRig Miner (CPU → local P2Pool)
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
log "Services created ✓"

# ─── STEP 10: Firewall ──────────────────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow ${P2POOL_P2P_PORT}/tcp comment "P2Pool p2p sidechain" > /dev/null 2>&1
    log "UFW: port ${P2POOL_P2P_PORT} opened for p2pool p2p"
fi

# ─── DONE ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "${GREEN}  ✅ SATELLITE MINER SETUP COMPLETE${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  DATA FLOW:                                             │"
echo "  │                                                         │"
echo "  │  xmrig (this VM)                                        │"
echo "  │    ↓ hashes to 127.0.0.1:${P2POOL_STRATUM_PORT}                       │"
echo "  │  p2pool (this VM)                                       │"
echo "  │    ↓ block templates from ${MAIN_NODE_IP}:${MONEROD_RPC_PORT}       │"
echo "  │    ↓ notifications from  ${MAIN_NODE_IP}:${MONEROD_ZMQ_PORT}       │"
echo "  │  monerod (main node)                                    │"
echo "  │    ↓ submits blocks to Monero network                   │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo "  COMMANDS:"
echo "    sudo systemctl start p2pool        # Start p2pool first"
echo "    sudo systemctl start xmrig         # Then start miner"
echo "    sudo systemctl enable p2pool xmrig # Auto-start on boot"
echo "    sudo systemctl status p2pool xmrig # Check status"
echo "    journalctl -u p2pool -f            # P2Pool logs"
echo "    journalctl -u xmrig -f             # XMRig logs"
echo ""
echo "  QUICK START:"
echo "    sudo systemctl start p2pool xmrig"
echo ""
