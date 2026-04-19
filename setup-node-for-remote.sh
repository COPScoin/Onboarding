#!/bin/bash
###############################################################################
# Monero Node — Enable Remote P2Pool Access
# 
# Run this on the VM that has monerod (20.62.43.171)
# This ensures RPC + ZMQ are open for remote P2Pool instances.
#
# Usage: sudo bash setup-node-for-remote.sh
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# Check if monerod is running
if pgrep -x monerod > /dev/null; then
    log "monerod is running (PID: $(pgrep -x monerod))"
    
    # Check current flags
    MONEROD_CMD=$(ps -p $(pgrep -x monerod) -o args= 2>/dev/null || echo "unknown")
    echo "  Current command: $MONEROD_CMD"
    echo ""
    
    # Check if RPC is accessible
    if curl -s --max-time 3 http://127.0.0.1:18081/get_info > /dev/null 2>&1; then
        log "RPC is responding on port 18081"
    else
        warn "RPC not responding on 18081"
    fi
    
    # Check if ZMQ is bound
    if ss -tlnp | grep -q ":18083"; then
        log "ZMQ is listening on port 18083"
    else
        warn "ZMQ NOT listening on port 18083 — P2Pool needs this!"
    fi
    
    # Check if RPC is bound to 0.0.0.0
    if ss -tlnp | grep ":18081" | grep -q "0.0.0.0"; then
        log "RPC is bound to 0.0.0.0 (accessible remotely)"
    else
        warn "RPC may only be on 127.0.0.1 — remote P2Pool can't connect!"
    fi
else
    warn "monerod is NOT running"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  If monerod needs reconfiguring, stop it and restart with:"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Find data directory
DATA_DIR=""
if [ -d "$HOME/.bitmonero" ]; then
    DATA_DIR="$HOME/.bitmonero"
elif [ -d "/root/.bitmonero" ]; then
    DATA_DIR="/root/.bitmonero"
elif [ -d "/home/hermes/.bitmonero" ]; then
    DATA_DIR="/home/hermes/.bitmonero"
fi

if [ -n "$DATA_DIR" ]; then
    log "Found blockchain data at: $DATA_DIR"
else
    DATA_DIR="\$HOME/.bitmonero"
    warn "Couldn't find blockchain data dir, using default"
fi

cat << EOF

  # Option A: Direct command
  monerod \\
    --data-dir=${DATA_DIR} \\
    --rpc-bind-ip=0.0.0.0 \\
    --rpc-bind-port=18081 \\
    --confirm-external-bind \\
    --restricted-rpc \\
    --zmq-pub=tcp://0.0.0.0:18083 \\
    --out-peers=32 \\
    --in-peers=64 \\
    --limit-rate-up=2048 \\
    --limit-rate-down=8192 \\
    --detach

  # Option B: Add to monerod.conf (${DATA_DIR}/monerod.conf)
  rpc-bind-ip=0.0.0.0
  rpc-bind-port=18081
  confirm-external-bind=1
  restricted-rpc=1
  zmq-pub=tcp://0.0.0.0:18083
  out-peers=32
  in-peers=64

  # Option C: If using systemd service, edit:
  sudo systemctl edit monerod
  # Add the flags to ExecStart

EOF

# ─── Firewall ────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════"
echo "  Firewall rules needed (if firewall is active):"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if command -v ufw &> /dev/null; then
    log "UFW detected. Run these:"
    echo "  sudo ufw allow 18080/tcp  # P2P"
    echo "  sudo ufw allow 18081/tcp  # RPC (restricted)"
    echo "  sudo ufw allow 18083/tcp  # ZMQ (for P2Pool)"
    echo ""
    
    read -p "Apply firewall rules now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ufw allow 18080/tcp comment "Monero P2P" > /dev/null 2>&1
        ufw allow 18081/tcp comment "Monero RPC" > /dev/null 2>&1
        ufw allow 18083/tcp comment "Monero ZMQ" > /dev/null 2>&1
        log "Firewall rules applied!"
    fi
else
    echo "  # iptables:"
    echo "  sudo iptables -A INPUT -p tcp --dport 18080 -j ACCEPT"
    echo "  sudo iptables -A INPUT -p tcp --dport 18081 -j ACCEPT"
    echo "  sudo iptables -A INPUT -p tcp --dport 18083 -j ACCEPT"
fi

# ─── Azure NSG reminder ─────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
warn "AZURE VM? Don't forget the Network Security Group (NSG)!"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  In Azure Portal → VM → Networking → Add inbound rules:"
echo "  ┌──────────┬──────────┬────────────┬──────────────────────┐"
echo "  │ Priority │ Port     │ Protocol   │ Purpose              │"
echo "  ├──────────┼──────────┼────────────┼──────────────────────┤"
echo "  │ 1010     │ 18081    │ TCP        │ Monero RPC           │"
echo "  │ 1011     │ 18083    │ TCP        │ Monero ZMQ (P2Pool)  │"
echo "  │ 1012     │ 18080    │ TCP        │ Monero P2P           │"
echo "  └──────────┴──────────┴────────────┴──────────────────────┘"
echo ""
echo "  Source: IP Addresses of your miner VMs (or * for any)"
echo ""
