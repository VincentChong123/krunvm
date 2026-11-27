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

# 3. Apply Git Configuration, Hooks & Pre-commit
if [ -f "$DOTFILES_SRC/dot_gitconfig" ]; then
    cp -f "$DOTFILES_SRC/dot_gitconfig" "${TARGET_HOME}/.gitconfig"
fi
if [ -d "$DOTFILES_SRC/dot_config/git" ]; then
    mkdir -p "${TARGET_HOME}/.config/git"
    [ -f "$DOTFILES_SRC/dot_config/git/dot_commitlintrc.json" ] && cp -f "$DOTFILES_SRC/dot_config/git/dot_commitlintrc.json" "${TARGET_HOME}/.config/git/.commitlintrc.json"
    if [ -d "$DOTFILES_SRC/dot_config/git/hooks" ]; then
        cp -rf "$DOTFILES_SRC/dot_config/git/hooks" "${TARGET_HOME}/.config/git/"
        chmod +x "${TARGET_HOME}/.config/git/hooks/"* 2>/dev/null || true
    fi
fi
if [ -d "$DOTFILES_SRC/dot_config/pre-commit" ]; then
    mkdir -p "${TARGET_HOME}/.config/pre-commit"
    [ -f "$DOTFILES_SRC/dot_config/pre-commit/config.yaml" ] && cp -f "$DOTFILES_SRC/dot_config/pre-commit/config.yaml" "${TARGET_HOME}/.config/pre-commit/"
    [ -f "$DOTFILES_SRC/dot_config/pre-commit/dot_yamllint" ] && cp -f "$DOTFILES_SRC/dot_config/pre-commit/dot_yamllint" "${TARGET_HOME}/.config/pre-commit/.yamllint"
    if [ -d "$DOTFILES_SRC/dot_config/pre-commit/dot_trufflehog" ]; then
        cp -rf "$DOTFILES_SRC/dot_config/pre-commit/dot_trufflehog" "${TARGET_HOME}/.config/pre-commit/.trufflehog"
    fi
fi

# 4. Apply Bash Shell & Aliases SSOT
if [ -f "$DOTFILES_SRC/dot_bashrc" ]; then
    cp -f "$DOTFILES_SRC/dot_bashrc" "${TARGET_HOME}/.bashrc"
elif [ -f "$DOTFILES_SRC/dot_zshrc" ]; then
    sed -i '/--- Centralized Shell Aliases from Dotfiles SSOT ---/,/alias precommit-check=pc-check/d' "${TARGET_HOME}/.bashrc" 2>/dev/null || true
    cat << 'EOF' >> "${TARGET_HOME}/.bashrc"

# --- Centralized Shell Aliases from Dotfiles SSOT ---
alias agy-yolo="agy --dangerously-skip-permissions --sandbox"

pc-check() {
    local central_dir="${HOME}/.config/pre-commit"
    [[ ! -d "$central_dir" && -d "${XDG_CONFIG_HOME:-}/pre-commit" ]] && central_dir="${XDG_CONFIG_HOME}/pre-commit"
    local cfg=".pre-commit-config.yaml"
    if [ ! -f "$cfg" ]; then
        cfg="${central_dir}/config.yaml"
    fi

    local temp_truffle=0
    if [ ! -d ".trufflehog" ] && [ -d "${central_dir}/.trufflehog" ]; then
        ln -s "${central_dir}/.trufflehog" .trufflehog
        temp_truffle=1
    fi

    local temp_yamllint=0
    if [ ! -f ".yamllint" ] && [ -f "${central_dir}/.yamllint" ]; then
        ln -s "${central_dir}/.yamllint" .yamllint
        temp_yamllint=1
    fi

    local exit_code=0
    if [ $# -eq 0 ]; then
        pre-commit run --config "$cfg"
        exit_code=$?
    else
        pre-commit run --config "$cfg" "$@"
        exit_code=$?
    fi

    [ "$temp_truffle" -eq 1 ] && rm -f .trufflehog
    [ "$temp_yamllint" -eq 1 ] && rm -f .yamllint

    return $exit_code
}
alias pc-all="pc-check --all-files"
alias precommit-check=pc-check
EOF
fi

echo "    [OK] Shell completion, dotfiles and git configuration synchronized."
