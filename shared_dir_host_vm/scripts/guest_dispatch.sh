#!/usr/bin/env bash
# ==============================================================================
# guest_dispatch.sh - In-guest runtime dispatcher for persistent krunvm sandbox
# Executed inside the microVM to configure guest user, permissions, and launch
# Zellij, interactive bash, or command execution.
# ==============================================================================

set -eo pipefail

# 1. Enforce read-only mounts
/usr/local/bin/enforce-mounts.sh 2>/dev/null || true

# 2. Source environment configuration from mounted repo
ENV_FILE="/krunvm/.env.host"
[[ -f "$ENV_FILE" ]] || ENV_FILE="/krunvm/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
fi

GUEST_USER="${VM_USER:-sandbox-runner}"

# 3. Resolve primary workspace directory
PRIMARY_VM_DIR=""
if [[ -n "${VOLUMES:-}" ]]; then
    first_vol="$(echo "$VOLUMES" | grep -v '^[[:space:]]*#' | grep -E '^/[^:]+:' | head -n1 || true)"
    if [[ "$first_vol" =~ ^/[^:]+:([^:]+) ]]; then
        PRIMARY_VM_DIR="${BASH_REMATCH[1]}"
    fi
fi
PRIMARY_VM_DIR="${PRIMARY_VM_DIR:-/doc-micro-access-ctr}"

# 4. Ensure guest user exists and has sudo privileges
if [ "$GUEST_USER" = "sandbox-runner" ]; then
    if ! id -u sandbox-runner >/dev/null 2>&1; then
        if id -u ubuntu >/dev/null 2>&1; then
            usermod -l sandbox-runner -d /home/sandbox-runner -m ubuntu 2>/dev/null || true
            groupmod -n sandbox-runner ubuntu 2>/dev/null || true
            ln -sfn /home/sandbox-runner /home/ubuntu
        else
            groupadd -g 1000 sandbox-runner 2>/dev/null || true
            useradd -u 1000 -g 1000 -m -s /bin/bash sandbox-runner 2>/dev/null || true
        fi
        echo "sandbox-runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sandbox-runner
        chmod 0440 /etc/sudoers.d/sandbox-runner
    fi
fi

# Determine target user to run as
RUN_AS="$GUEST_USER"
id -u "$RUN_AS" >/dev/null 2>&1 || RUN_AS="ubuntu"
id -u "$RUN_AS" >/dev/null 2>&1 || RUN_AS="root"

RUN_HOME="$(getent passwd "$RUN_AS" | cut -d: -f6)"
RUN_HOME="${RUN_HOME:-/home/$RUN_AS}"

# 5. Ensure Zellij layout and config exist for RUN_AS
if [ -d /krunvm/configs ]; then
    mkdir -p "${RUN_HOME}/.config/zellij/layouts"
    if [ -f /krunvm/configs/layouts/agy-dev.kdl ]; then
        cp /krunvm/configs/layouts/agy-dev.kdl "${RUN_HOME}/.config/zellij/layouts/agy-dev.kdl"
    fi
    if [ -f /krunvm/configs/zellij-config.kdl ]; then
        cp /krunvm/configs/zellij-config.kdl "${RUN_HOME}/.config/zellij/config.kdl"
    fi
    chown -R "${RUN_AS}:${RUN_AS}" "${RUN_HOME}/.config" 2>/dev/null || true
fi

# 6. Ensure Antigravity telemetry secrets are in place
if [ -f /krunvm/.env.sandbox ]; then
    mkdir -p "${RUN_HOME}/.gemini/antigravity-cli"
    cp /krunvm/.env.sandbox "${RUN_HOME}/.gemini/antigravity-cli/.env"
    chown -R "${RUN_AS}:${RUN_AS}" "${RUN_HOME}/.gemini" 2>/dev/null || true
fi

# 7. Determine command to execute
export TERM="${TERM:-xterm-256color}"
export HOME="$RUN_HOME"

if [ $# -eq 0 ]; then
    if [ "${USE_ZELLIJ:-false}" = "true" ]; then
        CMD_TO_RUN="exec /usr/local/bin/zellij"
    else
        CMD_TO_RUN="exec /bin/bash"
    fi
elif [ $# -eq 1 ]; then
    CMD_TO_RUN="exec $1"
else
    CMD_TO_RUN="exec \"\$@\""
fi

if [ "$RUN_AS" = "root" ]; then
    cd "$PRIMARY_VM_DIR" 2>/dev/null || true
    if [ $# -le 1 ]; then
        eval "$CMD_TO_RUN"
    else
        "$@"
    fi
else
    if [ $# -eq 0 ] || [ $# -eq 1 ]; then
        exec su -l "$RUN_AS" -c "cd \"$PRIMARY_VM_DIR\" 2>/dev/null || true; $CMD_TO_RUN"
    else
        ARGS_ESC="$(printf '%q ' "$@")"
        exec su -l "$RUN_AS" -c "cd \"$PRIMARY_VM_DIR\" 2>/dev/null || true; exec $ARGS_ESC"
    fi
fi
