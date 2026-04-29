#!/bin/bash
###############################################################################
# SWAP ENTIRE FLEET BACK TO P2POOL
#
# Restores the proxy config to point upstream at local p2pool (127.0.0.1:3333)
# All miners stay connected to proxy on :4444 — seamless switch.
#
# Usage: bash swap-to-p2pool.sh
###############################################################################

set -euo pipefail

PARROW_HOST="20.62.43.171"
SSH_KEY="$HOME/.ssh/forge"
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 parrow@$PARROW_HOST"

WALLET="42ykwPdhRp9YNaXVJ3jrXnKzF84CneMdoPTTC4SFzqUVHkXmUocKG9FYo8wWymMgApCiyKkYfCb9USPvV9Er67ce86xu7Ho"

echo "============================================="
echo "  SWAPPING FLEET → P2POOL"
echo "============================================="
echo ""

# Step 1: Backup current config
echo "[1/4] Backing up current proxy config..."
$SSH_CMD "cp /home/parrow/xmrig-proxy-6.26.0/config.json /home/parrow/xmrig-proxy-6.26.0/config.json.moneroocean-backup"
echo "  ✓ Backed up to config.json.moneroocean-backup"

# Step 2: Ensure p2pool is running
echo "[2/4] Checking p2pool..."
P2POOL_STATUS=$($SSH_CMD "tmux has-session -t p2pool 2>&1 && echo RUNNING || echo STOPPED")
if [[ "$P2POOL_STATUS" == *"STOPPED"* ]]; then
    echo "  ⚠ p2pool not running — starting it..."
    $SSH_CMD "tmux new-session -d -s p2pool -c /home/parrow/p2pool 'cd /home/parrow/p2pool && ./p2pool --host 127.0.0.1 --rpc-port 18081 --zmq-port 18083 --wallet $WALLET --stratum 0.0.0.0:3333 --p2p 0.0.0.0:37889 --loglevel 2'"
    echo "  ✓ p2pool started — waiting 10s for sync..."
    sleep 10
else
    echo "  ✓ p2pool already running"
fi

# Step 3: Write p2pool proxy config
echo "[3/4] Writing p2pool proxy config..."
$SSH_CMD "cat > /home/parrow/xmrig-proxy-6.26.0/config.json" << 'PROXYEOF'
{
    "autosave": true,
    "background": false,
    "colors": true,
    "log-file": "/home/parrow/xmrig-proxy-6.26.0/proxy.log",
    "access-log-file": null,
    "verbose": 1,
    "mode": "nicehash",
    "custom-diff": 10000,
    "custom-diff-stats": 60,
    "donate-level": 0,
    "bind": [
        {
            "host": "0.0.0.0",
            "port": 4444,
            "tls": false
        }
    ],
    "pools": [
        {
            "algo": "rx/0",
            "url": "127.0.0.1:3333",
            "user": "42ykwPdhRp9YNaXVJ3jrXnKzF84CneMdoPTTC4SFzqUVHkXmUocKG9FYo8wWymMgApCiyKkYfCb9USPvV9Er67ce86xu7Ho",
            "pass": "Parrow-Proxy",
            "keepalive": true,
            "tls": false
        }
    ],
    "api": {
        "id": null,
        "worker-id": null
    },
    "http": {
        "enabled": true,
        "host": "127.0.0.1",
        "port": 4480,
        "access-token": null,
        "restricted": true
    }
}
PROXYEOF
echo "  ✓ p2pool config written"

# Step 4: Restart xmrig-proxy
echo "[4/4] Restarting xmrig-proxy..."
$SSH_CMD "tmux send-keys -t proxy C-c; sleep 2; tmux send-keys -t proxy 'cd /home/parrow/xmrig-proxy-6.26.0 && ./xmrig-proxy' Enter"
echo "  ✓ xmrig-proxy restarted"

echo ""
echo "============================================="
echo "  ✅ FLEET NOW MINING ON P2POOL"
echo "============================================="
echo ""
echo "  Upstream: 127.0.0.1:3333 (local p2pool)"
echo "  Proxy:    0.0.0.0:4444"
echo "  Wallet:   ${WALLET:0:12}...${WALLET: -8}"
echo "  Workers:  All VMs + containers reconnect automatically"
echo ""
echo "  To switch to MoneroOcean: bash swap-to-moneroocean.sh"
echo ""
