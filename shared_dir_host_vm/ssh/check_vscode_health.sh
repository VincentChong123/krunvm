#!/usr/bin/env bash
# ==============================================================================
# check_vscode_health.sh - Diagnose MicroVM SSH and VS Code Remote readiness
# ==============================================================================
set -u

echo "=========================================================="
echo " MicroVM VS Code Remote-SSH Health Diagnostic"
echo "=========================================================="

echo "==> 1. SSH Daemon & AF_TSI Listener Status:"
SSHD_PIDS="$(pgrep -x sshd 2>/dev/null || true)"
if [ -n "$SSHD_PIDS" ]; then
    echo "    [PASS] sshd process(es) active: $(echo "$SSHD_PIDS" | tr '\n' ' ')"
    for pid in $SSHD_PIDS; do
        cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
        sock_fds="$(ls -l "/proc/${pid}/fd" 2>/dev/null | grep "socket:" | awk '{print $9 " -> " $11}' | tr '\n' ', ')"
        echo "      PID $pid ($cmdline): ${sock_fds:-no sockets}"
    done
else
    echo "    [FAIL] sshd is NOT running!"
fi

python3 -c '
import socket
c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
c.settimeout(2)
try:
    c.connect(("127.0.0.1", 2222))
    banner = c.recv(64).decode("utf-8", errors="replace").strip()
    print(f"    [PASS] Round-trip Host(127.0.0.1:2222) -> Guest(22) banner: {banner}")
except Exception as e:
    print(f"    [FAIL] Round-trip Host(127.0.0.1:2222) -> Guest(22) failed: {e}")
finally:
    c.close()
' 2>/dev/null || true

echo ""
echo "==> 2. AF_TSI Ephemeral Port (port=0) Fix Status:"
if [ -f /usr/local/lib/libkrun_tsi_fix.so ] && grep -qxF "/usr/local/lib/libkrun_tsi_fix.so" /etc/ld.so.preload 2>/dev/null; then
    echo "    [PASS] /usr/local/lib/libkrun_tsi_fix.so is installed and active in /etc/ld.so.preload."
else
    echo "    [FAIL] /usr/local/lib/libkrun_tsi_fix.so is missing or not in /etc/ld.so.preload!"
fi

python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
s.listen(1)
port = s.getsockname()[1]
c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
c.settimeout(2)
try:
    c.connect(("127.0.0.1", port))
    conn, _ = s.accept()
    conn.sendall(b"PING")
    data = c.recv(16)
    print(f"    [PASS] Ephemeral port=0 bind/connect succeeded (port={port}, recv={data!r}).")
    conn.close()
except Exception as e:
    print(f"    [FAIL] Ephemeral port=0 bind/connect failed on port {port}: {e}")
finally:
    c.close()
    s.close()
' 2>/dev/null || true

echo ""
echo "==> 3. PTY (Pseudo-terminal) Device Status:"
if [ -c /dev/ptmx ] || [ -L /dev/ptmx ]; then
    echo "    [PASS] /dev/ptmx exists: $(ls -l /dev/ptmx)"
    python3 -c "import os, pty; master, slave = pty.openpty(); os.close(master); os.close(slave); print('    [PASS] Successfully opened PTY master/slave pair.')" 2>/dev/null || echo "    [FAIL] python3 pty test failed."
else
    echo "    [FAIL] /dev/ptmx is missing! VS Code integrated terminal cannot launch."
fi

echo ""
echo "==> 4. SSH Configuration & Permissions:"
echo "    /root/.ssh permissions: $(stat -c %a /root/.ssh 2>/dev/null || echo 'missing')"
echo "    authorized_keys: $(stat -c %a /root/.ssh/authorized_keys 2>/dev/null || echo 'missing') ($(wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0) key(s))"
echo "    sshd_config directives:"
grep -E "^(Port|AllowTcpForwarding|AllowStreamLocalForwarding|PermitRootLogin|PubkeyAuthentication|GatewayPorts)" /etc/ssh/sshd_config | sed 's/^/      /'

echo ""
echo "==> 5. Active Node / VS Code Processes:"
ps aux | grep -iE 'node|vscode' | grep -vE 'grep|check_vscode_health' || echo "    (No active VS Code / Node processes)"

echo ""
echo "==> 6. Recent VS Code Server Logs (if any):"
find /root/.vscode-server -maxdepth 2 -name ".*.log" -exec echo "--- {} ---" \; -exec tail -n 10 {} \; 2>/dev/null || echo "    (No logs found)"

echo ""
echo "==> 7. Recent SSH Daemon Log (/var/log/sshd.log):"
if [ -f /var/log/sshd.log ]; then
    tail -n 15 /var/log/sshd.log
else
    echo "    (No /var/log/sshd.log found)"
fi
echo "=========================================================="
