#!/usr/bin/env bash
# ==============================================================================
# setup_host_sandbox_user.sh - Provision Dedicated Sandbox User & ACL Permissions
# ==============================================================================
# 1. Creates dedicated host user 'sandbox-runner' (with /dev/kvm access).
# 2. Applies traversal ACLs on parent paths (/home/vin/...).
# 3. Grants bidirectional read/write ACLs on mapped RW volumes.
# 4. Grants read-only ACLs on mapped RO volumes.
# 5. Configures iptables rule blocking loopback SSH (port 22) for sandbox-runner.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure script is executed with root privileges
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run with sudo/root privileges:" >&2
    echo "        sudo $0" >&2
    exit 1
fi

SANDBOX_USER="${1:-sandbox-runner}"
PRIMARY_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "vin")}"

echo "=========================================================================="
echo " Setting up Dedicated Host Sandbox User: '$SANDBOX_USER'"
echo " Primary Host User:                      '$PRIMARY_USER'"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 1. Create Host Sandbox User & Groups
# ------------------------------------------------------------------------------
if id "$SANDBOX_USER" &>/dev/null; then
    echo "==> Host user '$SANDBOX_USER' already exists."
else
    echo "==> Creating system user '$SANDBOX_USER'..."
    useradd -r -m -s /bin/bash -c "krunvm YOLO Sandbox Runner" "$SANDBOX_USER"
    echo "    Created user '$SANDBOX_USER' (UID: $(id -u "$SANDBOX_USER"))."
fi

# Ensure user has access to KVM virtualization
if getent group kvm &>/dev/null; then
    usermod -aG kvm "$SANDBOX_USER"
    echo "==> Added '$SANDBOX_USER' to 'kvm' group."
fi

# Ensure user has subuid and subgid configured for rootless buildah/krunvm
if ! grep -q "^${SANDBOX_USER}:" /etc/subuid 2>/dev/null; then
    echo "${SANDBOX_USER}:200000:65536" >> /etc/subuid
    echo "==> Allocated subuid range for '$SANDBOX_USER'."
fi
if ! grep -q "^${SANDBOX_USER}:" /etc/subgid 2>/dev/null; then
    echo "${SANDBOX_USER}:200000:65536" >> /etc/subgid
    echo "==> Allocated subgid range for '$SANDBOX_USER'."
fi

# Install global /usr/local/bin/krunvm wrapper so sandbox-runner can execute it
echo "==> Installing global krunvm launcher wrapper at /usr/local/bin/krunvm..."
cat <<EOF > /usr/local/bin/krunvm
#!/usr/bin/env bash
export LD_LIBRARY_PATH="/home/${PRIMARY_USER}/.local/lib/x86_64-linux-gnu:/home/${PRIMARY_USER}/.local/lib64:/home/${PRIMARY_USER}/.local/lib:\${LD_LIBRARY_PATH:-}"
if [[ "\${_CONTAINERS_USERNS_CONFIGURED:-}" != "done" ]]; then
    exec buildah unshare -- "\$0" "\$@"
else
    exec "/home/${PRIMARY_USER}/.local/bin/krunvm-bin" "\$@"
fi
EOF
chmod 755 /usr/local/bin/krunvm
echo "    Installed /usr/local/bin/krunvm."

# ------------------------------------------------------------------------------
# 2. Parse Volume Mounts from Environment
# ------------------------------------------------------------------------------
ENV_FILE="${ROOT_DIR}/.env.host"
[[ -f "$ENV_FILE" ]] || ENV_FILE="${ROOT_DIR}/.env"

RW_DIRS=()
RO_DIRS=()

if [[ -f "$ENV_FILE" ]]; then
    echo "==> Parsing volume mounts from $ENV_FILE..."
    # Extract VOLUMES block
    VOL_BLOCK=$(sed -n '/^VOLUMES=/,/^"/p' "$ENV_FILE" | grep -v '^VOLUMES=' | tr -d '"')
    while IFS= read -r line; do
        line="$(echo "$line" | xargs)"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" =~ ^([^:]+):([^:]+)(:(ro|rw))?$ ]]; then
            h_path="${BASH_REMATCH[1]}"
            m_mode="${BASH_REMATCH[4]:-rw}"
            if [[ "$m_mode" == "ro" ]]; then
                RO_DIRS+=("$h_path")
            else
                RW_DIRS+=("$h_path")
            fi
        fi
    done <<< "$VOL_BLOCK"
else
    # Fallback default if no env file found
    RW_DIRS+=("/home/${PRIMARY_USER}/ws/20_projects/21_github/Vincentchong123/doc-micro-access-ctr")
fi

# ------------------------------------------------------------------------------
# 3. Configure Directory Traversal ACLs on Parents
# ------------------------------------------------------------------------------
echo "==> Configuring directory traversal ACLs on parent paths..."
ALL_DIRS=("${RW_DIRS[@]}" "${RO_DIRS[@]}")
PARENT_PATHS=()

