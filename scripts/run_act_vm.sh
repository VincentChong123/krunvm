#!/usr/bin/env bash
# ==============================================================================
# run_act_vm.sh - Execute GitHub Actions CI locally inside krunvm MicroVM
# Provides 1:1 parity with github.com Ubuntu runner environment.
#
# Usage:
#   ./scripts/run_act_vm.sh                               # Run full workflow
#   ./scripts/run_act_vm.sh -j lint-commits               # Run commitlint job
#   ./scripts/run_act_vm.sh -j test-langfuse-stack        # Run Langfuse smoke test
#   ./scripts/run_act_vm.sh -j test-hyperdx-stack         # Run HyperDX + Grafana smoke test
#   ./scripts/run_act_vm.sh -n                            # Dry-run workflow syntax
#   ./scripts/run_act_vm.sh shell                         # Open interactive shell in VM
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env.act}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] Environment config file '$ENV_FILE' not found." >&2
    echo "        Copy .env.act.example to .env.act and adjust paths: cp .env.act.example .env.act" >&2
    exit 1
fi

# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

VM_NAME="${VM_NAME:-krun-act-runner}"
KRUNVM_EXEC="${KRUNVM_BIN:-$(command -v krunvm 2>/dev/null || echo "${HOME}/.local/bin/krunvm")}"

if [[ ! -x "$KRUNVM_EXEC" ]]; then
    echo "[ERROR] 'krunvm' executable not found at '$KRUNVM_EXEC'." >&2
    echo "        Build or install krunvm first: bash scripts/build_krunvm_host.sh" >&2
    exit 1
fi

# Verify the VM exists in krunvm
if ! "$KRUNVM_EXEC" list 2>/dev/null | grep -q "^${VM_NAME}[[:space:]]*$"; then
    echo "[ERROR] MicroVM '$VM_NAME' does not exist." >&2
    echo "        Provision it first by running: ENV_FILE=.env.act ./setup.sh" >&2
    exit 1
fi

echo "=========================================================================="
echo " krunvm MicroVM act CI Runner"
echo " MicroVM Instance: $VM_NAME"
echo " Workdir:          /workspace"
echo "=========================================================================="

if [[ "${1:-}" == "shell" ]]; then
    echo "==> Opening interactive shell in microVM '$VM_NAME'..."
    exec "$KRUNVM_EXEC" start "$VM_NAME" \
        --env TERM="${TERM:-xterm-256color}" \
        --env COLORTERM="${COLORTERM:-truecolor}" \
        /bin/bash --login -i
fi

# In-VM runner command:
# Note: Must be a single line because libkrun appends arguments to the Linux kernel cmdline.
VM_COMMAND='command -v ensure-dockerd.sh >/dev/null 2>&1 && sudo ensure-dockerd.sh || ( pgrep -x dockerd >/dev/null 2>&1 || ( [ -f /etc/docker/daemon.json ] && grep -q fuse-overlayfs /etc/docker/daemon.json || sudo sh -c "echo '\''{\"iptables\":false,\"ip6tables\":false,\"storage-driver\":\"fuse-overlayfs\"}'\'' > /etc/docker/daemon.json" && sudo dockerd >/var/log/dockerd.log 2>&1 & sleep 2 ) ); cd /workspace && exec act workflow_dispatch -W /workspace/.github/workflows/ci.yml -P ubuntu-latest=-self-hosted --env ACT=true "$@"'

exec "$KRUNVM_EXEC" start "$VM_NAME" /bin/bash -- -c "$VM_COMMAND" bash "$@"
