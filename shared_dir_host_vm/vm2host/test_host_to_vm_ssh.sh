#!/usr/bin/env bash
# ==============================================================================
# test_host_to_vm_ssh.sh - End-to-End Host PC -> krunvm VS Code SSH Verifier
#
# LOCATION ON HOST PC:
#   /home/vin/ws/github/VincentChong123/krunvm/shared_dir_host_vm/vm2host/test_host_to_vm_ssh.sh
#
# USAGE ON HOST PC:
#   ./test_host_to_vm_ssh.sh           # Run all 5 end-to-end SSH & VS Code checks
#   ./test_host_to_vm_ssh.sh --launch  # Run checks, then open VS Code on krun-act-runner
#
# WHAT THIS SCRIPT TESTS:
#   1. Host PC -> 127.0.0.1:2222 raw TCP & OpenSSH banner check.
#   2. Passwordless Ed25519 SSH authentication via `ssh krun-act-runner`.
#   3. Remote PTY allocation (`ssh -tt krun-act-runner`), required by VS Code
#      integrated terminal.
#   4. End-to-End SSH TCP Local Port Forwarding (`ssh -L`) to a `port=0` server
#      inside the VM (simulates VS Code's default `code-server --port=0` flow).
#   5. End-to-End SSH Unix Domain Socket Forwarding (`StreamLocalForward`) to a
#      Unix socket inside the VM (simulates `remoteServerListenOnSocket: true`).
# ==============================================================================
set -euo pipefail

HOST_ALIAS="krun-act-runner"
LAUNCH_VSCODE=false

for arg in "$@"; do
    case "$arg" in
        --launch|-l)
            LAUNCH_VSCODE=true
            ;;
    esac
done

echo "=================================================================="
echo " End-to-End Host PC -> krunvm (${HOST_ALIAS}) Verification"
echo "=================================================================="

# Safety check: Ensure this is run on the Host PC, not inside the krunvm VM
if [ -f /init.krun ] || grep -q "tsi_hijack" /proc/cmdline 2>/dev/null; then
    echo "[ERROR] Detected krunvm guest environment. Run this script on the Host PC:" >&2
    echo "        /home/vin/ws/github/VincentChong123/krunvm/shared_dir_host_vm/vm2host/test_host_to_vm_ssh.sh" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Test 1: Raw TCP & SSH Banner on 127.0.0.1:2222
# ------------------------------------------------------------------------------
echo "==> [Test 1/5] Checking TCP 127.0.0.1:2222 SSH banner..."
python3 - << 'PYEOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(("127.0.0.1", 2222))
    banner = s.recv(64).decode("utf-8", errors="replace").strip()
    print(f"    [PASS] 127.0.0.1:2222 responded with banner: {banner}")
except Exception as e:
    print(f"    [FAIL] Cannot connect to 127.0.0.1:2222: {e}", file=sys.stderr)
    print("           Ensure the krunvm VM is running and setup_vscode.sh was executed.", file=sys.stderr)
    sys.exit(1)
finally:
    s.close()
PYEOF

# ------------------------------------------------------------------------------
# Test 2: Passwordless SSH Key Authentication
# ------------------------------------------------------------------------------
echo "==> [Test 2/5] Testing passwordless SSH login ('ssh ${HOST_ALIAS}')..."
if REMOTE_OUT="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${HOST_ALIAS}" "uname -a && id" 2>&1)"; then
    echo "    [PASS] Authenticated successfully:"
    echo "           ${REMOTE_OUT}" | head -n 2
else
    echo "    [FAIL] Passwordless SSH failed:" >&2
    echo "${REMOTE_OUT}" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Test 3: Remote PTY Allocation (Required for VS Code Integrated Terminal)
# ------------------------------------------------------------------------------
echo "==> [Test 3/5] Testing remote PTY allocation ('ssh -tt ${HOST_ALIAS}')..."
if PTY_OUT="$(ssh -tt -o BatchMode=yes -o LogLevel=QUIET "${HOST_ALIAS}" "tty && exit" 2>&1)"; then
    PTY_CLEAN="$(echo "${PTY_OUT}" | tr -d '\r' | head -n 1)"
    echo "    [PASS] Remote PTY allocated: ${PTY_CLEAN}"
else
    echo "    [FAIL] Remote PTY allocation failed!" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Test 4: SSH Local TCP Port Forwarding (-L) to Ephemeral port=0 Server in VM
