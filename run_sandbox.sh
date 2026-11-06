#!/usr/bin/env bash
# ==============================================================================
# run_sandbox.sh - Fast interactive launcher for the Persistent krunvm Sandbox
# Supports hierarchical .env.host / .env loading and enforces read-only volumes.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.host"
[[ -f "$ENV_FILE" ]] || ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
fi

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

VM_NAME="${VM_NAME:-krun-agent-persistent}"
USE_ZELLIJ="${USE_ZELLIJ:-false}"

# Robust binary candidate resolution across host users
KRUNVM_EXEC="${KRUNVM_BIN:-}"
if [[ -z "$KRUNVM_EXEC" ]]; then
    for candidate in \
        "$(command -v krunvm 2>/dev/null || true)" \
        "/usr/local/bin/krunvm" \
        "/home/vin/.local/bin/krunvm" \
        "${HOME}/.local/bin/krunvm"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            KRUNVM_EXEC="$candidate"
            break
        fi
    done
fi

if [[ ! -x "$KRUNVM_EXEC" ]]; then
    echo "[ERROR] krunvm executable not found at '$KRUNVM_EXEC'." >&2
    echo "        Run ./setup.sh or ./scripts/build_krunvm_host.sh first." >&2
    exit 1
fi

GUEST_USER="${VM_USER:-sandbox-runner}"

# Verify the VM exists for the current execution user
if ! "$KRUNVM_EXEC" list 2>/dev/null | grep -q "^${VM_NAME}[[:space:]]*$"; then
    echo "[ERROR] microVM '$VM_NAME' not found for host user '$(id -un)'." >&2
    echo "        Please run './setup.sh --as-runner' first to create and provision it." >&2
    exit 1
fi

echo "==> Starting persistent microVM '$VM_NAME' (user: $GUEST_USER, zellij: $USE_ZELLIJ)..."
exec "$KRUNVM_EXEC" start "$VM_NAME" -- /bin/bash /krunvm/scripts/guest_dispatch.sh "$@"
