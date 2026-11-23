#!/usr/bin/env bash
# ==============================================================================
# run_act_vm.sh - Execute GitHub Actions CI locally inside krunvm MicroVM
# Respective Purpose: act CI runner execution
# Delegates to run_sandbox.sh as the underlying launcher engine.
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
REPO_ROOT="$SCRIPT_DIR"
while [[ "$REPO_ROOT" != "/" && ! -f "$REPO_ROOT/setup.sh" && ! -d "$REPO_ROOT/.git" && ! -f "$REPO_ROOT/.env" && ! -f "$REPO_ROOT/.env.act" ]]; do
    REPO_ROOT="$(dirname "$REPO_ROOT")"
done
if [[ ! -f "$REPO_ROOT/setup.sh" && ! -d "$REPO_ROOT/.git" && ! -f "$REPO_ROOT/.env" && ! -f "$REPO_ROOT/.env.act" ]]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Delegate execution directly to run_sandbox.sh targeting the act profile
if [[ "${1:-}" == "shell" ]]; then
    shift
    exec "${REPO_ROOT}/run_sandbox.sh" --env "${REPO_ROOT}/.env.act" shell "$@"
else
    exec "${REPO_ROOT}/run_sandbox.sh" --env "${REPO_ROOT}/.env.act" act "$@"
fi
