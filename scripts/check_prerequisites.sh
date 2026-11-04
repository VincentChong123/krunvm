#!/usr/bin/env bash
# ==============================================================================
# check_prerequisites.sh - Pre-flight environment check for krunvm host
# ==============================================================================

set -euo pipefail

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo "==> Running Host Prerequisites Check for krunvm on $(uname -s) $(uname -r)..."
FAILED=0

# 1. Check KVM Virtualization
echo -n "Checking /dev/kvm access... "
if [[ -e /dev/kvm ]]; then
    if [[ -w /dev/kvm ]]; then
        echo -e "${GREEN}OK (Writable)${NC}"
    else
        echo -e "${RED}FAILED (/dev/kvm exists but is not writable by current user)${NC}"
        echo "    Tip: Add your user to the kvm group: sudo usermod -aG kvm $USER"
        FAILED=1
    fi
else
    echo -e "${RED}FAILED (/dev/kvm not found)${NC}"
    echo "    Tip: Verify hardware virtualization (VT-x/AMD-V) is enabled in BIOS"
    FAILED=1
fi

# 2. Check Rust & Cargo
echo -n "Checking Rust toolchain (cargo)... "
if command -v cargo >/dev/null 2>&1; then
    CARGO_VER="$(cargo --version)"
    echo -e "${GREEN}OK ($CARGO_VER)${NC}"
else
    echo -e "${RED}FAILED (cargo not found)${NC}"
    echo "    Tip: Install Rust via: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    FAILED=1
fi

# 3. Check C Compiler and Make
for bin in gcc make; do
    echo -n "Checking $bin... "
    if command -v "$bin" >/dev/null 2>&1; then
        echo -e "${GREEN}OK ($($bin --version | head -n1))${NC}"
    else
        echo -e "${RED}FAILED ($bin not found)${NC}"
        FAILED=1
    fi
done

# 4. Check Build Dependencies for libkrun / libkrunfw
MISSING_APT_PACKAGES=()
for tool in pkg-config flex bison; do
    echo -n "Checking $tool... "
    if command -v "$tool" >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Missing${NC}"
        MISSING_APT_PACKAGES+=("$tool")
    fi
done

# Check buildah
echo -n "Checking buildah... "
if command -v buildah >/dev/null 2>&1; then
    echo -e "${GREEN}OK ($(buildah --version))${NC}"
else
    echo -e "${YELLOW}Missing (Required for OCI image rootfs parsing)${NC}"
    MISSING_APT_PACKAGES+=("buildah")
fi

# Check pyelftools
echo -n "Checking python3 pyelftools... "
if python3 -c "import elftools" >/dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}Missing (Required by libkrunfw kernel build)${NC}"
    MISSING_APT_PACKAGES+=("python3-pyelftools")
fi

# 5. Check krunvm and libkrun runtime binaries
echo -n "Checking krunvm binary... "
if command -v krunvm >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/krunvm" ]]; then
    KRUN_PATH="$(command -v krunvm 2>/dev/null || echo "${HOME}/.local/bin/krunvm")"
    echo -e "${GREEN}OK ($KRUN_PATH)${NC}"
else
    echo -e "${YELLOW}Not installed yet (Run scripts/build_krunvm_host.sh)${NC}"
fi

echo ""
if [[ ${#MISSING_APT_PACKAGES[@]} -gt 0 ]]; then
    echo -e "${YELLOW}[ACTION REQUIRED] Missing system build packages detected.${NC}"
    echo "Run the following command on your host to install prerequisites:"
    echo ""
    echo "    sudo apt update && sudo apt install -y build-essential libelf-dev libssl-dev ${MISSING_APT_PACKAGES[*]}"
    echo ""
fi

if [[ $FAILED -ne 0 ]]; then
    echo -e "${RED}Host prerequisites check failed. Please resolve critical errors above.${NC}"
    exit 1
fi

echo -e "${GREEN}Host prerequisites check completed successfully.${NC}"
