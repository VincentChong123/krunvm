#!/usr/bin/env bash
# ==============================================================================
# build_krunvm_host.sh - Automated from-source compiler for libkrun & krunvm
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DEPS_DIR="${REPO_ROOT}/src_deps"
PREFIX="${PREFIX:-$HOME/.local}"

# Resolve host multiarch subdirectory (e.g. x86_64-linux-gnu)
HOST_ARCH="$(uname -m)"
if [[ -e /etc/debian_version ]]; then
    ARCH_LIBDIR="lib/${HOST_ARCH}-linux-gnu"
else
    ARCH_LIBDIR="lib64"
fi

mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/${ARCH_LIBDIR}" "$PREFIX/lib64" "$PREFIX/include"
mkdir -p "$PREFIX/${ARCH_LIBDIR}/pkgconfig" "$PREFIX/lib/pkgconfig" "$PREFIX/lib64/pkgconfig"
mkdir -p "$SRC_DEPS_DIR"

# ------------------------------------------------------------------------------
# 0. Environment Setup & Toolchain Hotfixes
# ------------------------------------------------------------------------------
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib64/pkgconfig:$PREFIX/${ARCH_LIBDIR}/pkgconfig:$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$PREFIX/lib64:$PREFIX/${ARCH_LIBDIR}:$PREFIX/lib:${LD_LIBRARY_PATH:-}"
export RUSTFLAGS="-L $PREFIX/lib64 -L $PREFIX/${ARCH_LIBDIR} -L $PREFIX/lib ${RUSTFLAGS:-}"

# Fix 1: Ensure musl target is installed for krun-init blob
if command -v rustup >/dev/null 2>&1; then
    rustup target add "${HOST_ARCH}-unknown-linux-musl" >/dev/null 2>&1 || true
fi

# Fix 2: Provide unversioned libclang.so symlink if only versioned runtime exists
if [[ ! -f "$PREFIX/lib/libclang.so" ]]; then
    HOST_LIBCLANG="$(find /usr/lib -name "libclang-*.so.*" 2>/dev/null | head -n1 || true)"
    if [[ -n "$HOST_LIBCLANG" ]]; then
        ln -sf "$HOST_LIBCLANG" "$PREFIX/lib/libclang.so"
    fi
fi
export LIBCLANG_PATH="$PREFIX/lib"

# Fix 3: Point bindgen to GCC compiler internal headers (stddef.h)
GCC_INC_DIR="$(gcc -print-file-name=include 2>/dev/null || true)"
if [[ -d "$GCC_INC_DIR" ]]; then
    export BINDGEN_EXTRA_CLANG_ARGS="-I$GCC_INC_DIR"
fi

# Fix 4: Stub asciidoctor man-page generator if asciidoctor is not installed
if ! command -v asciidoctor >/dev/null 2>&1; then
    cat <<'EOF_ASCII' > "$PREFIX/bin/asciidoctor"
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-o" || "$1" == "--out-file" ]]; then
        touch "$2"
        exit 0
    fi
    shift
done
exit 0
EOF_ASCII
    chmod +x "$PREFIX/bin/asciidoctor"
fi

echo "=========================================================================="
echo " Building libkrunfw, libkrun, and krunvm for Host Workstation"
echo " Installation Prefix: $PREFIX"
echo " Build Directory:     $SRC_DEPS_DIR"
echo "=========================================================================="

NPROC="$(nproc 2>/dev/null || echo 4)"

# ------------------------------------------------------------------------------
# 1. Build and Install libkrunfw (Embedded Minimal Linux Kernel & Firmware)
# ------------------------------------------------------------------------------
echo ""
echo "==> [1/3] Cloning and building libkrunfw..."
if [[ ! -d "${SRC_DEPS_DIR}/libkrunfw" ]]; then
    git clone --depth 1 https://github.com/libkrun/libkrunfw.git "${SRC_DEPS_DIR}/libkrunfw"
fi

(
    cd "${SRC_DEPS_DIR}/libkrunfw"
    make -j"$NPROC" PREFIX="$PREFIX"
    make install PREFIX="$PREFIX"
)
echo "==> libkrunfw installed."

# ------------------------------------------------------------------------------
# 2. Build and Install libkrun v1.19.7 (Stable C API for krunvm)
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/3] Cloning and building libkrun (v1.19.7)..."
if [[ ! -d "${SRC_DEPS_DIR}/libkrun" ]]; then
    git clone --depth 1 --branch v1.19.7 https://github.com/libkrun/libkrun.git "${SRC_DEPS_DIR}/libkrun"
else
    (
        cd "${SRC_DEPS_DIR}/libkrun"
        git fetch --tags || true
        git checkout v1.19.7 || true
    )
fi

(
    cd "${SRC_DEPS_DIR}/libkrun"
    make -j"$NPROC" PREFIX="$PREFIX"
    make install PREFIX="$PREFIX"
)

# Cross-link library paths so dynamic loader finds libkrun regardless of multiarch conventions
ln -sf "$PREFIX/lib64"/libkrun.so* "$PREFIX/lib/" 2>/dev/null || true
ln -sf "$PREFIX/lib64"/libkrun.so* "$PREFIX/${ARCH_LIBDIR}/" 2>/dev/null || true
ln -sf "$PREFIX/lib64/pkgconfig"/libkrun.pc "$PREFIX/lib/pkgconfig/" 2>/dev/null || true
ln -sf "$PREFIX/lib64/pkgconfig"/libkrun.pc "$PREFIX/${ARCH_LIBDIR}/pkgconfig/" 2>/dev/null || true
echo "==> libkrun installed."

# ------------------------------------------------------------------------------
# 3. Build and Install krunvm CLI (OCI Container MicroVM Engine)
# ------------------------------------------------------------------------------
echo ""
echo "==> [3/3] Cloning and building krunvm CLI..."
if [[ ! -d "${SRC_DEPS_DIR}/krunvm" ]]; then
    git clone --depth 1 https://github.com/libkrun/krunvm.git "${SRC_DEPS_DIR}/krunvm"
fi

(
    cd "${SRC_DEPS_DIR}/krunvm"
    cargo build --release
    cp target/release/krunvm "$PREFIX/bin/krunvm-bin"
    chmod +x "$PREFIX/bin/krunvm-bin"
)

# Install rootless user namespace auto-wrapper
cat <<'EOF_WRAPPER' > "$PREFIX/bin/krunvm"
#!/usr/bin/env bash
export LD_LIBRARY_PATH="/home/vin/.local/lib64:/home/vin/.local/lib:${LD_LIBRARY_PATH:-}"
if [[ "${_CONTAINERS_USERNS_CONFIGURED:-}" != "done" ]]; then
    exec buildah unshare -- "$0" "$@"
else
    exec "$HOME/.local/bin/krunvm-bin" "$@"
fi
EOF_WRAPPER
chmod +x "$PREFIX/bin/krunvm"

echo ""
echo "=========================================================================="
echo " Build and Installation Complete!"
echo " krunvm binary: $PREFIX/bin/krunvm"
echo "=========================================================================="
echo "Ensure your ~/.bashrc or shell profile contains the following exports:"
echo ""
echo "    export PATH=\"$PREFIX/bin:\$PATH\""
echo "    export LD_LIBRARY_PATH=\"$PREFIX/lib64:$PREFIX/lib:\$LD_LIBRARY_PATH\""
echo "=========================================================================="
