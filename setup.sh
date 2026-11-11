#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Hardened krunvm MicroVM Provisioning & Lifecycle Engine
# Creates and configures the Persistent Sandbox and subagent orchestration layer.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# 1. Environment & Configuration Loading (.env)
# ------------------------------------------------------------------------------
if [[ -z "${ENV_FILE:-}" ]]; then
    if [[ -f "${SCRIPT_DIR}/.env.host" ]]; then
        ENV_FILE="${SCRIPT_DIR}/.env.host"
    else
        ENV_FILE="${SCRIPT_DIR}/.env"
    fi
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] Configuration file '$ENV_FILE' not found. Please copy .env.example to .env." >&2
    exit 1
fi

echo "==> Loading configuration from $ENV_FILE..."
# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

# ------------------------------------------------------------------------------
# 2. Strict Configuration Validation
# ------------------------------------------------------------------------------
REQUIRED_CONFIG_VARS=(
    "VM_NAME"
    "OCI_BASE_IMAGE"
    "VM_CPUS"
    "VM_MEMORY"
    "VM_USER"
    "VM_VENV_DIR"
    "VOLUMES"
    "HOST_LANGFUSE_PORT"
    "HOST_OTEL_EXPORTER_PORT"
)

MISSING_CONFIG_VARS=()
for var_name in "${REQUIRED_CONFIG_VARS[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
        MISSING_CONFIG_VARS+=("$var_name")
    fi
done

