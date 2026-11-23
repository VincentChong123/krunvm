#!/usr/bin/env bash
# ==============================================================================
# link_vm_workspace.sh - Symlink Host Directory Structure into krunvm MicroVM
# ==============================================================================
# Reads .env.mapped_dir (or uses built-in defaults) and creates a mirrored host
# directory hierarchy inside the microVM's user home directory (e.g. ~/ws/github/...).
#
# Because krunvm requires mounts to be top-level root folders (e.g. /streamhouse_fluss_demo),
# this script restores the familiar host paths inside the VM via symbolic links.
#
# Examples:
#   ~/ws/github/VincentChong123/streamhouse_fluss_demo -> /streamhouse_fluss_demo
#   ~/ws/github/VincentChong123/doc-micro-access-ctr   -> /doc-micro-access-ctr
#   ~/ws/github/VincentChong123/private_repo_obsidian  -> /private_repo_obsidian
#   ~/ws/github/VincentChong123/krunvm/shared_dir_host_vm -> /shared_dir_host_vm
#   ~/ws/github/winwinteam/local-infra                 -> /local-infra
#
# Usage:
#   ./shared_dir_host_vm/scripts/link_vm_workspace.sh [OPTIONS]
#
# Options:
#   --target-home <dir>   Target home directory in VM (default: $HOME)
#   --config <file>       Path to .env.mapped_dir
#   --host-user <user>    Host username for /home/<user> compatibility symlinks
#   --host-alias          Create /home/<user> compatibility symlinks (default: true if host user set)
#   --no-host-alias       Disable host compatibility symlinks
#   --dry-run             Show what links would be created without making changes
#   -h, --help            Show this help message
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_HOME="${HOME:-/root}"
MAPPED_DIR_FILE="${MAPPED_DIR_FILE:-}"
CREATE_HOST_ALIAS=true
DRY_RUN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-home)
            TARGET_HOME="$2"
            shift 2
            ;;
        --target-home=*)
            TARGET_HOME="${1#*=}"
            shift
            ;;
        --config|-c)
            MAPPED_DIR_FILE="$2"
            shift 2
            ;;
        --config=*)
            MAPPED_DIR_FILE="${1#*=}"
            shift
            ;;
        --host-user)
            HOST_USER="$2"
            shift 2
            ;;
        --host-user=*)
            HOST_USER="${1#*=}"
            shift
            ;;
        --host-alias)
            CREATE_HOST_ALIAS=true
            shift
            ;;
        --no-host-alias)
            CREATE_HOST_ALIAS=false
            shift
            ;;
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            sed -ne 's/^# //p; /^# =/q' "$0"
            exit 0
            ;;
        *)
            echo "[WARN] Unknown option '$1' ignored." >&2
            shift
            ;;
    esac
done

echo "=========================================================================="
echo " krunvm Workspace Symlink Mirrored Layout Engine"
echo " Target Home Dir : $TARGET_HOME"
echo " Dry Run Mode   : $DRY_RUN"
echo "=========================================================================="

# 1. Locate .env.mapped_dir
if [[ -z "$MAPPED_DIR_FILE" || ! -f "$MAPPED_DIR_FILE" ]]; then
    SEARCH_LOCATIONS=(
        "/shared_dir_host_vm/.env.mapped_dir"
        "${SCRIPT_DIR}/../.env.mapped_dir"
        "${SCRIPT_DIR}/../../.env.mapped_dir"
        "${PWD}/.env.mapped_dir"
        "${TARGET_HOME}/.env.mapped_dir"
    )
    for candidate in "${SEARCH_LOCATIONS[@]}"; do
        if [[ -f "$candidate" ]]; then
            MAPPED_DIR_FILE="$candidate"
            break
        fi
    done
fi

MAPPING_ENTRIES=()

if [[ -n "$MAPPED_DIR_FILE" && -f "$MAPPED_DIR_FILE" ]]; then
    echo " Using Mappings : $MAPPED_DIR_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        MAPPING_ENTRIES+=("$line")
    done < "$MAPPED_DIR_FILE"