#   This reproduces the exact mechanism VS Code uses when starting
#   `code-server --host=127.0.0.1 --port=0` and forwarding a local port to it.
# ------------------------------------------------------------------------------
echo "==> [Test 4/5] Testing SSH TCP forwarding (-L) to ephemeral port=0 inside VM..."
REMOTE_PORT="$(ssh "${HOST_ALIAS}" 'python3 -c "
import socket, time, os, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind((\"127.0.0.1\", 0))
s.listen(1)
port = s.getsockname()[1]
print(port, flush=True)
sys.stdout.flush()
sys.stderr.flush()
pid = os.fork()
if pid == 0:
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    os.close(devnull)
    s.settimeout(15)
    try:
        conn, _ = s.accept()
        conn.sendall(b\"VSCODE_TCP_FORWARD_OK\\n\")
        conn.close()
    except Exception:
        pass
    finally:
        s.close()
    os._exit(0)
os._exit(0)
"' | tr -d '\r\n')"

echo "    VM ephemeral server listening on 127.0.0.1:${REMOTE_PORT}; forwarding from Host PC..."
LOCAL_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

ssh -f -N -o ExitOnForwardFailure=yes -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" "${HOST_ALIAS}"
FWD_PID="$(pgrep -n -f "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" || true)"

FORWARD_RESULT="$(python3 - "${LOCAL_PORT}" << 'PYEOF'
import socket, sys
port = int(sys.argv[1])
c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
c.settimeout(4)
c.connect(("127.0.0.1", port))
data = c.recv(64).decode("utf-8", errors="replace").strip()
c.close()
print(data)
PYEOF
)"

[ -n "${FWD_PID}" ] && kill "${FWD_PID}" 2>/dev/null || true

if [ "${FORWARD_RESULT}" = "VSCODE_TCP_FORWARD_OK" ]; then
    echo "    [PASS] End-to-End SSH TCP forwarding succeeded (${FORWARD_RESULT})."
else
    echo "    [FAIL] End-to-End SSH TCP forwarding failed (got: '${FORWARD_RESULT}')." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Test 5: SSH Unix Domain Socket Forwarding (StreamLocalForward)
#   This tests the path used when `"remote.SSH.remoteServerListenOnSocket": true`.
# ------------------------------------------------------------------------------
echo "==> [Test 5/5] Testing SSH Unix Socket forwarding (StreamLocalForward)..."
REMOTE_SOCK="/tmp/vscode_test_$$.sock"
LOCAL_SOCK_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

ssh "${HOST_ALIAS}" "python3 -c '
import socket, os, sys
sock_path = \"${REMOTE_SOCK}\"
if os.path.exists(sock_path): os.unlink(sock_path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path)
s.listen(1)
pid = os.fork()
if pid == 0:
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    os.close(devnull)
    s.settimeout(15)
    try:
        conn, _ = s.accept()
        conn.sendall(b\"VSCODE_UNIX_SOCKET_OK\\n\")
        conn.close()
    except Exception:
        pass
    finally:
        s.close()
        if os.path.exists(sock_path): os.unlink(sock_path)
    os._exit(0)
os._exit(0)
'"

ssh -f -N -o ExitOnForwardFailure=yes -L "127.0.0.1:${LOCAL_SOCK_PORT}:${REMOTE_SOCK}" "${HOST_ALIAS}"
SOCK_FWD_PID="$(pgrep -n -f "127.0.0.1:${LOCAL_SOCK_PORT}:${REMOTE_SOCK}" || true)"

UNIX_RESULT="$(python3 - "${LOCAL_SOCK_PORT}" << 'PYEOF'
import socket, sys
port = int(sys.argv[1])
c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
c.settimeout(4)
c.connect(("127.0.0.1", port))
data = c.recv(64).decode("utf-8", errors="replace").strip()
c.close()
print(data)
PYEOF
)"

[ -n "${SOCK_FWD_PID}" ] && kill "${SOCK_FWD_PID}" 2>/dev/null || true

if [ "${UNIX_RESULT}" = "VSCODE_UNIX_SOCKET_OK" ]; then
    echo "    [PASS] End-to-End SSH Unix Socket forwarding succeeded (${UNIX_RESULT})."
else
    echo "    [FAIL] End-to-End SSH Unix Socket forwarding failed (got: '${UNIX_RESULT}')." >&2
    exit 1
fi

echo ""
echo "=================================================================="
echo " [ALL 5 TESTS PASSED] krun-act-runner is 100% ready for VS Code!"
echo "=================================================================="

if [ "${LAUNCH_VSCODE}" = true ]; then
    if command -v code >/dev/null 2>&1; then
        echo "Launching VS Code connected to ${HOST_ALIAS}..."
        code --remote "ssh-remote+${HOST_ALIAS}" /shared_dir_host_vm
    else
        echo "[WARN] 'code' CLI not found in PATH; open VS Code manually and connect to ${HOST_ALIAS}."
    fi
else
    echo "To launch VS Code directly from terminal, run:"
    echo "  code --remote ssh-remote+${HOST_ALIAS} /shared_dir_host_vm"
fi
