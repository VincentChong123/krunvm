#!/usr/bin/env bash
# ==============================================================================
# setup_host_vscode_ssh.sh - Configure Host PC for VS Code Remote-SSH to krunvm
#
# LOCATION ON HOST PC:
#   shared_dir_host_vm/vm2host/setup_host_vscode_ssh.sh
#
# PURPOSE:
#   This script MUST be executed on the Host PC (NOT inside the krunvm VM).
#   It prepares the Host PC's OpenSSH client and VS Code settings so VS Code
#   Remote-SSH can connect reliably to the krunvm MicroVM ("krun-act-runner"):
#
#   1. Verifies that this script is running on the Host PC (not inside the VM).
#   2. Ensures ~/.ssh/id_ed25519 keypair exists and exports id_ed25519.pub into
#      the shared vm2host folder so the VM can authorize it automatically.
#   3. Configures Host krun-act-runner in ~/.ssh/config (backing up first) with
#      keep-alive, non-multiplexed forwarding, and host-key-checking disabled
#      for ephemeral VM host keys.
#   4. Updates VS Code's ~/.config/Code/User/settings.json (backing up first)
#      to set remote.SSH.RemotePlatform, remote.SSH.connectTimeout, and
#      remote.SSH.remoteServerListenOnSocket.
#   5. Terminates any stale local VS Code SSH port-forwarding processes that
#      were stuck from previous failed connection attempts.
# ==============================================================================
set -euo pipefail

# Determine the directory where this script resides on the Host PC
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=================================================================="
echo " Host PC Setup for krunvm VS Code Remote-SSH (krun-act-runner)"
echo "=================================================================="

# ------------------------------------------------------------------------------
# Step 1: Safety check - Ensure this script is run on the Host PC, not in the VM
# ------------------------------------------------------------------------------
if [ -f /init.krun ] || grep -q "tsi_hijack" /proc/cmdline 2>/dev/null; then
    echo "[ERROR] Detected krunvm guest environment (/init.krun or tsi_hijack)." >&2
    echo "        Please run this script on your Host PC at:" >&2
    echo "        ./shared_dir_host_vm/vm2host/setup_host_vscode_ssh.sh" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 2: Ensure SSH keypair exists & export public key to shared directory
# ------------------------------------------------------------------------------
echo "==> [1/5] Checking Host PC SSH keypair (~/.ssh/id_ed25519)..."
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [ ! -f "${HOME}/.ssh/id_ed25519" ]; then
    echo "    Generating new Ed25519 SSH key at ${HOME}/.ssh/id_ed25519..."
    ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519"
else
    echo "    [OK] Found existing key: ${HOME}/.ssh/id_ed25519"
fi

chmod 600 "${HOME}/.ssh/id_ed25519"
chmod 644 "${HOME}/.ssh/id_ed25519.pub"

# Copy public key into vm2host so the VM can read it from /shared_dir_host_vm/vm2host/id_ed25519.pub
cp -f "${HOME}/.ssh/id_ed25519.pub" "${SCRIPT_DIR}/id_ed25519.pub"
echo "    [OK] Exported public key to ${SCRIPT_DIR}/id_ed25519.pub"

# ------------------------------------------------------------------------------
# Step 3: Ensure Host krun-act-runner is properly configured in ~/.ssh/config
# ------------------------------------------------------------------------------
echo "==> [2/5] Verifying ~/.ssh/config entry for 'Host krun-act-runner'..."
SSH_CONFIG="${HOME}/.ssh/config"
touch "${SSH_CONFIG}"
chmod 600 "${SSH_CONFIG}"

# Back up ~/.ssh/config before making any changes
cp -f "${SSH_CONFIG}" "${SSH_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"

# Use Python to cleanly update or append the `Host krun-act-runner` block
# while preserving all other Host entries in ~/.ssh/config.
python3 - "${SSH_CONFIG}" << 'PYEOF'
import re
import sys

config_path = sys.argv[1]
with open(config_path, "r", encoding="utf-8") as f:
    content = f.read()

desired_block = """Host krun-act-runner
    HostName 127.0.0.1
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ControlMaster no
    ServerAliveInterval 15
    ServerAliveCountMax 6
    ExitOnForwardFailure no
"""

# Match an existing `Host krun-act-runner` block up to the next `Host ` or EOF
pattern = re.compile(
    r"(?m)^Host\s+krun-act-runner\s*$\n(?:^(?!Host\s).*\n?)*"
)

if pattern.search(content):
    new_content = pattern.sub(desired_block + "\n", content, count=1)
    action = "Updated existing"
