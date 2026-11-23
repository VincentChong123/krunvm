#!/usr/bin/env bash
# ==============================================================================
# scripts/load_config.sh - Single Source of Truth Configuration Loader
# ==============================================================================
# Standardizes configuration resolution, environment precedence, and logging
# across setup.sh, run_sandbox.sh, refresh_mounts.sh, etc.
# ==============================================================================

# Determine repository root
if [[ -z "${REPO_ROOT:-}" ]]; then
    _LOAD_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$_LOAD_CONFIG_DIR"
    while [[ "$REPO_ROOT" != "/" && ! -f "$REPO_ROOT/setup.sh" && ! -d "$REPO_ROOT/.git" && ! -f "$REPO_ROOT/.env" && ! -f "$REPO_ROOT/.env.act" ]]; do
        REPO_ROOT="$(dirname "$REPO_ROOT")"
    done
    if [[ ! -f "$REPO_ROOT/setup.sh" && ! -d "$REPO_ROOT/.git" && ! -f "$REPO_ROOT/.env" && ! -f "$REPO_ROOT/.env.act" ]]; then
        REPO_ROOT="$(cd "$_LOAD_CONFIG_DIR/.." && pwd)"
    fi
fi

# Capture any pre-existing environment overrides before sourcing config
_PRE_ENV_FILE="${ENV_FILE:-}"
_PRE_VM_NAME="${VM_NAME:-}"
_PRE_VM_CPUS="${VM_CPUS:-}"
_PRE_VM_MEMORY="${VM_MEMORY:-}"
_PRE_OCI_BASE_IMAGE="${OCI_BASE_IMAGE:-}"
_PRE_MAPPED_DIR_FILE="${MAPPED_DIR_FILE:-}"
_PRE_SANDBOX_HOST_USER="${SANDBOX_HOST_USER:-}"

# Parse command line arguments for --env / -e or --vm / -v flags
_CLEANED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env)
            if [[ -n "${2:-}" ]]; then
                _PRE_ENV_FILE="$2"
                shift 2
            else
                shift
            fi
            ;;
        --env=*)
            _PRE_ENV_FILE="${1#*=}"
            shift
            ;;
        --vm)
            if [[ -n "${2:-}" ]]; then
                _PRE_VM_NAME="$2"
                shift 2
            else
                shift
            fi
            ;;
        --vm=*)
            _PRE_VM_NAME="${1#*=}"
            shift
            ;;
        *)
            _CLEANED_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional arguments minus extracted config flags
