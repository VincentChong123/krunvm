#!/usr/bin/env bash
# ==============================================================================
# setup_vscode.sh - Prepare krunvm MicroVM for VS Code Remote-SSH
# Ensures all SSH daemon options, network configs, PTY terminal support,
# and VS Code Server prerequisites are properly configured and running.
# ==============================================================================
set -euo pipefail

echo "=========================================================="
echo " Preparing MicroVM for VS Code Remote-SSH"
echo "=========================================================="

# 1. Ensure required tools are installed
echo "==> [1/6] Verifying system dependencies..."
MISSING_PKGS=()
for pkg in curl wget tar gzip procps iproute2; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "    Installing missing packages: ${MISSING_PKGS[*]}..."
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    sed -i 's|http://archive.ubuntu.com|http://azure.archive.ubuntu.com|g' /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list 2>/dev/null || true
    apt-get update -y && apt-get install -y "${MISSING_PKGS[@]}"
else
    echo "    All required dependencies are installed."
fi

# 2. Fix /dev/ptmx and /dev/pts (Essential for VS Code integrated terminal / node-pty)
echo "==> [2/6] Configuring Pseudoterminal (PTY) devices for terminal support..."
mkdir -p /dev/pts
mount -t devpts -o remount,ptmxmode=0666,mode=620 devpts /dev/pts 2>/dev/null || \
mount -t devpts -o ptmxmode=0666,mode=620 devpts /dev/pts 2>/dev/null || true

# Ensure /dev/ptmx is accessible to allocate new terminals
if [ ! -e /dev/ptmx ] || [ ! -c /dev/ptmx ]; then
    rm -f /dev/ptmx
    ln -s /dev/pts/ptmx /dev/ptmx 2>/dev/null || mknod /dev/ptmx c 5 2 2>/dev/null || true
fi
chmod 666 /dev/ptmx 2>/dev/null || true
chmod 666 /dev/pts/ptmx 2>/dev/null || true

# Test PTY allocation
if [ -e /dev/ptmx ]; then
    echo "    [OK] /dev/ptmx is available (mode: $(stat -c %a /dev/ptmx 2>/dev/null || echo 'unknown'))."
else
    echo "    [WARN] /dev/ptmx could not be created; terminal allocation may be affected."
fi

# 3. Configure SSH daemon specifically for VS Code Remote-SSH & port forwarding
echo "==> [3/6] Configuring OpenSSH daemon (/etc/ssh/sshd_config)..."
mkdir -p /run/sshd /root/.ssh
chmod 0755 /run/sshd
chmod 700 /root/.ssh
[ -f /root/.ssh/authorized_keys ] && chmod 600 /root/.ssh/authorized_keys

# Neutralize conflicting overrides in sshd_config.d
if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        if [ -f "$f" ]; then
            echo "    Backing up overriding config: $f"
            mv "$f" "${f}.bak" 2>/dev/null || true
        fi
    done
fi

cat << 'SSHEOF' > /etc/ssh/sshd_config
# Clean OpenSSH configuration for krunvm VS Code Remote-SSH
Port 22
AddressFamily inet
ListenAddress 0.0.0.0
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes

# Critical port and socket forwarding directives for VS Code
AllowTcpForwarding yes
AllowAgentForwarding yes
AllowStreamLocalForwarding yes
GatewayPorts yes
X11Forwarding yes

# Keep-alive settings to prevent disconnection
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 10

# Subsystem & environment
Subsystem sftp /usr/lib/openssh/sftp-server
AcceptEnv LANG LC_*
SSHEOF

# Generate host keys if missing
ssh-keygen -A >/dev/null 2>&1 || true

# Validate sshd configuration
if ! /usr/sbin/sshd -t; then
    echo "    [ERROR] sshd_config validation failed!" >&2
    exit 1
fi

# 4. Clean up stale VS Code Server processes and locks
echo "==> [4/6] Cleaning up stale VS Code locks and ephemeral sockets..."
# Kill any lingering node/vscode processes
kill -9 $(ps aux | grep -iE 'vscode-server|server-main.js' | grep -v grep | awk '{print $2}') 2>/dev/null || true

# Remove stale sockets and pids, but preserve downloaded server binaries
find /root/.vscode-server -name "*.pid" -delete 2>/dev/null || true
find /root/.vscode-server -name "*.sock" -delete 2>/dev/null || true

# 5. Verify network loopback & IP forwarding
echo "==> [5/6] Verifying loopback and kernel networking..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if ! grep -q "127.0.0.1 localhost" /etc/hosts; then
    echo "127.0.0.1 localhost" >> /etc/hosts
fi
sed -i 's/^::1[[:space:]]*localhost/# ::1 localhost/' /etc/hosts 2>/dev/null || true

# 6. Start / Restart sshd daemon reliably
echo "==> [6/6] Starting SSH daemon in persistent daemon mode..."
pkill -9 sshd 2>/dev/null || true
sleep 1

# Launch sshd with non-detaching -D flag into background to ensure persistent multi-connection handling
/usr/sbin/sshd -D -e > /var/log/sshd.log 2>&1 &
SSHD_PID=$!
sleep 1

# Check if sshd is listening
if ss -tlpn | grep -qE ":22\b"; then
    echo "    [OK] sshd is running (PID: $SSHD_PID) and listening on 0.0.0.0:22."
else
    echo "    [WARN] Background sshd didn't bind immediately, trying standard /usr/sbin/sshd..."
    /usr/sbin/sshd
    sleep 1
    if ss -tlpn | grep -qE ":22\b"; then
        echo "    [OK] sshd is running and listening on 0.0.0.0:22."
    else
        echo "    [ERROR] sshd failed to bind to port 22!" >&2
        echo "    Recent /var/log/sshd.log output:"
        cat /var/log/sshd.log 2>/dev/null || true
        exit 1
    fi
fi

echo ""
echo "=========================================================="
echo " [SUCCESS] MicroVM is now ready for VS Code Remote-SSH!"
echo "=========================================================="
echo "Recommended Host PC Settings (~/.config/Code/User/settings.json):"
echo '  "remote.SSH.remoteServerListenOnSocket": true'
echo '  "remote.SSH.useExecServer": false'
echo ""
echo "Next step in Host PC VS Code:"
echo "  1. Press Ctrl+Shift+P -> 'Remote-SSH: Connect to Host...'"
echo "  2. Select: krun-act-runner"
echo "  3. Open terminal in VS Code: Ctrl+\` or Terminal -> New Terminal"
echo "=========================================================="
