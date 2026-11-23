#!/usr/bin/env bash
# ==============================================================================
# setup_vscode.sh - Prepare krunvm MicroVM for VS Code Remote-SSH
# Ensures all SSH daemon options, AF_TSI port=0 workaround, PTY terminal support,
# auto-start hooks, and VS Code Server prerequisites are configured and running.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo " Preparing MicroVM for VS Code Remote-SSH"
echo "=========================================================="

# 1. Ensure required tools are installed
echo "==> [1/7] Verifying system dependencies..."
MISSING_PKGS=()
for pair in "curl:curl" "wget:wget" "tar:tar" "gzip:gzip" "ps:procps" "ip:iproute2" "gcc:gcc"; do
    cmd="${pair%%:*}"
    pkg="${pair##*:}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
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
echo "==> [2/7] Configuring Pseudoterminal (PTY) devices for terminal support..."
mkdir -p /dev/pts
mount -t devpts -o remount,ptmxmode=0666,mode=620 devpts /dev/pts 2>/dev/null || \
mount -t devpts -o ptmxmode=0666,mode=620 devpts /dev/pts 2>/dev/null || true

if [ ! -e /dev/ptmx ] || [ ! -c /dev/ptmx ]; then
    rm -f /dev/ptmx
    ln -s /dev/pts/ptmx /dev/ptmx 2>/dev/null || mknod /dev/ptmx c 5 2 2>/dev/null || true
fi
chmod 666 /dev/ptmx 2>/dev/null || true
chmod 666 /dev/pts/ptmx 2>/dev/null || true

if [ -e /dev/ptmx ]; then
    echo "    [OK] /dev/ptmx is available (mode: $(stat -c %a /dev/ptmx 2>/dev/null || echo 'unknown'))."
else
    echo "    [WARN] /dev/ptmx could not be created; terminal allocation may be affected."
fi

# 3. Compile and install libkrun_tsi_fix.so to fix AF_TSI port=0 bug
echo "==> [3/7] Building and installing AF_TSI port=0 fix (libkrun_tsi_fix.so)..."
mkdir -p /usr/local/lib
TSI_FIX_SRC="${SCRIPT_DIR}/libkrun_tsi_fix.c"
TSI_FIX_SO="/usr/local/lib/libkrun_tsi_fix.so"

if [ ! -f "$TSI_FIX_SRC" ]; then
    echo "    [ERROR] Missing source file: $TSI_FIX_SRC" >&2
    exit 1
fi

# Remove from /etc/ld.so.preload briefly while replacing the shared object
if [ -f /etc/ld.so.preload ]; then
    sed -i '\|/usr/local/lib/libkrun_tsi_fix.so|d' /etc/ld.so.preload 2>/dev/null || true
fi

gcc -shared -fPIC -O2 -Wall -Wextra "$TSI_FIX_SRC" -o "${TSI_FIX_SO}.tmp" -ldl
chmod 0755 "${TSI_FIX_SO}.tmp"
mv -f "${TSI_FIX_SO}.tmp" "$TSI_FIX_SO"

if ! grep -qxF "$TSI_FIX_SO" /etc/ld.so.preload 2>/dev/null; then
    echo "$TSI_FIX_SO" >> /etc/ld.so.preload
fi
chmod 0644 /etc/ld.so.preload
echo "    [OK] Installed $TSI_FIX_SO and registered in /etc/ld.so.preload."

# Verify port=0 loopback bind/connect now works under AF_TSI
if python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
s.listen(1)
port = s.getsockname()[1]
c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
c.settimeout(2)
c.connect(("127.0.0.1", port))
conn, _ = s.accept()
conn.sendall(b"TSI_OK")
assert c.recv(16) == b"TSI_OK"
c.close(); conn.close(); s.close()
print(f"    [OK] Verified AF_TSI port=0 bind/connect (assigned port {port}).")
'; then
    :
else
    echo "    [ERROR] AF_TSI port=0 self-test failed!" >&2
    exit 1
fi

# 4. Configure SSH daemon specifically for VS Code Remote-SSH & port forwarding
echo "==> [4/7] Configuring OpenSSH daemon (/etc/ssh/sshd_config)..."
mkdir -p /run/sshd /root/.ssh
chmod 0755 /run/sshd
chmod 700 /root/.ssh

# Sync public key from vm2host if present, and ensure authorized_keys has strict permissions
if [ -f /shared_dir_host_vm/vm2host/id_ed25519.pub ]; then
    PUBKEY_CONTENT="$(cat /shared_dir_host_vm/vm2host/id_ed25519.pub)"
    if [ -n "$PUBKEY_CONTENT" ] && ! grep -qxF "$PUBKEY_CONTENT" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$PUBKEY_CONTENT" >> /root/.ssh/authorized_keys
    fi
fi
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

# 5. Clean up stale VS Code Server processes and locks
echo "==> [5/7] Cleaning up stale VS Code locks and ephemeral sockets..."
for vpid in $(pgrep -f "/root/\.vscode-server/.*/node .*server-main\.js" 2>/dev/null || true); do
    if [ "$vpid" != "$$" ] && [ "$vpid" != "$PPID" ]; then
        kill -9 "$vpid" 2>/dev/null || true
    fi
