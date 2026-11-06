#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Hardened krunvm MicroVM Provisioning & Lifecycle Engine
# Creates and configures the Persistent Sandbox and subagent orchestration layer.
# Supports hierarchical .env / .env.host / .env.sandbox architecture.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECREATE=false

for arg in "$@"; do
    case "$arg" in
        --as-runner)
            if [[ "$(id -un)" != "sandbox-runner" ]]; then
                echo "==> Re-executing setup.sh as 'sandbox-runner'..."
                exec sudo -u sandbox-runner -H "$0" "$@"
            fi
            ;;
        --recreate|-r)
            RECREATE=true
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 1. Environment & Configuration Loading (.env.host / .env)
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

# Support running under dedicated sandbox user configured in .env.host
if [[ -n "${SANDBOX_HOST_USER:-}" ]] && [[ "$(id -un)" != "$SANDBOX_HOST_USER" ]]; then
    echo "==> Re-executing setup.sh as isolated host user '$SANDBOX_HOST_USER'..."
    exec sudo -u "$SANDBOX_HOST_USER" -H "$0" "$@"
fi

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
# 3. Volume Parsing, Normalization & krunvm Constraint Handling
# ------------------------------------------------------------------------------
PARSED_MOUNTS=()
RO_MOUNTS=()
SYMLINKS=()

# Dynamically resolve and substitute user variables in VOLUMES
EFFECTIVE_USER="${SANDBOX_HOST_USER:-${VM_USER:-sandbox-runner}}"
VOLUMES="${VOLUMES//\$SANDBOX_HOST_USER/$EFFECTIVE_USER}"
VOLUMES="${VOLUMES//\$\{SANDBOX_HOST_USER\}/$EFFECTIVE_USER}"
VOLUMES="${VOLUMES//\$VM_USER/$EFFECTIVE_USER}"
VOLUMES="${VOLUMES//\$\{VM_USER\}/$EFFECTIVE_USER}"

while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    for token in $line; do
        if [[ "$token" =~ ^(/[^:]+):(/[^:]+)(:(ro|rw))?$ ]]; then
            h_dir="${BASH_REMATCH[1]}"
            raw_v_dir="${BASH_REMATCH[2]}"
            m_mode="${BASH_REMATCH[4]:-rw}"

            # krunvm requires guest paths to be a direct root child (e.g. /doc-micro-access-ctr)
            # If user specifies /home/<user>/<name>, extract /<name> for krunvm and symlink it
            if [[ "$raw_v_dir" =~ ^/home/[^/]+/(.+)$ ]]; then
                leaf="${BASH_REMATCH[1]}"
                v_vm_dir="/${leaf}"
                v_symlink="/home/${EFFECTIVE_USER}/${leaf}"
            elif [[ "$raw_v_dir" =~ ^/([^/]+)$ ]]; then
                v_vm_dir="$raw_v_dir"
                v_symlink="/home/${EFFECTIVE_USER}/${BASH_REMATCH[1]}"
            else
                echo "[ERROR] Invalid volume mapping '$token':" >&2
                echo "        krunvm requires guest_path to be a direct root child (e.g. /workspace) or /home/ubuntu/<name>." >&2
                exit 1
            fi

            if [[ "$m_mode" == "ro" ]]; then
                RO_MOUNTS+=("${v_vm_dir}")
            fi
            SYMLINKS+=("${v_vm_dir}:${v_symlink}")
            PARSED_MOUNTS+=("${h_dir}:${v_vm_dir}:${m_mode}")
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
    for candidate in \
        "$(command -v krunvm 2>/dev/null || true)" \
        "/usr/local/bin/krunvm" \
        "/home/vin/.local/bin/krunvm" \
        "${HOME}/.local/bin/krunvm"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            KRUNVM_BIN="$candidate"
            break
        fi
    done
fi

if [[ ! -x "${KRUNVM_BIN:-}" ]]; then
    echo "[ERROR] 'krunvm' executable not found on host." >&2
    echo "        Please build it first: bash scripts/build_krunvm_host.sh" >&2
    exit 1
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
    if [[ "$RECREATE" == "true" ]]; then
        echo "==> Deleting existing microVM '$VM_NAME' for clean recreation (--recreate)..."
        "$KRUNVM_BIN" delete "$VM_NAME" >/dev/null 2>&1 || true
    else
        echo "==> Persistent sandbox '$VM_NAME' already exists in krunvm."
        echo "    Tip: Run './setup.sh --recreate' to apply new volume mappings."
    fi
fi

# Re-check after potential deletion
VM_LIST="$("$KRUNVM_BIN" list 2>/dev/null || true)"
if ! echo "$VM_LIST" | grep -q "^${VM_NAME}[[:space:]]*$"; then
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

    # --------------------------------------------------------------------------
    # 7. Post-Provisioning Initialization (Symlinks, RO Mounts, Telemetry Secrets)
    # --------------------------------------------------------------------------
    echo "==> Configuring guest environment (symlinks, ro mounts, telemetry)..."

    # Find a writable mounted host folder for the init script handoff
    HANDOFF_HOST_DIR="$PRIMARY_HOST_DIR"
    HANDOFF_VM_DIR="$PRIMARY_VM_DIR"
    for mount_entry in "${PARSED_MOUNTS[@]}"; do
        IFS=':' read -r h_dir v_dir m_mode <<< "$mount_entry"
        if [[ "$m_mode" == "rw" ]]; then
            HANDOFF_HOST_DIR="$h_dir"
            HANDOFF_VM_DIR="$v_dir"
            break
        fi
    done

    INIT_SCRIPT_HOST="${HANDOFF_HOST_DIR}/.tmp_krun_init.sh"
    INIT_SCRIPT_GUEST="${HANDOFF_VM_DIR}/.tmp_krun_init.sh"

    cat << 'EOF' > "$INIT_SCRIPT_HOST"