if [[ ${#_CLEANED_ARGS[@]} -gt 0 ]]; then
    set -- "${_CLEANED_ARGS[@]}"
else
    set --
fi

# 1. Resolve configuration file path
CONFIG_SOURCE=""
RESOLVED_ENV_FILE=""

if [[ -n "$_PRE_ENV_FILE" ]]; then
    if [[ -f "$_PRE_ENV_FILE" ]]; then
        RESOLVED_ENV_FILE="$(realpath "$_PRE_ENV_FILE")"
    elif [[ -f "${REPO_ROOT}/${_PRE_ENV_FILE}" ]]; then
        RESOLVED_ENV_FILE="$(realpath "${REPO_ROOT}/${_PRE_ENV_FILE}")"
    else
        echo "[ERROR] Specified config file '$_PRE_ENV_FILE' not found." >&2
        exit 1
    fi
    CONFIG_SOURCE="explicit CLI/ENV (--env / ENV_FILE)"
elif [[ -n "$_PRE_VM_NAME" ]]; then
    # Try to find which .env file defines this VM_NAME
    for candidate in "${REPO_ROOT}/.env.host" "${REPO_ROOT}/.env.act" "${REPO_ROOT}/.env"; do
        if [[ -f "$candidate" ]] && grep -q "VM_NAME=[\"']${_PRE_VM_NAME}[\"']" "$candidate" 2>/dev/null; then
            RESOLVED_ENV_FILE="$(realpath "$candidate")"
            CONFIG_SOURCE="auto-matched by VM_NAME='$_PRE_VM_NAME'"
            break
        fi
    done
fi

# Fallback hierarchy if still unresolved
if [[ -z "$RESOLVED_ENV_FILE" ]]; then
    # Smart check: If a VM is already registered in krunvm, check if an env file matches it
    _KRUNVM_CHECK="$(command -v krunvm 2>/dev/null || echo "${HOME}/.local/bin/krunvm")"
    if [[ -x "$_KRUNVM_CHECK" ]]; then
        _INSTALLED_VMS="$("$_KRUNVM_CHECK" list 2>/dev/null | grep -E '^[a-zA-Z0-9_-]+$' || true)"
        for _active_vm in $_INSTALLED_VMS; do
            for _candidate in "${REPO_ROOT}/.env.host" "${REPO_ROOT}/.env.act" "${REPO_ROOT}/.env"; do
                if [[ -f "$_candidate" ]] && grep -q "VM_NAME=[\"']${_active_vm}[\"']" "$_candidate" 2>/dev/null; then
                    RESOLVED_ENV_FILE="$(realpath "$_candidate")"
                    CONFIG_SOURCE="auto-matched to existing krunvm instance '${_active_vm}'"
                    break 2
                fi
            done
        done
    fi
fi

if [[ -z "$RESOLVED_ENV_FILE" ]]; then
    if [[ -f "${REPO_ROOT}/.env.host" ]]; then
        RESOLVED_ENV_FILE="$(realpath "${REPO_ROOT}/.env.host")"
        CONFIG_SOURCE="default host profile (.env.host)"
    elif [[ -f "${REPO_ROOT}/.env" ]]; then
        RESOLVED_ENV_FILE="$(realpath "${REPO_ROOT}/.env")"
        CONFIG_SOURCE="standard profile (.env)"
    elif [[ -f "${REPO_ROOT}/.env.act" ]]; then
        RESOLVED_ENV_FILE="$(realpath "${REPO_ROOT}/.env.act")"
        CONFIG_SOURCE="act CI runner profile (.env.act)"
    fi
fi

if [[ -z "$RESOLVED_ENV_FILE" || ! -f "$RESOLVED_ENV_FILE" ]]; then
    echo "[ERROR] No configuration file (.env.host, .env, .env.act) found in $REPO_ROOT." >&2
    echo "        Please copy .env.example to .env: cp .env.example .env" >&2
    exit 1
fi

ENV_FILE="$RESOLVED_ENV_FILE"

# 2. Source Configuration
# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

# 3. Apply and Track Overrides
OVERRIDES=()
if [[ -n "$_PRE_VM_NAME" && "$_PRE_VM_NAME" != "${VM_NAME:-}" ]]; then
    OVERRIDES+=("VM_NAME: '${VM_NAME:-}' -> '$_PRE_VM_NAME'")
    VM_NAME="$_PRE_VM_NAME"
fi
if [[ -n "$_PRE_VM_CPUS" && "$_PRE_VM_CPUS" != "${VM_CPUS:-}" ]]; then
    OVERRIDES+=("VM_CPUS: '${VM_CPUS:-}' -> '$_PRE_VM_CPUS'")
    VM_CPUS="$_PRE_VM_CPUS"
fi
if [[ -n "$_PRE_VM_MEMORY" && "$_PRE_VM_MEMORY" != "${VM_MEMORY:-}" ]]; then
    OVERRIDES+=("VM_MEMORY: '${VM_MEMORY:-}' -> '$_PRE_VM_MEMORY'")
    VM_MEMORY="$_PRE_VM_MEMORY"
fi
if [[ -n "$_PRE_OCI_BASE_IMAGE" && "$_PRE_OCI_BASE_IMAGE" != "${OCI_BASE_IMAGE:-}" ]]; then
    OVERRIDES+=("OCI_BASE_IMAGE: '${OCI_BASE_IMAGE:-}' -> '$_PRE_OCI_BASE_IMAGE'")
    OCI_BASE_IMAGE="$_PRE_OCI_BASE_IMAGE"
fi
if [[ -n "$_PRE_MAPPED_DIR_FILE" && "$_PRE_MAPPED_DIR_FILE" != "${MAPPED_DIR_FILE:-}" ]]; then
    OVERRIDES+=("MAPPED_DIR_FILE: '${MAPPED_DIR_FILE:-}' -> '$_PRE_MAPPED_DIR_FILE'")
    MAPPED_DIR_FILE="$_PRE_MAPPED_DIR_FILE"
fi
if [[ -n "$_PRE_SANDBOX_HOST_USER" && "$_PRE_SANDBOX_HOST_USER" != "${SANDBOX_HOST_USER:-}" ]]; then
    OVERRIDES+=("SANDBOX_HOST_USER: '${SANDBOX_HOST_USER:-}' -> '$_PRE_SANDBOX_HOST_USER'")
    SANDBOX_HOST_USER="$_PRE_SANDBOX_HOST_USER"
fi

# Ensure default fallback values
VM_NAME="${VM_NAME:-krun-act-runner}"
MAPPED_DIR_FILE="${MAPPED_DIR_FILE:-${REPO_ROOT}/.env.mapped_dir}"

# 4. Print Clear Configuration Log
echo "=========================================================================="
echo " [CONFIG SSOT] Configuration Loaded"
echo " Configuration File : $ENV_FILE"
echo " Selection Source   : $CONFIG_SOURCE"
echo " Target MicroVM     : $VM_NAME"
if [[ -n "${OCI_BASE_IMAGE:-}" ]]; then
    echo " Base OCI Image     : $OCI_BASE_IMAGE"
fi
if [[ -n "${VM_CPUS:-}" && -n "${VM_MEMORY:-}" ]]; then
    echo " Sizing             : $VM_CPUS vCPUs / $VM_MEMORY MiB RAM"
fi
if [[ -f "$MAPPED_DIR_FILE" ]]; then
    echo " Volume Mappings    : $MAPPED_DIR_FILE (active)"
elif [[ -n "${VOLUMES:-}" ]]; then
    echo " Volume Mappings    : VOLUMES defined in $ENV_FILE"
fi

if [[ ${#OVERRIDES[@]} -gt 0 ]]; then
    echo "--------------------------------------------------------------------------"
    echo " [CONFIG OVERRIDES APPLIED]:"
    for ov in "${OVERRIDES[@]}"; do
        echo "   - $ov"
    done
fi
echo "=========================================================================="
