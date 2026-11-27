#!/usr/bin/env bash
# ==============================================================================
# watch_vms.sh - Watch running krunvm VM count and warn if more than MAX_VMS
#
# Usage:
#   ./scripts/watch_vms.sh                  # Poll every 30s, warn if > 1 VM
#   ./scripts/watch_vms.sh -i 10 -m 1       # Poll every 10s, warn if > 1 VM
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL=30
MAX_VMS=1

while getopts ":i:m:h" opt; do
    case "$opt" in
        i) INTERVAL="$OPTARG" ;;
        m) MAX_VMS="$OPTARG" ;;
        h)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        *)
            echo "Usage: $0 [-i interval_seconds] [-m max_vms]" >&2
            exit 1
            ;;
    esac
done

echo "==> Watching krunvm VMs every ${INTERVAL}s (warning threshold: > ${MAX_VMS} running VM)..."
while true; do
    count="$("${SCRIPT_DIR}/list_vms.sh" --count)"
    if [[ "$count" -gt "$MAX_VMS" ]]; then
        msg="[WARNING $(date '+%H:%M:%S')] ${count} krunvm VMs are running (limit: ${MAX_VMS})!"
        echo "$msg" >&2
        "${SCRIPT_DIR}/list_vms.sh" --running >&2
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -u critical "krunvm VM Warning" "${count} krunvm VMs running (limit: ${MAX_VMS}). Check host RAM!" || true
        fi
    fi
    sleep "$INTERVAL"
done
