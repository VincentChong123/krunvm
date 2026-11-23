#!/usr/bin/env bash
# ==============================================================================
# install_agy.sh - On-Demand Installer for Antigravity CLI (agy)
# ==============================================================================
# Installs Antigravity CLI post-build into the persistent sandbox microVM
# without blocking or destabilizing the base OCI image build process.
# ==============================================================================

set -euo pipefail

TARGET_DIR="${1:-/usr/local/bin}"
INSTALL_URL="https://antigravity.google/cli/install.sh"

echo "=========================================================================="
echo " Antigravity CLI (agy) On-Demand Installer"
echo " Target Directory: $TARGET_DIR"
echo " Installer URL:    $INSTALL_URL"
echo "=========================================================================="

if command -v agy >/dev/null 2>&1; then
    echo "==> Antigravity CLI is already installed: $(which agy)"
    agy --version || true
    echo "==> Done."
    exit 0
fi

# Determine if sudo is needed for TARGET_DIR
SUDO_CMD=""
if [[ ! -w "$TARGET_DIR" ]]; then
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO_CMD="sudo"
        else
            echo "[WARN] Target directory '$TARGET_DIR' is not writable and sudo is unavailable."
            TARGET_DIR="${HOME}/.local/bin"
            mkdir -p "$TARGET_DIR"
            echo "       Falling back to '$TARGET_DIR'."
        fi
    fi
fi

echo "==> Downloading Antigravity installer..."
TEMP_SCRIPT="$(mktemp /tmp/agy_install_XXXXXX.sh)"
trap 'rm -f "$TEMP_SCRIPT"' EXIT

if ! curl --connect-timeout 15 --retry 3 --progress-bar -fSL "$INSTALL_URL" -o "$TEMP_SCRIPT"; then
    echo "[ERROR] Failed to download installer from '$INSTALL_URL'." >&2
    echo "        Please check network access and firewall settings." >&2
    exit 1
fi

chmod +x "$TEMP_SCRIPT"

echo "==> Executing installer into '$TARGET_DIR'..."
if [[ -n "$SUDO_CMD" ]]; then
    $SUDO_CMD bash "$TEMP_SCRIPT" --dir "$TARGET_DIR"
else
    bash "$TEMP_SCRIPT" --dir "$TARGET_DIR"
fi

if [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
    export PATH="${TARGET_DIR}:${PATH}"
fi

if command -v agy >/dev/null 2>&1 || [[ -x "${TARGET_DIR}/agy" ]]; then
    echo "=========================================================================="
    echo " [SUCCESS] Antigravity CLI installed successfully!"
    "${TARGET_DIR}/agy" --version 2>/dev/null || true
    echo "=========================================================================="
else
    echo "[WARN] Installation finished, but 'agy' was not found at '${TARGET_DIR}/agy'."
    exit 1
fi
