#!/usr/bin/env bash
# ==============================================================================
# start_daemon.sh - Headless Daemon Launcher for krun-act-runner MicroVM
# ==============================================================================
# 1. Ensures SSH daemon and AF_TSI port-forwarding fixes are active.
# 2. Synchronizes dotfiles from the read-only host mount (/dotfiles).
# 3. Keeps the microVM alive for SSH / VS Code Remote-SSH sessions.
# ==============================================================================

set -e

# Start SSH daemon
if [ -x /shared_dir_host_vm/ssh/ensure-sshd.sh ]; then
    /shared_dir_host_vm/ssh/ensure-sshd.sh
fi

# Apply dotfiles if mount is present
if [ -x /shared_dir_host_vm/scripts/apply_dotfiles.sh ]; then
    /shared_dir_host_vm/scripts/apply_dotfiles.sh || true
fi

# Mirror workspace paths
if [ -x /shared_dir_host_vm/scripts/link_vm_workspace.sh ]; then
    /shared_dir_host_vm/scripts/link_vm_workspace.sh || true
fi

echo "[krunvm daemon] Ready for SSH and VS Code Remote-SSH connections on port 2222."
exec sleep infinity