else
    echo " [INFO] .env.mapped_dir not found directly; using default canonical mapping set."
    MAPPING_ENTRIES=(
        '${HOME}/ws/github/VincentChong123/krunvm/shared_dir_host_vm:/shared_dir_host_vm:rw'
        '${HOME}/ws/github/winwinteam/local-infra:/local-infra:rw'
        '${HOME}/ws/github/VincentChong123/private_repo_obsidian:/private_repo_obsidian:rw'
        '${HOME}/ws/github/VincentChong123/doc-micro-access-ctr:/doc-micro-access-ctr:rw'
        '${HOME}/ws/github/VincentChong123/streamhouse_fluss_demo:/streamhouse_fluss_demo:rw'
        '${HOME}/ws/github/VincentChong123/dotfiles:/dotfiles:ro'
    )
fi

echo "=========================================================================="

# 2. Process each volume mapping
LINK_COUNT=0
for entry in "${MAPPING_ENTRIES[@]}"; do
    # Remove leading list dashes if any
    entry="${entry#- }"
    entry="$(echo "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    entry="${entry%\"}"
    entry="${entry#\"}"
    entry="${entry%\'}"
    entry="${entry#\'}"

    # Syntax: <host_path>:<vm_path>[:mode]
    if [[ "$entry" =~ ^([^:]+):(/[^:]+)(:(ro|rw))?$ ]]; then
        raw_host_path="${BASH_REMATCH[1]}"
        vm_target="${BASH_REMATCH[2]}"

        # Calculate relative path from host home
        rel_path="$raw_host_path"
        rel_path="${rel_path#\$\{HOME\}\/}"
        rel_path="${rel_path#\$HOME\/}"
        rel_path="${rel_path#\~\/}"

        # Strip /var/home/<user>/ or /home/<user>/ if absolute path
        if [[ "$rel_path" =~ ^/(var/)?home/[^/]+/(.*)$ ]]; then
            rel_path="${BASH_REMATCH[2]}"
        elif [[ "$rel_path" =~ ^/(.*)$ ]]; then
            rel_path="${BASH_REMATCH[1]}"
        fi

        dest_link="${TARGET_HOME}/${rel_path}"
        dest_parent="$(dirname "$dest_link")"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY-RUN] mkdir -p \"$dest_parent\""
            echo "[DRY-RUN] ln -sfn \"$vm_target\" \"$dest_link\""
        else
            mkdir -p "$dest_parent"
            ln -sfn "$vm_target" "$dest_link"
            echo " [LINK] $dest_link -> $vm_target"
        fi
        LINK_COUNT=$((LINK_COUNT + 1))
    fi
done

# 3. Create host path compatibility symlinks if requested
HOST_USER="${HOST_USER:-${SANDBOX_HOST_USER:-}}"
if [[ "$CREATE_HOST_ALIAS" == "true" && -n "$HOST_USER" ]]; then
    echo "--------------------------------------------------------------------------"
    echo " Configuring Host Path Aliases (/home/${HOST_USER}, /var/home/${HOST_USER})..."
    HOST_COMPAT_DIRS=("/home/${HOST_USER}" "/var/home/${HOST_USER}")
    for compat in "${HOST_COMPAT_DIRS[@]}"; do
        compat_parent="$(dirname "$compat")"
        if [[ "$compat" != "$TARGET_HOME" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "[DRY-RUN] mkdir -p \"$compat_parent\""
                echo "[DRY-RUN] ln -sfn \"$TARGET_HOME\" \"$compat\""
            else
                if mkdir -p "$compat_parent" 2>/dev/null; then
                    ln -sfn "$TARGET_HOME" "$compat" 2>/dev/null || true
                    echo " [ALIAS] $compat -> $TARGET_HOME"
                else
                    echo " [NOTICE] Could not create $compat (permission denied; run with root to enable)."
                fi
            fi
        fi
    done
fi

echo "=========================================================================="
echo " [SUCCESS] Finished! Mirrored $LINK_COUNT workspace directories."
echo "=========================================================================="