if [[ ${#MISSING_CONFIG_VARS[@]} -gt 0 ]]; then
    echo "[ERROR] Missing required configuration values in '$ENV_FILE':" >&2
    for var_name in "${MISSING_CONFIG_VARS[@]}"; do
        echo "        - $var_name is unset or empty." >&2
    done
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Volume Parsing & krunvm Constraint Validation
# ------------------------------------------------------------------------------
PARSED_MOUNTS=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    for token in $line; do
        if [[ "$token" =~ ^(/[^:]+):(/[^:]+)(:(ro|rw))?$ ]]; then
            h_dir="${BASH_REMATCH[1]}"
            v_dir="${BASH_REMATCH[2]}"
            m_mode="${BASH_REMATCH[4]:-rw}"

            # krunvm constraint: guest_path must be a single direct root child (e.g. /workspace)
            trimmed_v="${v_dir#/}"
            if [[ "$trimmed_v" == *"/"* || -z "$trimmed_v" ]]; then
                echo "[ERROR] Invalid volume mapping '$token':" >&2
                echo "        krunvm requires guest_path to be a direct root child (e.g. /workspace, /scratch)." >&2
                exit 1
            fi
            PARSED_MOUNTS+=("${h_dir}:${v_dir}:${m_mode}")
        else
            echo "[ERROR] Invalid volume mapping in VOLUMES: '$token'" >&2
            echo "        Expected syntax: /path/on/host:/path_in_vm[:ro|:rw]" >&2
            exit 1
        fi
    done
done <<< "$VOLUMES"

if [[ ${#PARSED_MOUNTS[@]} -eq 0 ]]; then
    echo "[ERROR] No valid volume definitions found in 'VOLUMES'." >&2
    exit 1
fi

# Security Golden Rule: Never mount /, /home, or the entire user home directory
REAL_HOME="$(realpath "$HOME" 2>/dev/null || echo "$HOME")"
for mount_entry in "${PARSED_MOUNTS[@]}"; do
    IFS=':' read -r h_dir v_dir m_mode <<< "$mount_entry"
    REAL_HOST_DIR="$(realpath "$h_dir" 2>/dev/null || echo "$h_dir")"

    if [[ "$REAL_HOST_DIR" == "/" || "$REAL_HOST_DIR" == "/home" || "$REAL_HOST_DIR" == "$REAL_HOME" ]]; then
        echo "[SECURITY ERROR] Refusing to mount host root or home directory ($REAL_HOST_DIR)." >&2
        echo "                 Only dedicated project subfolders should be mounted." >&2
        exit 1
    fi
done

IFS=':' read -r PRIMARY_HOST_DIR PRIMARY_VM_DIR PRIMARY_MODE <<< "${PARSED_MOUNTS[0]}"

# ------------------------------------------------------------------------------
# 4. Host Binary Resolution
# ------------------------------------------------------------------------------
KRUNVM_BIN="${KRUNVM_BIN:-}"
if [[ -z "$KRUNVM_BIN" ]]; then
    if command -v krunvm >/dev/null 2>&1; then
        KRUNVM_BIN="$(command -v krunvm)"
    elif [[ -x "${HOME}/.local/bin/krunvm" ]]; then
        KRUNVM_BIN="${HOME}/.local/bin/krunvm"
    else
        echo "[ERROR] 'krunvm' executable not found on host." >&2
        echo "        Please build it first: bash scripts/build_krunvm_host.sh" >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 5. Base OCI Image Verification
# ------------------------------------------------------------------------------
echo "==> Checking base OCI image '$OCI_BASE_IMAGE'..."
IMAGE_EXISTS=false
if command -v buildah >/dev/null 2>&1; then
    if buildah images 2>/dev/null | grep -q "${OCI_BASE_IMAGE%:*}"; then
        IMAGE_EXISTS=true
    fi
fi

if [[ "$IMAGE_EXISTS" != "true" ]]; then
    echo "==> Base image '$OCI_BASE_IMAGE' not found locally. Building image..."
    bash "${SCRIPT_DIR}/scripts/build_image.sh" "$OCI_BASE_IMAGE"
fi

# ------------------------------------------------------------------------------
# 6. Instance Lifecycle Management (Persistent Sandbox)
# ------------------------------------------------------------------------------
echo "==> Checking current status of persistent sandbox '$VM_NAME'..."
VM_LIST="$("$KRUNVM_BIN" list 2>/dev/null || true)"

if echo "$VM_LIST" | grep -q "^${VM_NAME}[[:space:]]*$"; then
    echo "==> Persistent sandbox '$VM_NAME' already exists in krunvm."
else
    echo "==> Creating persistent sandbox '$VM_NAME'..."
    MOUNT_FLAGS=()
    for mount_entry in "${PARSED_MOUNTS[@]}"; do
        IFS=':' read -r h_dir v_dir m_mode <<< "$mount_entry"
        MOUNT_FLAGS+=("-v" "${h_dir}:${v_dir}")
    done

    "$KRUNVM_BIN" create \
        --name "$VM_NAME" \
        --cpus "$VM_CPUS" \
        --mem "$VM_MEMORY" \
        --workdir "$PRIMARY_VM_DIR" \
        "${MOUNT_FLAGS[@]}" \
        "$OCI_BASE_IMAGE"

    echo "==> Persistent sandbox '$VM_NAME' created successfully."
fi

# ------------------------------------------------------------------------------
# 7. Telemetry & Summary
# ------------------------------------------------------------------------------
echo ""
echo "=========================================================================="
echo " krunvm MicroVM Setup Complete!"
echo "=========================================================================="
echo " Persistent Sandbox: $VM_NAME (CPUs: $VM_CPUS, RAM: ${VM_MEMORY}MB)"
echo " Base Image:         $OCI_BASE_IMAGE"
echo " Working Directory:  $PRIMARY_VM_DIR"
echo " Telemetry Target:   http://${HOST_TARGET_IP:-127.0.0.1}:${HOST_LANGFUSE_PORT}"
echo ""
echo "--- How to Run ---"
echo " 1. Interactive Persistent Shell (YOLO Mode):"
echo "    ./run_sandbox.sh"
echo ""
echo " 2. Launch Ephemeral MicroVM Subagent (<100ms cold start):"
echo "    ./scripts/launch_subagent_microvm.sh [scratch_dir] [command...]"
echo ""
echo " 3. Verify Langfuse & OTEL Connectivity:"
echo "    ./run_sandbox.sh test_connectivity"
echo ""
echo " 4. Install Antigravity CLI (on-demand):"
echo "    ./run_sandbox.sh install_agy"
echo "=========================================================================="
