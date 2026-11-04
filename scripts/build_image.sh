#!/usr/bin/env bash
# ==============================================================================
# build_image.sh - Build the base OCI image for krunvm sandboxes via buildah
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_TAG="${1:-localhost/krun-agent-sandbox:latest}"
CONTAINERFILE="${REPO_ROOT}/configs/Containerfile"

if [[ ! -f "$CONTAINERFILE" ]]; then
    echo "[ERROR] Containerfile not found at '$CONTAINERFILE'." >&2
    exit 1
fi

echo "=========================================================================="
echo " Building Base OCI Sandbox Image"
echo " Image Tag:     $IMAGE_TAG"
echo " Containerfile: $CONTAINERFILE"
echo "=========================================================================="

if command -v buildah >/dev/null 2>&1; then
    BUILD_TOOL="buildah"
elif command -v podman >/dev/null 2>&1; then
    BUILD_TOOL="podman"
elif command -v docker >/dev/null 2>&1; then
    BUILD_TOOL="docker"
else
    echo "[ERROR] No container builder (buildah, podman, or docker) found on host." >&2
    echo "        Please install buildah: sudo apt install -y buildah" >&2
    exit 1
fi

echo "==> Using builder: $BUILD_TOOL..."
case "$BUILD_TOOL" in
    buildah)
        buildah bud -f "$CONTAINERFILE" -t "$IMAGE_TAG" "$REPO_ROOT"
        ;;
    podman)
        podman build -f "$CONTAINERFILE" -t "$IMAGE_TAG" "$REPO_ROOT"
        ;;
    docker)
        docker build -f "$CONTAINERFILE" -t "$IMAGE_TAG" "$REPO_ROOT"
        ;;
esac

echo "==> OCI image '$IMAGE_TAG' built successfully."