for target_dir in "${ALL_DIRS[@]}"; do
    curr_dir="$(dirname "$target_dir")"
    while [[ "$curr_dir" != "/" && "$curr_dir" != "." ]]; do
        PARENT_PATHS+=("$curr_dir")
        curr_dir="$(dirname "$curr_dir")"
    done
done

# Deduplicate and sort parent paths from root downwards
IFS=$'\n' SORTED_PARENTS=($(sort -u <<<"${PARENT_PATHS[*]}"))
unset IFS

for parent in "${SORTED_PARENTS[@]}"; do
    if [[ -d "$parent" ]]; then
        setfacl -m "u:${SANDBOX_USER}:x" "$parent" 2>/dev/null || true
    fi
done

# Ensure sandbox-runner can execute local krunvm binary & shared libraries if in ~/.local
if [[ -d "/home/${PRIMARY_USER}/.local/bin" ]]; then
    setfacl -m "u:${SANDBOX_USER}:x" "/home/${PRIMARY_USER}/.local" 2>/dev/null || true
    setfacl -m "u:${SANDBOX_USER}:rx" "/home/${PRIMARY_USER}/.local/bin" 2>/dev/null || true
    [[ -f "/home/${PRIMARY_USER}/.local/bin/krunvm" ]] && setfacl -m "u:${SANDBOX_USER}:rx" "/home/${PRIMARY_USER}/.local/bin/krunvm" 2>/dev/null || true
    [[ -f "/home/${PRIMARY_USER}/.local/bin/krunvm-bin" ]] && setfacl -m "u:${SANDBOX_USER}:rx" "/home/${PRIMARY_USER}/.local/bin/krunvm-bin" 2>/dev/null || true
    for libdir in "/home/${PRIMARY_USER}/.local/lib" "/home/${PRIMARY_USER}/.local/lib64" "/home/${PRIMARY_USER}/.local/lib/x86_64-linux-gnu"; do
        [[ -d "$libdir" ]] && setfacl -R -m "u:${SANDBOX_USER}:rx" "$libdir" 2>/dev/null || true
    done
fi
echo "    Parent directory and runtime traversal ACLs configured."

# ------------------------------------------------------------------------------
# 4. Configure Read/Write Permissions & Default ACL Inheritance
# ------------------------------------------------------------------------------
for rw_dir in "${RW_DIRS[@]}"; do
    if [[ -d "$rw_dir" ]]; then
        echo "==> Applying bidirectional Read/Write ACLs on '$rw_dir'..."
        # Existing files and directories
        setfacl -R -m "u:${SANDBOX_USER}:rwX" "$rw_dir"
        setfacl -R -m "u:${PRIMARY_USER}:rwX" "$rw_dir"
        # Default ACL for future files and directories
        setfacl -R -d -m "u:${SANDBOX_USER}:rwX" "$rw_dir"
        setfacl -R -d -m "u:${PRIMARY_USER}:rwX" "$rw_dir"
        echo "    RW ACLs set for '$SANDBOX_USER' and '$PRIMARY_USER'."
    else
        echo "    [WARN] RW directory '$rw_dir' not found on host. Skipping."
    fi
done

# ------------------------------------------------------------------------------
# 5. Configure Read-Only Permissions
# ------------------------------------------------------------------------------
for ro_dir in "${RO_DIRS[@]}"; do
    if [[ -d "$ro_dir" ]]; then
        echo "==> Applying Read-Only ACLs on '$ro_dir'..."
        setfacl -R -m "u:${SANDBOX_USER}:r-X" "$ro_dir"
        setfacl -R -d -m "u:${SANDBOX_USER}:r-X" "$ro_dir"
        echo "    RO ACLs set for '$SANDBOX_USER'."
    fi
done

# ------------------------------------------------------------------------------
# 6. Firewall: Strict Internet-Only Policy (Blocks Host Ports & Private LAN)
# ------------------------------------------------------------------------------
echo "==> Configuring host firewall (iptables) for strict Internet-Only access..."
LANGFUSE_PORT="${HOST_LANGFUSE_PORT:-3100}"
if [[ -f "$ENV_FILE" ]]; then
    EXTRACTED_PORT="$(grep -E "^HOST_LANGFUSE_PORT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' || true)"
    [[ -n "$EXTRACTED_PORT" ]] && LANGFUSE_PORT="$EXTRACTED_PORT"
fi

