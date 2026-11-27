#!/usr/bin/env bash
# ==============================================================================
# list_vms.sh - List running and configured krunvm microVMs with lifecycle info
# Shows: PID, user, VM name, RSS memory, start time, uptime, and last access.
#
# Usage:
#   ./scripts/list_vms.sh              # Full table (running + configured)
#   ./scripts/list_vms.sh --running    # Only running VMs
#   ./scripts/list_vms.sh --count      # Print number of running VMs and exit
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_DIR}/logs"

MODE="all"
case "${1:-}" in
    --running) MODE="running" ;;
    --count)   MODE="count" ;;
    --help|-h)
        sed -n '2,10p' "$0"
        exit 0
        ;;
esac

# Find running krunvm / libkrun VM processes.
# Matches either comm == "libkrun VM" or cmdline containing "krunvm start".
get_running_vm_pids() {
    ps -eo pid=,comm=,args= 2>/dev/null | awk '
        $2 == "libkrun" || $0 ~ /libkrun VM/ || $0 ~ /(^|\/)krunvm[[:space:]]+start([[:space:]]|$)/ {
            if ($0 !~ /awk|list_vms\.sh|watch_vms\.sh/) print $1
        }
    ' | sort -u
}

extract_vm_name() {
    local pid="$1"
    local cmdline
    cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
    if [[ "$cmdline" =~ krunvm[[:space:]]+start[[:space:]]+([^[:space:]]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

get_last_access() {
    local pid="$1"
    local fd1_target=""
    fd1_target="$(readlink -f "/proc/${pid}/fd/1" 2>/dev/null || true)"
    if [[ -n "$fd1_target" && -f "$fd1_target" ]]; then
        stat -c '%y' "$fd1_target" 2>/dev/null | cut -d'.' -f1
        return
    fi
    if [[ -n "$fd1_target" && "$fd1_target" == /dev/pts/* ]]; then
        local pts_mtime
        pts_mtime="$(stat -c '%y' "$fd1_target" 2>/dev/null | cut -d'.' -f1 || true)"
        echo "${pts_mtime:-active (tty)} (tty)"
        return
    fi
    echo "unknown"
}

mapfile -t RUNNING_PIDS < <(get_running_vm_pids)
RUNNING_COUNT="${#RUNNING_PIDS[@]}"

if [[ "$MODE" == "count" ]]; then
    echo "$RUNNING_COUNT"
    exit 0
fi

declare -A RUNNING_NAMES=()

echo "=== Running krunvm VMs (${RUNNING_COUNT}) ==="
if [[ "$RUNNING_COUNT" -eq 0 ]]; then
    echo "  (none)"
else
    printf "%-8s %-12s %-20s %-9s %-24s %-12s %-22s\n" \
        "PID" "USER" "VM_NAME" "RSS(MiB)" "STARTED" "UPTIME" "LAST_ACCESS"
    printf "%-8s %-12s %-20s %-9s %-24s %-12s %-22s\n" \
        "--------" "------------" "--------------------" "---------" "------------------------" "------------" "----------------------"

    for pid in "${RUNNING_PIDS[@]}"; do
        [[ -d "/proc/${pid}" ]] || continue
        user="$(ps -p "$pid" -o user= 2>/dev/null | xargs || echo "?")"
        rss_kb="$(ps -p "$pid" -o rss= 2>/dev/null | xargs || echo "0")"
        rss_mb="$(( rss_kb / 1024 ))"
        started="$(ps -p "$pid" -o lstart= 2>/dev/null | xargs || echo "?")"
        uptime="$(ps -p "$pid" -o etime= 2>/dev/null | xargs || echo "?")"
        vm_name="$(extract_vm_name "$pid")"
        last_access="$(get_last_access "$pid")"
        RUNNING_NAMES["$vm_name"]=1

        printf "%-8s %-12s %-20s %-9s %-24s %-12s %-22s\n" \
            "$pid" "$user" "$vm_name" "${rss_mb}MiB" "$started" "$uptime" "$last_access"
    done

    if [[ "$RUNNING_COUNT" -gt 1 ]]; then
        echo ""
        echo "[WARNING] ${RUNNING_COUNT} krunvm VMs are running simultaneously! This may cause host OOM/swap thrashing." >&2
    fi
fi

if [[ "$MODE" == "running" ]]; then
    exit 0
fi

echo ""
echo "=== Configured krunvm VMs ==="
KRUNVM_EXEC="${KRUNVM_BIN:-$(command -v krunvm 2>/dev/null || echo /usr/local/bin/krunvm)}"
if [[ -x "$KRUNVM_EXEC" ]]; then
    LATEST_LOG_TIME="n/a"
    if [[ -d "$LOG_DIR" ]]; then
        latest_log="$(ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -n 1 || true)"
        if [[ -n "$latest_log" ]]; then
            LATEST_LOG_TIME="$(stat -c '%y' "$latest_log" 2>/dev/null | cut -d'.' -f1 || echo "n/a")"
        fi
    fi

    printf "%-24s %-6s %-10s %-10s %-22s\n" "VM_NAME" "CPUS" "RAM(MiB)" "STATE" "LAST_LOG_ACCESS"
    printf "%-24s %-6s %-10s %-10s %-22s\n" "------------------------" "------" "----------" "----------" "----------------------"

    vm=""
    cpus=""
    ram=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[^[:space:]] ]]; then
            if [[ -n "$vm" ]]; then
                state="STOPPED"
                [[ -n "${RUNNING_NAMES[$vm]:-}" ]] && state="RUNNING"
                printf "%-24s %-6s %-10s %-10s %-22s\n" "$vm" "${cpus:-?}" "${ram:-?}" "$state" "$LATEST_LOG_TIME"
            fi
            vm="$(echo "$line" | xargs)"
            cpus=""
            ram=""
        elif [[ "$line" =~ CPUs:[[:space:]]*([0-9]+) ]]; then
            cpus="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ RAM[[:space:]]*\(MiB\):[[:space:]]*([0-9]+) ]]; then
            ram="${BASH_REMATCH[1]}"
        fi
    done < <("$KRUNVM_EXEC" list 2>/dev/null || true)

    if [[ -n "$vm" ]]; then
        state="STOPPED"
        [[ -n "${RUNNING_NAMES[$vm]:-}" ]] && state="RUNNING"
        printf "%-24s %-6s %-10s %-10s %-22s\n" "$vm" "${cpus:-?}" "${ram:-?}" "$state" "$LATEST_LOG_TIME"
    fi
else
    echo "  (krunvm binary not found)"
fi
