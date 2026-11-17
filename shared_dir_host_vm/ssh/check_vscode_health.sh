#!/usr/bin/env bash
# ==============================================================================
# check_vscode_health.sh - Diagnose MicroVM SSH and VS Code Remote readiness
# ==============================================================================
set -u

echo "=========================================================="
echo " MicroVM VS Code Remote-SSH Health Diagnostic"
echo "=========================================================="

echo "==> 1. SSH Daemon Status:"
if ss -tlpn | grep -qE ":22\b"; then
    echo "    [PASS] sshd is listening on port 22."
    ss -tlpn | grep -E ":22\b"
else
    echo "    [FAIL] sshd is NOT listening on port 22!"
fi

echo ""
echo "==> 2. PTY (Pseudo-terminal) Device Status:"
if [ -c /dev/ptmx ] || [ -L /dev/ptmx ]; then
    echo "    [PASS] /dev/ptmx exists: $(ls -l /dev/ptmx)"
    # Try testing python or posix_openpt if available
    python3 -c "import pty; master, slave = pty.openpty(); print('    [PASS] Successfully opened PTY master/slave pair.')" 2>/dev/null || echo "    [INFO] python3 pty test not run or failed."
else
    echo "    [FAIL] /dev/ptmx is missing! VS Code integrated terminal cannot launch."
fi

echo ""
echo "==> 3. SSH Configuration & Permissions:"
echo "    /root/.ssh permissions: $(stat -c %a /root/.ssh 2>/dev/null || echo 'missing')"
echo "    authorized_keys: $(stat -c %a /root/.ssh/authorized_keys 2>/dev/null || echo 'missing')"
echo "    sshd_config directives:"
grep -E "^(Port|AllowTcpForwarding|AllowStreamLocalForwarding|PermitRootLogin|PubkeyAuthentication|GatewayPorts)" /etc/ssh/sshd_config | sed 's/^/      /'

echo ""
echo "==> 4. Active Node / VS Code Processes:"
ps aux | grep -iE 'node|vscode' | grep -v grep || echo "    (No active VS Code / Node processes)"

echo ""
echo "==> 5. All Listening TCP Ports in VM:"
ss -tlpn

echo ""
echo "==> 6. Recent VS Code Server Logs (if any):"
find /root/.vscode-server -name "*.log" -exec echo "--- {} ---" \; -exec tail -n 10 {} \; 2>/dev/null || echo "    (No logs found)"

echo ""
echo "==> 7. Recent SSH Daemon Log (/var/log/sshd.log):"
if [ -f /var/log/sshd.log ]; then
    tail -n 15 /var/log/sshd.log
else
    echo "    (No /var/log/sshd.log found)"
fi
echo "=========================================================="