#!/bin/bash
set -euo pipefail

# 0. Ensure sandbox-runner user exists with passwordless sudo
TARGET_GUEST_USER="${VM_USER:-sandbox-runner}"
if id -u ubuntu >/dev/null 2>&1 && [ "$TARGET_GUEST_USER" = "sandbox-runner" ] && ! id -u sandbox-runner >/dev/null 2>&1; then
    usermod -l sandbox-runner -d /home/sandbox-runner -m ubuntu 2>/dev/null || true
    groupmod -n sandbox-runner ubuntu 2>/dev/null || true
    ln -sfn /home/sandbox-runner /home/ubuntu
    echo "sandbox-runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sandbox-runner
    chmod 0440 /etc/sudoers.d/sandbox-runner
fi

# 1. Setup symlinks in home directory for Multipass compatibility
EOF

    for sym_entry in "${SYMLINKS[@]}"; do
        IFS=':' read -r src dest <<< "$sym_entry"
        echo "mkdir -p \"$(dirname "$dest")\" && ln -sfn \"$src\" \"$dest\"" >> "$INIT_SCRIPT_HOST"
    done

    cat << 'EOF' >> "$INIT_SCRIPT_HOST"
# 2. Configure enforce-mounts script for read-only volume protection
cat << 'ENFORCE_EOF' > /usr/local/bin/enforce-mounts.sh
#!/bin/bash
set -e
EOF

    for ro_mount in "${RO_MOUNTS[@]}"; do
        cat << ENFORCE_RO >> "$INIT_SCRIPT_HOST"
if [ -d "$ro_mount" ]; then
    mount --bind "$ro_mount" "$ro_mount" 2>/dev/null || true
    mount -o remount,ro,bind "$ro_mount" 2>/dev/null || true
fi
ENFORCE_RO
    done

    cat << 'EOF' >> "$INIT_SCRIPT_HOST"
ENFORCE_EOF
chmod +x /usr/local/bin/enforce-mounts.sh
/usr/local/bin/enforce-mounts.sh

# Install global bash login and interactive hook to ensure RO mounts stay locked
cat << 'PROFILE_EOF' > /etc/profile.d/enforce-mounts.sh
if [ -x /usr/local/bin/enforce-mounts.sh ]; then
    /usr/local/bin/enforce-mounts.sh >/dev/null 2>&1 || true
fi
PROFILE_EOF
chmod +x /etc/profile.d/enforce-mounts.sh

if ! grep -q "enforce-mounts.sh" /etc/bash.bashrc 2>/dev/null; then
    echo '[ -x /usr/local/bin/enforce-mounts.sh ] && /usr/local/bin/enforce-mounts.sh >/dev/null 2>&1 || true' >> /etc/bash.bashrc
fi

# 3. Configure Git safe.directory to avoid dubious ownership warnings on mounted volumes
git config --system --add safe.directory "*" 2>/dev/null || true

# 4. Inject guest sandbox secrets if available
mkdir -p /home/ubuntu/.gemini/antigravity-cli
if [ -f /krunvm/.env.sandbox ]; then
    cp /krunvm/.env.sandbox /home/ubuntu/.gemini/antigravity-cli/.env
elif [ -f /.env.sandbox ]; then
    cp /.env.sandbox /home/ubuntu/.gemini/antigravity-cli/.env
fi
chown -R ubuntu:ubuntu /home/ubuntu
EOF

    chmod +x "$INIT_SCRIPT_HOST"
    # Execute guest initialization inside krunvm
    "$KRUNVM_BIN" start "$VM_NAME" -- bash "$INIT_SCRIPT_GUEST" || true
    rm -f "$INIT_SCRIPT_HOST"
fi

# ------------------------------------------------------------------------------
# 8. Summary & Next Steps
# ------------------------------------------------------------------------------
echo ""
echo "=========================================================================="
echo " krunvm MicroVM Setup Complete!"
echo "=========================================================================="
echo " Persistent Sandbox: $VM_NAME (CPUs: $VM_CPUS, RAM: ${VM_MEMORY}MB)"
echo " Base Image:         $OCI_BASE_IMAGE"
echo " Primary Workdir:    $PRIMARY_VM_DIR"
echo " Active Volumes:"
for mount_entry in "${PARSED_MOUNTS[@]}"; do
    IFS=':' read -r h_dir v_dir m_mode <<< "$mount_entry"
    echo "   - $h_dir -> $v_dir ($m_mode)"
done
echo " Telemetry Target:   http://${HOST_TARGET_IP:-127.0.0.1}:${HOST_LANGFUSE_PORT}"
echo ""
echo "--- How to Run ---"
echo " 1. Interactive Persistent Shell (YOLO Mode):"
echo "    ./run_sandbox.sh"
echo ""
echo " 2. Verify Langfuse & OTEL Connectivity:"
echo "    ./run_sandbox.sh test_connectivity"
echo "=========================================================================="
