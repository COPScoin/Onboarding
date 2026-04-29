#!/bin/bash
###############################################################################
# SWAP ENTIRE FLEET TO MONEROOCEAN
#
# What this does:
#   1. Replaces xmrig-proxy config on Parrow → points upstream to MoneroOcean
#   2. Restarts xmrig-proxy (miners stay connected, just get new jobs)
#   
# What this does NOT need to do:
#   - Touch any VM or container configs — they all point to the proxy on :4444
#   - The proxy handles the upstream switch transparently
#
# Usage: bash swap-to-moneroocean.sh
###############################################################################

set -euo pipefail

PARROW_HOST="20.62.43.171"
SSH_KEY="$HOME/.ssh/forge"
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 parrow@$PARROW_HOST"

WALLET="42ykwPdhRp9YNaXVJ3jrXnKzF84CneMdoPTTC4SFzqUVHkXmUocKG9FYo8wWymMgApCiyKkYfCb9USPvV9Er67ce86xu7Ho"

echo "============================================="
echo "  SWAPPING FLEET → MONEROOCEAN"
echo "============================================="
echo ""

# Step 1: Backup current proxy config
echo "[1/3] Backing up current proxy config..."
$SSH_CMD "cp /home/parrow/xmrig-proxy-6.26.0/config.json /home/parrow/xmrig-proxy-6.26.0/config.json.p2pool-backup"
echo "  ✓ Backed up to config.json.p2pool-backup"

# Step 2: Write MoneroOcean proxy config
echo "[2/3] Writing MoneroOcean proxy config..."
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
            "algo": null,
            "url": "gulf.moneroocean.stream:10128",
            "user": "42ykwPdhRp9YNaXVJ3jrXnKzF84CneMdoPTTC4SFzqUVHkXmUocKG9FYo8wWymMgApCiyKkYfCb9USPvV9Er67ce86xu7Ho",
            "pass": "Parrow-Proxy",
            "keepalive": true,
            "tls": true
        },
        {
            "algo": null,
            "url": "gulf.moneroocean.stream:10032",
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
echo "  ✓ MoneroOcean config written"

# Step 3: Restart xmrig-proxy in tmux
echo "[3/3] Restarting xmrig-proxy..."
$SSH_CMD "tmux send-keys -t proxy C-c; sleep 2; tmux send-keys -t proxy 'cd /home/parrow/xmrig-proxy-6.26.0 && ./xmrig-proxy' Enter"
echo "  ✓ xmrig-proxy restarted"

echo ""
echo "============================================="
echo "  ✅ FLEET NOW MINING ON MONEROOCEAN"
echo "============================================="
echo ""
echo "  Pool:    gulf.moneroocean.stream"
echo "  Port:    10128 (TLS) / 10032 (fallback)"
echo "  Wallet:  ${WALLET:0:12}...${WALLET: -8}"
echo "  Workers: All VMs + containers reconnect automatically"
echo ""
echo "  Dashboard: https://moneroocean.stream/#/dashboard?addr=$WALLET"
echo ""
echo "  To switch back to p2pool: bash swap-to-p2pool.sh"
echo ""
