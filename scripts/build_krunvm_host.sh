#!/usr/bin/env bash
# ==============================================================================
# build_krunvm_host.sh - Automated from-source compiler for libkrun & krunvm
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DEPS_DIR="${REPO_ROOT}/src_deps"
PREFIX="${PREFIX:-$HOME/.local}"

mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/lib/pkgconfig"
mkdir -p "$SRC_DEPS_DIR"

export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:${LD_LIBRARY_PATH:-}"

echo "=========================================================================="
echo " Building libkrunfw, libkrun, and krunvm for Host Workstation"
echo " Installation Prefix: $PREFIX"
echo " Build Directory:     $SRC_DEPS_DIR"
echo "=========================================================================="

# Check build prerequisites first
if ! bash "${SCRIPT_DIR}/check_prerequisites.sh"; then
    echo "[ERROR] Missing system prerequisites. Please install required packages before proceeding." >&2
    exit 1
fi

NPROC="$(nproc 2>/dev/null || echo 4)"

# ------------------------------------------------------------------------------
# 1. Build and Install libkrunfw (Embedded Minimal Linux Kernel & Firmware)
# ------------------------------------------------------------------------------
echo ""
echo "==> [1/3] Cloning and building libkrunfw..."
if [[ ! -d "${SRC_DEPS_DIR}/libkrunfw" ]]; then
    git clone --depth 1 https://github.com/libkrun/libkrunfw.git "${SRC_DEPS_DIR}/libkrunfw"
else
    echo "    Pulling latest changes in ${SRC_DEPS_DIR}/libkrunfw..."
    (cd "${SRC_DEPS_DIR}/libkrunfw" && git pull --rebase || true)
fi

echo "    Compiling libkrunfw with $NPROC parallel jobs..."
(
    cd "${SRC_DEPS_DIR}/libkrunfw"
    make -j"$NPROC" PREFIX="$PREFIX"
    make install PREFIX="$PREFIX"
)
echo "==> libkrunfw installed to $PREFIX/lib."

# ------------------------------------------------------------------------------
# 2. Build and Install libkrun (Lightweight MicroVM Monitor Library)
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/3] Cloning and building libkrun..."
if [[ ! -d "${SRC_DEPS_DIR}/libkrun" ]]; then
    git clone --depth 1 https://github.com/libkrun/libkrun.git "${SRC_DEPS_DIR}/libkrun"
else
    echo "    Pulling latest changes in ${SRC_DEPS_DIR}/libkrun..."
    (cd "${SRC_DEPS_DIR}/libkrun" && git pull --rebase || true)
fi

echo "    Compiling libkrun..."
(
    cd "${SRC_DEPS_DIR}/libkrun"
    make -j"$NPROC" PREFIX="$PREFIX"
    make install PREFIX="$PREFIX"
)
echo "==> libkrun installed to $PREFIX/lib."

# ------------------------------------------------------------------------------
# 3. Build and Install krunvm CLI (OCI Container MicroVM Engine)
# ------------------------------------------------------------------------------
echo ""
echo "==> [3/3] Cloning and building krunvm CLI..."
if [[ ! -d "${SRC_DEPS_DIR}/krunvm" ]]; then
    git clone --depth 1 https://github.com/libkrun/krunvm.git "${SRC_DEPS_DIR}/krunvm"
else
    echo "    Pulling latest changes in ${SRC_DEPS_DIR}/krunvm..."
    (cd "${SRC_DEPS_DIR}/krunvm" && git pull --rebase || true)
fi

echo "    Compiling krunvm with Cargo..."
(
    cd "${SRC_DEPS_DIR}/krunvm"
    cargo build --release
    cp target/release/krunvm "$PREFIX/bin/krunvm"
    chmod +x "$PREFIX/bin/krunvm"
)

echo ""
echo "=========================================================================="
echo " Build and Installation Complete!"
echo " krunvm binary: $PREFIX/bin/krunvm"
echo "=========================================================================="
echo "Ensure your ~/.bashrc or shell profile contains the following exports:"
echo ""
echo "    export PATH=\"$PREFIX/bin:\$PATH\""
echo "    export LD_LIBRARY_PATH=\"$PREFIX/lib:\$LD_LIBRARY_PATH\""
echo "=========================================================================="
