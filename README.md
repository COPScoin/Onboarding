# XMRig + P2Pool Mining Setup

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     MAIN NODE (20.62.43.171)                    │
│                                                                 │
│  monerod (:18081 RPC, :18083 ZMQ, :18080 P2P)                 │
│  p2pool  (:3333 stratum, :37889 p2p sidechain)                │
│  xmrig   → 127.0.0.1:3333 (mines to local p2pool)            │
└──────────────────────┬──────────────────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          │            │            │
          ▼            ▼            ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│ SATELLITE 1 │ │ SATELLITE 2 │ │ SATELLITE 3 │
│ (CPU only)  │ │ (CPU+GPU)   │ │ (CPU only)  │
│             │ │             │ │             │
│ p2pool ─────┼─┼─────────────┼─┼──→ monerod  │
│  :3333      │ │  :3333      │ │  :3333      │
│  :37889     │ │  :37889     │ │  :37889     │
│ xmrig ──→   │ │ xmrig ──→   │ │ xmrig ──→   │
│ 127.0.0.1   │ │ 127.0.0.1   │ │ 127.0.0.1   │
│ :3333       │ │ :3333       │ │ :3333       │
└─────────────┘ └─────────────┘ └─────────────┘
```

### Key Point
Each satellite runs its **own p2pool instance** that connects to the main node's monerod.
xmrig on each satellite connects to its **own local p2pool** at `127.0.0.1:3333`.
Satellites do NOT connect directly to the main node's p2pool stratum.

## Scripts

| Script | Run Where | What It Does |
|--------|-----------|-------------|
| `setup-node.sh` | Main node | Verifies monerod config, checks ports, opens firewall |
| `setup-satellite.sh` | CPU-only satellites | Installs p2pool + xmrig (CPU), connects to main node's monerod |
| `setup-satellite-gpu.sh` | GPU satellites (AMD) | Same + OpenCL, GPU firmware fix, GPU driver setup |

### Old scripts (superseded):
- `setup-miner.sh` → replaced by `setup-satellite.sh`
- `setup-miner-gpu.sh` → replaced by `setup-satellite-gpu.sh`
- `setup-node-for-remote.sh` → replaced by `setup-node.sh`

## Port Map

### Main Node must expose:
| Port | Protocol | Purpose | Who connects |
|------|----------|---------|-------------|
| 18081 | TCP | monerod RPC | Satellite p2pool instances |
| 18083 | TCP | monerod ZMQ | Satellite p2pool instances |
| 18080 | TCP | monerod P2P | Monero network |

### Each Satellite uses locally:
| Port | Protocol | Purpose | Bound to |
|------|----------|---------|----------|
| 3333 | TCP | p2pool stratum | 0.0.0.0 (but only xmrig uses it locally) |
| 37889 | TCP | p2pool p2p sidechain | 0.0.0.0 (talks to other p2pool nodes globally) |
| 37841 | TCP | xmrig HTTP API | 127.0.0.1 (local monitoring only) |

## Quick Deploy

### Main Node:
```bash
sudo bash setup-node.sh
# Verify all checks pass
```

### CPU Satellite:
```bash
scp setup-satellite.sh user@SATELLITE_IP:~/
ssh user@SATELLITE_IP
sudo bash setup-satellite.sh
sudo systemctl start p2pool xmrig
sudo systemctl enable p2pool xmrig
```

### GPU Satellite (AMD Vega/MI25):
```bash
scp setup-satellite-gpu.sh user@SATELLITE_IP:~/
ssh user@SATELLITE_IP
sudo bash setup-satellite-gpu.sh
sudo reboot  # Required for GPU firmware
# After reboot:
sudo systemctl start p2pool xmrig
sudo systemctl enable p2pool xmrig
```

## Monitoring

```bash
# Check services
sudo systemctl status p2pool xmrig

# Live logs
journalctl -u p2pool -f
journalctl -u xmrig -f

# XMRig hashrate
curl -s http://127.0.0.1:37841/2/summary | python3 -m json.tool

# P2Pool shares
grep -i "share" /opt/mining/p2pool/p2pool.log | tail -20
```

## Troubleshooting

### "connect error" from xmrig
- xmrig connects to LOCAL p2pool (127.0.0.1:3333)
- Make sure p2pool is running: `systemctl status p2pool`
- p2pool starts first, xmrig waits 5 seconds

### p2pool can't connect to monerod
- Check main node ports: `nc -zv 20.62.43.171 18081` and `nc -zv 20.62.43.171 18083`
- Check Azure NSG allows inbound 18081/18083 from satellite IPs
- Check monerod binds to 0.0.0.0: `ss -tlnp | grep 18081` on main node

### GPU not detected (MI25/Vega)
- Check firmware: `ls /lib/firmware/amdgpu/vega10_gpu_info.bin`
- Check driver: `lsmod | grep amdgpu`
- Check compute node: `ls /dev/dri/renderD128`
- Check dmesg: `dmesg | grep -i amdgpu | grep -i error`
- Reboot after firmware install: `sudo reboot`

### p2pool shows 0 hashrate
- It takes time to find shares (hours at low hashrate)
- Check xmrig is submitting: `journalctl -u xmrig | grep accepted`
- Check p2pool sees the miner: `journalctl -u p2pool | grep "new miner"`
