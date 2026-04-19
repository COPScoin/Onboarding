#!/bin/bash
###############################################################################
# MONERO NODE SETUP — Run on the MAIN NODE (20.62.43.171)
#
# This ensures monerod is configured for remote P2Pool connections
# and that all required ports are open.
#
# Usage: sudo bash setup-node.sh
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  MONERO NODE — Remote P2Pool Access Setup"
echo "  This VM: $(hostname) / $(hostname -I | awk '{print $1}')"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── CHECK MONEROD STATUS ────────────────────────────────────────────────────
if pgrep -x monerod > /dev/null; then
    MONEROD_PID=$(pgrep -x monerod)
    MONEROD_CMD=$(ps -p $MONEROD_PID -o args= 2>/dev/null || echo "unknown")
    log "monerod is running (PID: $MONEROD_PID)"
    info "Command: $MONEROD_CMD"
else
    err "monerod is NOT running!"
    echo ""
    echo "  Start monerod first, then re-run this script."
    echo "  See the monerod command below for required flags."
    echo ""
fi

echo ""

# ─── CHECK PORTS ─────────────────────────────────────────────────────────────
info "Checking port bindings..."

ISSUES=0

# RPC port 18081
if ss -tlnp | grep -q ":18081"; then
    if ss -tlnp | grep ":18081" | grep -q "0.0.0.0"; then
        log "RPC port 18081 — listening on 0.0.0.0 (remote accessible) ✓"
    else
        warn "RPC port 18081 — listening on 127.0.0.1 ONLY (satellites can't connect!)"
        ISSUES=$((ISSUES + 1))
    fi
else
    err "RPC port 18081 — NOT listening!"
    ISSUES=$((ISSUES + 1))
fi

# ZMQ port 18083
if ss -tlnp | grep -q ":18083"; then
    if ss -tlnp | grep ":18083" | grep -q "0.0.0.0"; then
        log "ZMQ port 18083 — listening on 0.0.0.0 (remote accessible) ✓"
    else
        warn "ZMQ port 18083 — listening on 127.0.0.1 ONLY (satellites can't connect!)"
        ISSUES=$((ISSUES + 1))
    fi
else
    err "ZMQ port 18083 — NOT listening! P2Pool REQUIRES this."
    ISSUES=$((ISSUES + 1))
fi

# P2P port 18080
if ss -tlnp | grep -q ":18080"; then
    log "P2P port 18080 — listening ✓"
else
    warn "P2P port 18080 — not detected (monerod may use a different port)"
fi

# Stratum port 3333 (if p2pool runs on this node too)
if ss -tlnp | grep -q ":3333"; then
    if ss -tlnp | grep ":3333" | grep -q "0.0.0.0"; then
        log "P2Pool stratum 3333 — listening on 0.0.0.0 ✓"
    else
        warn "P2Pool stratum 3333 — listening on 127.0.0.1 only"
        info "This is fine IF satellites run their own P2Pool instances"
    fi
fi

echo ""

# ─── CHECK RPC RESPONDS ─────────────────────────────────────────────────────
info "Testing RPC..."
if curl -s --max-time 5 http://127.0.0.1:18081/get_info > /dev/null 2>&1; then
    HEIGHT=$(curl -s --max-time 5 http://127.0.0.1:18081/get_info | python3 -c "import sys,json; print(json.load(sys.stdin).get('height','unknown'))" 2>/dev/null || echo "unknown")
    log "RPC responding — blockchain height: $HEIGHT"
else
    err "RPC not responding on 127.0.0.1:18081!"
    ISSUES=$((ISSUES + 1))
fi

echo ""

# ─── FIREWALL ────────────────────────────────────────────────────────────────
info "Checking firewall..."

# iptables
IPTABLES_BLOCKING=false
if iptables -L INPUT -n 2>/dev/null | grep -q "DROP\|REJECT"; then
    # Check if our ports are explicitly allowed
    for PORT in 18080 18081 18083 3333; do
        if ! iptables -L INPUT -n 2>/dev/null | grep -q "$PORT"; then
            warn "iptables may be blocking port $PORT"
            IPTABLES_BLOCKING=true
        fi
    done
fi

if [ "$IPTABLES_BLOCKING" = true ]; then
    echo ""
    read -p "  Open ports 18080/18081/18083/3333 in iptables now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        iptables -I INPUT -p tcp --dport 18080 -j ACCEPT
        iptables -I INPUT -p tcp --dport 18081 -j ACCEPT
        iptables -I INPUT -p tcp --dport 18083 -j ACCEPT
        iptables -I INPUT -p tcp --dport 3333 -j ACCEPT
        log "iptables rules added!"
    fi
fi

# ufw
if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "active"; then
    info "UFW is active"
    for PORT in 18080 18081 18083 3333; do
        if ! ufw status | grep -q "$PORT"; then
            warn "UFW: port $PORT not allowed"
        else
            log "UFW: port $PORT allowed ✓"
        fi
    done
    
    echo ""
    read -p "  Add UFW rules for mining ports? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ufw allow 18080/tcp comment "Monero P2P" > /dev/null 2>&1
        ufw allow 18081/tcp comment "Monero RPC" > /dev/null 2>&1
        ufw allow 18083/tcp comment "Monero ZMQ" > /dev/null 2>&1
        ufw allow 3333/tcp comment "P2Pool Stratum" > /dev/null 2>&1
        log "UFW rules added!"
    fi
fi

echo ""

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
if [ "$ISSUES" -gt 0 ]; then
    echo "═══════════════════════════════════════════════════════════════"
    err "$ISSUES ISSUE(S) FOUND — monerod needs reconfiguring"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Stop monerod and restart with these flags:"
    echo ""
    echo "  monerod \\"
    echo "    --data-dir=\$HOME/.bitmonero \\"
    echo "    --rpc-bind-ip=0.0.0.0 \\"
    echo "    --rpc-bind-port=18081 \\"
    echo "    --confirm-external-bind \\"
    echo "    --restricted-rpc \\"
    echo "    --zmq-pub=tcp://0.0.0.0:18083 \\"
    echo "    --out-peers=32 \\"
    echo "    --in-peers=64 \\"
    echo "    --detach"
    echo ""
    echo "  Or if using systemd, edit the service:"
    echo "    sudo systemctl edit monerod"
    echo ""
else
    echo "═══════════════════════════════════════════════════════════════"
    log "ALL CHECKS PASSED — node is ready for remote P2Pool connections"
    echo "═══════════════════════════════════════════════════════════════"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  AZURE NSG REMINDER"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  In Azure Portal → VM → Networking → Inbound port rules:"
echo ""
echo "  ┌──────────┬──────────┬────────────────────────────────────┐"
echo "  │ Port     │ Protocol │ Purpose                            │"
echo "  ├──────────┼──────────┼────────────────────────────────────┤"
echo "  │ 18080    │ TCP      │ Monero P2P (blockchain sync)       │"
echo "  │ 18081    │ TCP      │ Monero RPC (P2Pool needs this)     │"
echo "  │ 18083    │ TCP      │ Monero ZMQ (P2Pool needs this)     │"
echo "  │ 3333     │ TCP      │ P2Pool Stratum (if direct mining)  │"
echo "  └──────────┴──────────┴────────────────────────────────────┘"
echo ""
echo "  Source: IP addresses of your satellite miner VMs"
echo ""
