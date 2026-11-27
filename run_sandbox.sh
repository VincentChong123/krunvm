#!/usr/bin/env bash
# ==============================================================================
# run_sandbox.sh - Fast interactive launcher for the Persistent krunvm Sandbox
# Single Source of Truth for launching microVM sessions.
# Supports hierarchical config loading (.env / .env.act / .env.host),
# clear config override logging, and execution modes (shell, nektos_act, exec).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Source Single Source of Truth Configuration Loader
# shellcheck source=/dev/null
if [[ -f "${SCRIPT_DIR}/scripts/load_config.sh" ]]; then
    source "${SCRIPT_DIR}/scripts/load_config.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/shared_dir_host_vm/scripts/load_config.sh" ]]; then
    source "${SCRIPT_DIR}/shared_dir_host_vm/scripts/load_config.sh" "$@"
else
    echo "[ERROR] load_config.sh not found." >&2
    exit 1
fi
set -- "${_CLEANED_ARGS[@]}"

# Support running under dedicated sandbox user (e.g. sandbox-runner)
SANDBOX_HOST_USER="${SANDBOX_HOST_USER:-}"
if [[ "${1:-}" == "--as-runner" ]]; then
    SANDBOX_HOST_USER="sandbox-runner"
    shift
fi

if [[ -n "$SANDBOX_HOST_USER" ]] && [[ "$(id -un)" != "$SANDBOX_HOST_USER" ]]; then
    echo "==> Launching krunvm under isolated host user '$SANDBOX_HOST_USER'..."
    exec sudo -u "$SANDBOX_HOST_USER" -H "$0" "$@"
fi

USE_ZELLIJ="${USE_ZELLIJ:-false}"

# Robust binary candidate resolution across host users
KRUNVM_EXEC="${KRUNVM_BIN:-}"
if [[ -z "$KRUNVM_EXEC" ]]; then
    for candidate in \
        "$(command -v krunvm 2>/dev/null || true)" \
        "/usr/local/bin/krunvm" \
        "${HOME}/.local/bin/krunvm"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            KRUNVM_EXEC="$candidate"
            break
        fi
    done
fi

if [[ ! -x "$KRUNVM_EXEC" ]]; then
    echo "[ERROR] krunvm executable not found at '$KRUNVM_EXEC'." >&2
    echo "        Run ./setup.sh or ./shared_dir_host_vm/scripts/build_krunvm_host.sh first." >&2
    exit 1
fi

GUEST_USER="${VM_USER:-sandbox-runner}"

# Verify the VM exists for the current execution user
if ! "$KRUNVM_EXEC" list 2>/dev/null | grep -q "^${VM_NAME}[[:space:]]*$"; then
    echo "[ERROR] microVM '$VM_NAME' not found for host user '$(id -un)'." >&2
    echo "        Please run 'ENV_FILE=$ENV_FILE ./setup.sh' first to create and provision it." >&2
    exit 1
fi

# Warn if any krunvm VM is already running (prevents accidental multi-VM host OOM)
if [[ -x "${SCRIPT_DIR}/scripts/list_vms.sh" ]]; then
    EXISTING_VMS="$("${SCRIPT_DIR}/scripts/list_vms.sh" --count 2>/dev/null || echo 0)"
    if [[ "${EXISTING_VMS:-0}" -gt 0 ]]; then
        echo "" >&2
        echo "[WARNING] ${EXISTING_VMS} krunvm VM(s) already running! Running multiple VMs may exhaust host RAM." >&2
        "${SCRIPT_DIR}/scripts/list_vms.sh" --running >&2
        echo "" >&2
        if [[ -t 0 && "${FORCE_START:-false}" != "true" ]]; then
            read -r -p "Continue launching another VM ('$VM_NAME')? [y/N] " _reply
            if [[ ! "$_reply" =~ ^[Yy]$ ]]; then
                echo "==> Aborted." >&2
                exit 1
            fi
        fi
    fi
fi

# Determine execution mode (defaults to daemon when no mode is provided)
MODE="${1:-daemon}"
if [[ $# -gt 0 ]] && [[ "$MODE" == "shell" || "$MODE" == "daemon" || "$MODE" == "nektos_act" || "$MODE" == "exec" ]]; then
    shift
fi

if [[ "$MODE" == "shell" ]]; then
    echo "==> Opening interactive shell in microVM '$VM_NAME'..."
    exec "$KRUNVM_EXEC" start "$VM_NAME" /usr/bin/env -- TERM="${TERM:-xterm-256color}" COLORTERM="${COLORTERM:-truecolor}" /bin/bash --login -i "$@"
elif [[ "$MODE" == "daemon" ]]; then
    LOG_DIR="${SCRIPT_DIR}/logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/$(date +%Y-%m-%d-%H-%M-%S).log"
    echo "==> Starting microVM '$VM_NAME' in headless daemon mode (SSH / VS Code)..."
    echo "==> Logging to: $LOG_FILE"
    nohup "$KRUNVM_EXEC" start "$VM_NAME" /shared_dir_host_vm/scripts/start_daemon.sh "$@" >"$LOG_FILE" 2>&1 </dev/null &
    DAEMON_PID=$!
    disown "$DAEMON_PID" 2>/dev/null || true
    echo "==> Daemon started (PID: $DAEMON_PID). Press Ctrl+C or close terminal to detach; VM stays running."
    exec tail -f "$LOG_FILE"

elif [[ "$MODE" == "exec" ]]; then
    echo "==> Executing command in microVM '$VM_NAME': $*"
    exec "$KRUNVM_EXEC" start "$VM_NAME" /bin/bash -- -c "$*"
else
    # Default execution: guest dispatch if /krunvm is mounted, otherwise interactive shell
    if "$KRUNVM_EXEC" list 2>/dev/null | grep -q '": "/krunvm"'; then
        echo "==> Starting microVM '$VM_NAME' with guest dispatch (user: $GUEST_USER, zellij: $USE_ZELLIJ)..."
        exec "$KRUNVM_EXEC" start "$VM_NAME" /bin/bash -- /krunvm/scripts/guest_dispatch.sh "$@"
    else
        echo "==> Starting microVM '$VM_NAME' interactive shell..."
        exec "$KRUNVM_EXEC" start "$VM_NAME" /usr/bin/env -- TERM="${TERM:-xterm-256color}" COLORTERM="${COLORTERM:-truecolor}" /bin/bash --login -i "$@"
    fi
fi
