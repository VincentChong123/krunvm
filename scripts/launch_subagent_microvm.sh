#!/usr/bin/env bash
# ==============================================================================
# launch_subagent_microvm.sh - Instantaneous (<100ms) Ephemeral MicroVM Subagent Launcher
# Runs disposable YOLO-mode agent tasks in isolated microVMs without host pollution.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment configuration if available
ENV_FILE="${REPO_ROOT}/.env.host"
[[ -f "$ENV_FILE" ]] || ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
fi

OCI_IMAGE="${OCI_BASE_IMAGE:-localhost/krun-agent-sandbox:latest}"
SUBAGENT_CPUS="${EPHEMERAL_CPUS:-2}"
SUBAGENT_MEM="${EPHEMERAL_MEMORY:-2048}"
KRUNVM_EXEC="$(command -v krunvm 2>/dev/null || echo "${HOME}/.local/bin/krunvm")"

if [[ ! -x "$KRUNVM_EXEC" ]]; then
    echo "[ERROR] krunvm executable not found at '$KRUNVM_EXEC'." >&2
    exit 1
fi

SUBAGENT_ID="subagent-$(date +%s)-$RANDOM"
SCRATCH_DIR="${1:-${REPO_ROOT}/scratch/${SUBAGENT_ID}}"
mkdir -p "$SCRATCH_DIR"

shift 1 2>/dev/null || true
SUBAGENT_CMD=("${@:-/bin/bash}")

echo "==> [Ephemeral MicroVM] Spawning subagent sandbox '$SUBAGENT_ID'..."
echo "    CPUs: $SUBAGENT_CPUS | RAM: ${SUBAGENT_MEM}MB | Image: $OCI_IMAGE"
echo "    Scratch Mount: $SCRATCH_DIR -> /workspace"

# Cleanup trap ensures the microVM is destroyed upon command completion or failure
cleanup() {
    echo "==> [Ephemeral MicroVM] Tearing down disposable subagent '$SUBAGENT_ID'..."
    "$KRUNVM_EXEC" delete "$SUBAGENT_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Create the ephemeral microVM with strict isolation (single-depth guest path /workspace)
"$KRUNVM_EXEC" create \
    --name "$SUBAGENT_ID" \
    --cpus "$SUBAGENT_CPUS" \
    --mem "$SUBAGENT_MEM" \
    --workdir "/workspace" \
    -v "$SCRATCH_DIR:/workspace" \
    "$OCI_IMAGE"

echo "==> [Ephemeral MicroVM] Starting subagent execution in YOLO mode..."
if [[ ${#SUBAGENT_CMD[@]} -eq 1 ]]; then
    "$KRUNVM_EXEC" start "$SUBAGENT_ID" "${SUBAGENT_CMD[0]}"
else
    cmd="${SUBAGENT_CMD[0]}"
    args=("${SUBAGENT_CMD[@]:1}")
    "$KRUNVM_EXEC" start "$SUBAGENT_ID" "$cmd" -- "${args[@]}"
fi
