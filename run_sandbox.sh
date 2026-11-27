#!/usr/bin/env bash
# ==============================================================================
# run_sandbox.sh - Fast interactive launcher for the Persistent krunvm Sandbox
# Single Source of Truth for launching microVM sessions.
# Supports hierarchical config loading (.env / .env.act / .env.host),
# clear config override logging, and execution modes (shell, act, exec).
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

# Determine execution mode
MODE="${1:-}"

if [[ "$MODE" == "shell" ]]; then
    shift
    echo "==> Opening interactive shell in microVM '$VM_NAME'..."
    exec "$KRUNVM_EXEC" start "$VM_NAME" /usr/bin/env TERM="${TERM:-xterm-256color}" COLORTERM="${COLORTERM:-truecolor}" /bin/bash --login -i "$@"
elif [[ "$MODE" == "daemon" ]]; then
    shift
    echo "==> Starting microVM '$VM_NAME' in headless daemon mode (SSH / VS Code)..."
    exec "$KRUNVM_EXEC" start "$VM_NAME" /shared_dir_host_vm/scripts/start_daemon.sh "$@"
elif [[ "$MODE" == "act" ]]; then
    shift
    echo "==> Executing GitHub Actions (act) runner inside microVM '$VM_NAME'..."
    VM_COMMAND='command -v ensure-dockerd.sh >/dev/null 2>&1 && sudo ensure-dockerd.sh || ( pgrep -x dockerd >/dev/null 2>&1 || ( [ -f /etc/docker/daemon.json ] && grep -q overlay2 /etc/docker/daemon.json || sudo sh -c "echo '\''{\"iptables\":false,\"ip6tables\":false,\"storage-driver\":\"overlay2\"}'\'' > /etc/docker/daemon.json" && sudo dockerd >/var/log/dockerd.log 2>&1 & sleep 2 ) ); cd /workspace && exec act workflow_dispatch -W /workspace/.github/workflows/ci.yml -P ubuntu-latest=-self-hosted --env ACT=true "$@"'
    exec "$KRUNVM_EXEC" start "$VM_NAME" /bin/bash -- -c "$VM_COMMAND" bash "$@"
elif [[ "$MODE" == "exec" ]]; then
    shift
    echo "==> Executing command in microVM '$VM_NAME': $*"
    exec "$KRUNVM_EXEC" start "$VM_NAME" /bin/bash -- -c "$*"
else
    # Default execution: guest dispatch if /krunvm is mounted, otherwise interactive shell
    if "$KRUNVM_EXEC" list 2>/dev/null | grep -q '": "/krunvm"'; then
        echo "==> Starting microVM '$VM_NAME' with guest dispatch (user: $GUEST_USER, zellij: $USE_ZELLIJ)..."
        exec "$KRUNVM_EXEC" start "$VM_NAME" /bin/bash -- /krunvm/scripts/guest_dispatch.sh "$@"
    else
        echo "==> Starting microVM '$VM_NAME' interactive shell..."
        exec "$KRUNVM_EXEC" start "$VM_NAME" /usr/bin/env TERM="${TERM:-xterm-256color}" COLORTERM="${COLORTERM:-truecolor}" /bin/bash --login -i "$@"
    fi
fi
