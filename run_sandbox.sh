#!/usr/bin/env bash
# ==============================================================================
# run_sandbox.sh - Fast interactive launcher for the Persistent krunvm Sandbox
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.host"
[[ -f "$ENV_FILE" ]] || ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
fi

VM_NAME="${VM_NAME:-krun-agent-persistent}"
KRUNVM_EXEC="${KRUNVM_BIN:-$(command -v krunvm 2>/dev/null || echo "${HOME}/.local/bin/krunvm")}"

if [[ ! -x "$KRUNVM_EXEC" ]]; then
    echo "[ERROR] krunvm executable not found at '$KRUNVM_EXEC'." >&2
    echo "        Run ./setup.sh or ./scripts/build_krunvm_host.sh first." >&2
    exit 1
fi

echo "==> Starting persistent microVM '$VM_NAME' in YOLO mode..."
if [[ $# -eq 0 ]]; then
    exec "$KRUNVM_EXEC" start "$VM_NAME" /bin/bash
elif [[ $# -eq 1 ]]; then
    exec "$KRUNVM_EXEC" start "$VM_NAME" "$1"
else
    cmd="$1"
    shift
    exec "$KRUNVM_EXEC" start "$VM_NAME" "$cmd" -- "$@"
fi
