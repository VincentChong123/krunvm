#!/usr/bin/env bash
# ==============================================================================
# refresh_mounts.sh - Dynamic Volume Mount Synchronizer for krunvm
# ==============================================================================
# Reads .env.mapped_dir, safely checks if the microVM is actively running,
# gracefully stops it if needed, and applies updated mounts via `krunvm changevm`
# without wiping the VM's state, rootfs, or authentication tokens.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. Load Environment
ENV_FILE="${REPO_ROOT}/.env.host"
[[ -f "$ENV_FILE" ]] || ENV_FILE="${REPO_ROOT}/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
fi

VM_NAME="${VM_NAME:-krun-agent-persistent}"
MAPPED_DIR_FILE="${MAPPED_DIR_FILE:-${REPO_ROOT}/.env.mapped_dir}"
KRUNVM_BIN="${KRUNVM_BIN:-$(command -v krunvm 2>/dev/null || echo "${HOME}/.local/bin/krunvm")}"

if [[ ! -x "$KRUNVM_BIN" ]]; then
    echo "[ERROR] 'krunvm' executable not found at '$KRUNVM_BIN'." >&2
    exit 1
fi

echo "=========================================================================="
echo " krunvm Dynamic Volume Refresh Engine"
echo " VM Instance:    $VM_NAME"
echo " Mappings File:  $MAPPED_DIR_FILE"
echo "=========================================================================="

# 2. Parse & Validate Mappings
PARSED_MOUNTS=()
REAL_HOME="$(realpath "$HOME" 2>/dev/null || echo "$HOME")"

validate_and_add_mount() {
    local raw_token="$1"
    local source_name="$2"

    # Support ~/ shorthand for host home directory
    raw_token="${raw_token/#\~/$HOME}"

    # Expand environment variables safely if present
    local token
    eval "token=\"$raw_token\""

    if [[ "$token" =~ ^(/[^:]+):(/[^:]+)(:(ro|rw))?$ ]]; then
        local h_dir="${BASH_REMATCH[1]}"
        local v_dir="${BASH_REMATCH[2]}"
        local m_mode="${BASH_REMATCH[4]:-rw}"

        local trimmed_v="${v_dir#/}"
        if [[ "$trimmed_v" == *"/"* || -z "$trimmed_v" ]]; then
            echo "[ERROR] Invalid volume mapping '$token' in $source_name:" >&2
            echo "        krunvm requires guest_path to be a direct root child (e.g. /workspace, /scratch)." >&2
            exit 1
        fi

        local real_host_dir
        real_host_dir="$(realpath "$h_dir" 2>/dev/null || echo "$h_dir")"
        if [[ "$real_host_dir" == "/" || "$real_host_dir" == "/home" || "$real_host_dir" == "$REAL_HOME" ]]; then
            echo "[SECURITY ERROR] Refusing to mount host root or home directory ($real_host_dir)." >&2
            echo "                 Only dedicated project subfolders should be mounted." >&2
            exit 1
        fi

        if [[ ! -d "$h_dir" ]]; then
            echo "==> Creating missing host directory: $h_dir"
            mkdir -p "$h_dir" 2>/dev/null || true
        fi

        PARSED_MOUNTS+=("${h_dir}:${v_dir}:${m_mode}")
    else
        echo "[ERROR] Invalid volume mapping in $source_name: '$token'" >&2
        echo "        Expected syntax: <host_path>:<vm_path>[:ro|:rw]" >&2
        exit 1
    fi
}

if [[ -f "$MAPPED_DIR_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        line="${line#- }"
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        line="${line%\"}"
        line="${line#\"}"
        line="${line%\'}"
        line="${line#\'}"

        validate_and_add_mount "$line" ".env.mapped_dir"
    done < "$MAPPED_DIR_FILE"
fi

if [[ ${#PARSED_MOUNTS[@]} -eq 0 && -n "${VOLUMES:-}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        for token in $line; do
            validate_and_add_mount "$token" "VOLUMES"
        done
    done <<< "$VOLUMES"
fi

if [[ ${#PARSED_MOUNTS[@]} -eq 0 ]]; then
    echo "[ERROR] No valid directory mappings found to apply." >&2
    exit 1
fi

IFS=':' read -r PRIMARY_HOST_DIR PRIMARY_VM_DIR PRIMARY_MODE <<< "${PARSED_MOUNTS[0]}"

MOUNT_FLAGS=()
echo "==> Target directory mounts:"
for mount_entry in "${PARSED_MOUNTS[@]}"; do
    IFS=':' read -r h_dir v_dir m_mode <<< "$mount_entry"
    echo "    - $h_dir -> $v_dir ($m_mode)"
    MOUNT_FLAGS+=("-v" "${h_dir}:${v_dir}")
done

# 3. Check if VM is Actively Running
RUNNING_PIDS="$(pgrep -f "krunvm.*start.*[[:space:]]${VM_NAME}([[:space:]]|$)" || true)"

if [[ -n "$RUNNING_PIDS" ]]; then
    echo ""
    echo "[NOTICE] MicroVM '$VM_NAME' is currently running (PID: $(echo $RUNNING_PIDS | tr '\n' ' '))."
    echo "         virtio-fs hypervisor hardware mounts cannot be hot-plugged into an active session."
    echo "         To ensure file integrity, the running VM session must be stopped."
    echo ""
    read -r -p "==> Gracefully stop the running VM session now? [Y/n] " confirm || confirm="y"
    confirm="${confirm:-y}"
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "==> Sending SIGTERM to gracefully shut down the active session..."
        # Kill the innermost krunvm-bin process first to allow libkrun hypervisor to flush caches
        KRUN_BIN_PID="$(pgrep -f "krunvm-bin.*start.*${VM_NAME}" || true)"
        if [[ -n "$KRUN_BIN_PID" ]]; then
            kill -15 $KRUN_BIN_PID 2>/dev/null || true
        else
            kill -15 $RUNNING_PIDS 2>/dev/null || true
        fi

        # Wait up to 5 seconds for clean exit and dirty buffer flush
        for i in {1..5}; do
            if ! pgrep -f "krunvm.*start.*[[:space:]]${VM_NAME}([[:space:]]|$)" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done

        if pgrep -f "krunvm.*start.*[[:space:]]${VM_NAME}([[:space:]]|$)" >/dev/null 2>&1; then
            echo "==> Session still active; terminating gracefully with SIGINT/SIGKILL..."
            pkill -9 -f "krunvm.*start.*[[:space:]]${VM_NAME}([[:space:]]|$)" 2>/dev/null || true
            sleep 1
        fi
        echo "==> VM session stopped cleanly."
    else
        echo "[ABORT] Refresh cancelled. Please exit the running VM session and rerun this script."
        exit 0
    fi
fi

# 4. Apply Configuration Updates In-Place via changevm
echo ""
echo "==> Updating microVM configuration via 'krunvm changevm'..."
"$KRUNVM_BIN" changevm "$VM_NAME" \
    --workdir "$PRIMARY_VM_DIR" \
    "${MOUNT_FLAGS[@]}" >/dev/null

echo "=========================================================================="
echo " [SUCCESS] Volume mounts refreshed successfully!"
echo "=========================================================================="
echo "Your VM state, rootfs, and auth tokens (gh auth, agy auth) were preserved."
echo "Launch your updated microVM with:"
echo "    ./run_sandbox.sh"
echo "=========================================================================="