done
find /root/.vscode-server -name "*.pid" -delete 2>/dev/null || true
find /root/.vscode-server -name "*.sock" -delete 2>/dev/null || true

# 6. Verify network loopback & install auto-start hook in /etc/bash.bashrc
echo "==> [6/7] Configuring loopback and auto-start hook (/shared_dir_host_vm/ssh/ensure-sshd.sh)..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if ! grep -q "127.0.0.1 localhost" /etc/hosts; then
    echo "127.0.0.1 localhost" >> /etc/hosts
fi
sed -i 's/^::1[[:space:]]*localhost/# ::1 localhost/' /etc/hosts 2>/dev/null || true

chmod 0755 "${SCRIPT_DIR}/ensure-sshd.sh" 2>/dev/null || true
rm -f /usr/local/bin/ensure-sshd.sh
sed -i '\|ensure-sshd\.sh|d' /etc/bash.bashrc 2>/dev/null || true
echo '[ -x /shared_dir_host_vm/ssh/ensure-sshd.sh ] && /shared_dir_host_vm/ssh/ensure-sshd.sh >/dev/null 2>&1 || true' >> /etc/bash.bashrc
echo "    [OK] Registered /shared_dir_host_vm/ssh/ensure-sshd.sh in /etc/bash.bashrc."

# Register link_vm_workspace.sh hook to ensure workspace symlinks stay in sync
if [ -x /shared_dir_host_vm/scripts/link_vm_workspace.sh ]; then
    /shared_dir_host_vm/scripts/link_vm_workspace.sh >/dev/null 2>&1 || true
    sed -i '\|link_vm_workspace\.sh|d' /etc/bash.bashrc 2>/dev/null || true
    echo '[ -x /shared_dir_host_vm/scripts/link_vm_workspace.sh ] && /shared_dir_host_vm/scripts/link_vm_workspace.sh >/dev/null 2>&1 || true' >> /etc/bash.bashrc
    echo "    [OK] Registered /shared_dir_host_vm/scripts/link_vm_workspace.sh in /etc/bash.bashrc."
fi

# Apply dotfiles from read-only mount (/dotfiles)
if [ -x /shared_dir_host_vm/scripts/apply_dotfiles.sh ]; then
    /shared_dir_host_vm/scripts/apply_dotfiles.sh >/dev/null 2>&1 || true
    echo "    [OK] Synchronized dotfiles from read-only /dotfiles mount."
fi

# 7. Start / Restart sshd daemon reliably (single instance, detached session, AF_TSI-aware check)
echo "==> [7/7] Starting SSH daemon and verifying AF_TSI listener..."
pkill -9 -x sshd 2>/dev/null || true
sleep 0.5
rm -f /var/log/sshd.log

# Use standard daemonizing mode (-E /var/log/sshd.log, NO -D flag) wrapped in setsid
# so sshd detaches from the controlling terminal and never receives SIGHUP on shell exit.
setsid /usr/sbin/sshd -E /var/log/sshd.log </dev/null >/dev/null 2>&1
sleep 1

SSHD_PID="$(pgrep -o -x sshd 2>/dev/null || true)"

# Note: Under krunvm's AF_TSI (tsi_hijack), listening sockets use PF_TSI and do not
# appear in /proc/net/tcp (so `ss -tlpn` is empty). We verify:
#   (a) sshd process is alive and holds an open socket fd in /proc/$SSHD_PID/fd
#   (b) round-trip TCP connection to 127.0.0.1:2222 (Host PC port 2222 -> Guest port 22)
if [ -n "$SSHD_PID" ] && kill -0 "$SSHD_PID" 2>/dev/null && ls -l "/proc/${SSHD_PID}/fd" 2>/dev/null | grep -q "socket:"; then
    echo "    [OK] sshd is running in detached daemon mode (PID: $SSHD_PID) with active AF_TSI listening socket."
else
    echo "    [ERROR] sshd failed to start!" >&2
    cat /var/log/sshd.log 2>/dev/null || true
    exit 1
fi

if python3 -c '
import socket
c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
c.settimeout(3)
c.connect(("127.0.0.1", 2222))
banner = c.recv(64).decode("utf-8", errors="replace").strip()
c.close()
assert banner.startswith("SSH-2.0-"), f"Unexpected banner: {banner}"
print(f"    [OK] Round-trip Host:2222 -> Guest:22 SSH banner verified: {banner}")
'; then
    :
else
    echo "    [WARN] Could not verify round-trip on 127.0.0.1:2222; check krunvm port mapping (-p 2222:22)."
fi

echo ""
echo "=========================================================="
echo " [SUCCESS] MicroVM is now ready for VS Code Remote-SSH!"
echo "=========================================================="
echo "Next step on Host PC:"
echo "  1. Run: ./shared_dir_host_vm/vm2host/setup_host_vscode_ssh.sh"
echo "  2. Run: ./shared_dir_host_vm/vm2host/test_host_to_vm_ssh.sh"
echo "  3. Connect in VS Code: Ctrl+Shift+P -> 'Remote-SSH: Connect to Host...' -> krun-act-runner"
echo "=========================================================="
