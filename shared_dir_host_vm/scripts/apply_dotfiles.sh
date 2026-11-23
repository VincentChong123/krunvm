#!/usr/bin/env bash
# ==============================================================================
# apply_dotfiles.sh - Apply read-only mounted dotfiles inside krunvm microVM
# ==============================================================================
# 1. Enforces read-only kernel filesystem mode on /dotfiles (:ro).
# 2. Synchronizes core Git configuration and centralized hooks.
# 3. Enables bash auto-completion and centralized shell aliases.
# ==============================================================================

set -euo pipefail

DOTFILES_SRC="${1:-/dotfiles}"

if [ ! -d "$DOTFILES_SRC" ]; then
    if [ -d "${HOME}/ws/github/VincentChong123/dotfiles" ]; then
        DOTFILES_SRC="${HOME}/ws/github/VincentChong123/dotfiles"
    else
        echo "[INFO] No read-only dotfiles mount found at /dotfiles or ~/ws/.../dotfiles. Skipping."
        exit 0
    fi
fi

# 1. Enforce Kernel Read-Only Protection on /dotfiles
if [ -d "/dotfiles" ]; then
    mount -o remount,ro /dotfiles 2>/dev/null || true
fi

echo "==> Applying dotfiles from read-only SSOT: $DOTFILES_SRC"
TARGET_HOME="${HOME:-/root}"

# 2. Ensure bash-completion is active in .bashrc
if [ -f /etc/bash_completion ] && ! grep -q "bash_completion" "${TARGET_HOME}/.bashrc" 2>/dev/null; then
    cat << 'EOF' >> "${TARGET_HOME}/.bashrc"

# Enable bash completion
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi
EOF
fi

# 3. Apply Git Configuration & Hooks
if [ -f "$DOTFILES_SRC/dot_gitconfig" ]; then
    cp -f "$DOTFILES_SRC/dot_gitconfig" "${TARGET_HOME}/.gitconfig"
fi
if [ -d "$DOTFILES_SRC/dot_config/git/hooks" ]; then
    mkdir -p "${TARGET_HOME}/.config/git"
    cp -rf "$DOTFILES_SRC/dot_config/git/hooks" "${TARGET_HOME}/.config/git/"
    chmod +x "${TARGET_HOME}/.config/git/hooks/"* 2>/dev/null || true
fi

# 4. Apply Bash Shell & Aliases SSOT
if [ -f "$DOTFILES_SRC/dot_bashrc" ]; then
    cp -f "$DOTFILES_SRC/dot_bashrc" "${TARGET_HOME}/.bashrc"
elif [ -f "$DOTFILES_SRC/dot_zshrc" ]; then
    if ! grep -q "pc-check()" "${TARGET_HOME}/.bashrc" 2>/dev/null; then
        cat << 'EOF' >> "${TARGET_HOME}/.bashrc"

# --- Centralized Shell Aliases from Dotfiles SSOT ---
alias agy-yolo="agy --dangerously-skip-permissions --sandbox"

pc-check() {
    local infra_dir="${HOME}/ws/github/winwinteam/local-infra"
    if [ -d "/local-infra" ]; then
        infra_dir="/local-infra"
    fi
    local cfg="${infra_dir}/.pre-commit-config.yaml"
    local truffle="${infra_dir}/.trufflehog"
    local temp_link=0

    if [ ! -d ".trufflehog" ] && [ -d "$truffle" ]; then
        ln -s "$truffle" .trufflehog
        temp_link=1
    fi

    local exit_code=0
    if [ $# -eq 0 ]; then
        pre-commit run --config "$cfg"
        exit_code=$?
    else
        pre-commit run --config "$cfg" "$@"
        exit_code=$?
    fi

    if [ "$temp_link" -eq 1 ]; then
        rm -f .trufflehog
    fi

    return $exit_code
}
alias pc-all="pc-check --all-files"
alias precommit-check=pc-check
EOF
    fi
fi

echo "    [OK] Shell completion, dotfiles and git configuration synchronized."