if command -v iptables &>/dev/null; then
    # Dedicated chain for sandbox network isolation
    CHAIN_NAME="KRUNVM_SANDBOX_OUT"
    iptables -N "$CHAIN_NAME" 2>/dev/null || iptables -F "$CHAIN_NAME"

    # Route all outbound packets originating from sandbox-runner into the sandbox chain
    if ! iptables -C OUTPUT -m owner --uid-owner "$SANDBOX_USER" -j "$CHAIN_NAME" 2>/dev/null; then
        iptables -A OUTPUT -m owner --uid-owner "$SANDBOX_USER" -j "$CHAIN_NAME"
    fi

    # 1. Allow established and related connections (return traffic)
    iptables -A "$CHAIN_NAME" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 2. Allow DNS resolution (port 53)
    iptables -A "$CHAIN_NAME" -p udp --dport 53 -j ACCEPT
    iptables -A "$CHAIN_NAME" -p tcp --dport 53 -j ACCEPT

    # 3. Allow telemetry to local Langfuse server on host loopback
    if [[ -n "$LANGFUSE_PORT" ]]; then
        iptables -A "$CHAIN_NAME" -d 127.0.0.1 -p tcp --dport "$LANGFUSE_PORT" -j ACCEPT
        echo "    Allowed host loopback port $LANGFUSE_PORT (Langfuse Telemetry)."
    fi

    # 4. REJECT all other host loopback access (blocks SSH 22, DBs, internal host services)
    iptables -A "$CHAIN_NAME" -d 127.0.0.0/8 -j REJECT --reject-with icmp-port-unreachable
    echo "    Blocked all other host loopback access (127.0.0.0/8, including SSH port 22)."

    # 5. REJECT link-local and cloud metadata addresses (169.254.0.0/16)
    iptables -A "$CHAIN_NAME" -d 169.254.0.0/16 -j REJECT --reject-with icmp-port-unreachable

    # 6. REJECT private LAN subnets (blocks scanning or attacking other machines on local Wi-Fi/LAN)
    iptables -A "$CHAIN_NAME" -d 10.0.0.0/8 -j REJECT --reject-with icmp-port-unreachable
    iptables -A "$CHAIN_NAME" -d 172.16.0.0/12 -j REJECT --reject-with icmp-port-unreachable
    iptables -A "$CHAIN_NAME" -d 192.168.0.0/16 -j REJECT --reject-with icmp-port-unreachable
    echo "    Blocked private LAN subnets (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)."

    # 7. ACCEPT all remaining traffic (Public Internet: github.com, web search tools, APIs)
    iptables -A "$CHAIN_NAME" -j ACCEPT
    echo "    Allowed Public Internet access (GitHub, Web Search, Package Managers)."
fi

# ------------------------------------------------------------------------------
# 7. Sync Base OCI Image to sandbox-runner Storage
# ------------------------------------------------------------------------------
if command -v buildah &>/dev/null; then
    if sudo -u "$PRIMARY_USER" buildah images 2>/dev/null | grep -q "krun-agent-sandbox"; then
        echo "==> Syncing base image 'localhost/krun-agent-sandbox:latest' to '$SANDBOX_USER' storage..."
        TMP_IMAGE="/tmp/krun-sandbox-base.tar"
        sudo -u "$PRIMARY_USER" buildah push localhost/krun-agent-sandbox:latest "oci-archive:${TMP_IMAGE}" 2>/dev/null || true
        if [[ -f "$TMP_IMAGE" ]]; then
            chmod 644 "$TMP_IMAGE"
            sudo -u "$SANDBOX_USER" buildah pull "oci-archive:${TMP_IMAGE}" 2>/dev/null || true
            rm -f "$TMP_IMAGE"
            echo "    Base image synced to '$SANDBOX_USER' storage."
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 8. Verification Tests (Filesystem & Network Isolation)
# ------------------------------------------------------------------------------
echo "==> Verifying permissions and network isolation as '$SANDBOX_USER'..."

# Test 1: Filesystem write
PRIMARY_RW="${RW_DIRS[0]:-}"
if [[ -n "$PRIMARY_RW" && -d "$PRIMARY_RW" ]]; then
    TEST_FILE="${PRIMARY_RW}/.sandbox_perm_test"
    if sudo -u "$SANDBOX_USER" touch "$TEST_FILE" 2>/dev/null; then
        echo "    [PASS] Filesystem: '$SANDBOX_USER' successfully wrote to '$PRIMARY_RW'."
        rm -f "$TEST_FILE"
    else
        echo "    [FAIL] Filesystem: '$SANDBOX_USER' could not write to '$PRIMARY_RW'." >&2
        exit 1
    fi
fi

# Test 2: Network isolation - Host Loopback Port 22 must be blocked
if command -v curl &>/dev/null; then
    if sudo -u "$SANDBOX_USER" curl -s --connect-timeout 2 http://127.0.0.1:22 &>/dev/null; then
        echo "    [WARN] Network: 127.0.0.1:22 responded (firewall rule might not be matching)."
    else
        echo "    [PASS] Network: Host loopback port 22 is securely blocked."
    fi

    # Test 3: Public Internet access must be working (GitHub)
    if sudo -u "$SANDBOX_USER" curl -s --connect-timeout 4 https://github.com &>/dev/null; then
        echo "    [PASS] Network: Public Internet access (github.com) is operational."
    else
        echo "    [WARN] Network: Could not reach github.com (check host internet connectivity)."
    fi
fi

echo ""
echo "=========================================================================="
echo " Setup complete! Host sandbox user '$SANDBOX_USER' is fully configured."
echo "=========================================================================="