else:
    sep = "\n" if content and not content.endswith("\n") else ""
    new_content = content + sep + "\n" + desired_block
    action = "Appended new"

with open(config_path, "w", encoding="utf-8") as f:
    f.write(new_content)

print(f"    [OK] {action} 'Host krun-act-runner' block in {config_path}.")
PYEOF

chmod 600 "${SSH_CONFIG}"

# ------------------------------------------------------------------------------
# Step 4: Configure VS Code User settings.json for krunvm Remote-SSH
# Supports both native VS Code and Fedora Flatpak (com.visualstudio.code)
# ------------------------------------------------------------------------------
echo "==> [3/5] Updating VS Code settings..."
TARGET_SETTINGS_DIRS=(
    "${HOME}/.config/Code/User"
    "${HOME}/.var/app/com.visualstudio.code/config/Code/User"
)

for VSCODE_SETTINGS_DIR in "${TARGET_SETTINGS_DIRS[@]}"; do
    if [ -d "$(dirname "${VSCODE_SETTINGS_DIR}")" ] || [ -d "${VSCODE_SETTINGS_DIR}" ]; then
        mkdir -p "${VSCODE_SETTINGS_DIR}"
        VSCODE_SETTINGS_FILE="${VSCODE_SETTINGS_DIR}/settings.json"

        if [ -f "${VSCODE_SETTINGS_FILE}" ]; then
            cp -f "${VSCODE_SETTINGS_FILE}" "${VSCODE_SETTINGS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        fi

        python3 - "${VSCODE_SETTINGS_FILE}" << 'PYEOF'
import json
import os
import re
import sys

settings_path = sys.argv[1]
data = {}

if os.path.exists(settings_path) and os.path.getsize(settings_path) > 0:
    with open(settings_path, "r", encoding="utf-8") as f:
        raw = f.read()
    try:
        data = json.loads(raw)
    except Exception:
        cleaned = re.sub(r"(?m)^\s*//.*$", "", raw)
        cleaned = re.sub(r",(\s*[}\]])", r"\1", cleaned)
        try:
            data = json.loads(cleaned)
        except Exception as e:
            print(f"    [WARN] Could not parse existing {settings_path} ({e}); leaving file untouched.")
            sys.exit(0)

remote_platforms = data.get("remote.SSH.remotePlatform")
if not isinstance(remote_platforms, dict):
    remote_platforms = {}
remote_platforms["krun-act-runner"] = "linux"
data["remote.SSH.remotePlatform"] = remote_platforms

data["remote.SSH.remoteServerListenOnSocket"] = True
data["remote.SSH.connectTimeout"] = 60
data["remote.SSH.useExecServer"] = False

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4)
    f.write("\n")

print(f"    [OK] Updated VS Code Remote-SSH settings in {settings_path}.")
PYEOF
    fi
done

# ------------------------------------------------------------------------------
# Step 5: Clean up any stale local SSH mux/forwarding processes to 127.0.0.1:2222
# ------------------------------------------------------------------------------
echo "==> [4/5] Cleaning up stale Host PC SSH forwarding processes for port 2222..."
STALE_SSH_PIDS="$(pgrep -f "ssh.*(krun-act-runner|2222)" || true)"
if [ -n "${STALE_SSH_PIDS}" ]; then
    echo "    Killing stale SSH processes: $(echo "${STALE_SSH_PIDS}" | tr '\n' ' ')"
    kill -9 ${STALE_SSH_PIDS} 2>/dev/null || true
else
    echo "    [OK] No stale SSH client processes found."
fi

# ------------------------------------------------------------------------------
# Step 6: Sync authorized_keys & trigger VM setup over SSH if VM is reachable
# ------------------------------------------------------------------------------
echo "==> [5/5] Verifying SSH connection to krun-act-runner (127.0.0.1:2222)..."
if ssh -o ConnectTimeout=5 -o BatchMode=yes krun-act-runner "echo '    [OK] Connected to VM over SSH!'" 2>/dev/null; then
    ssh krun-act-runner "/shared_dir_host_vm/ssh/check_vscode_health.sh" || true
else
    echo "    [INFO] Could not connect via passwordless SSH yet."
    echo "           Make sure inside the krunvm VM you have run:"
    echo "           /shared_dir_host_vm/ssh/setup_vscode.sh"
fi

echo ""
echo "=================================================================="
echo " [SUCCESS] Host PC configuration complete!"
echo " Next: Run ${SCRIPT_DIR}/test_host_to_vm_ssh.sh"
echo "=================================================================="
