#!/usr/bin/env bash
# ==============================================================================
# build_image.sh - Build the base OCI image for krunvm sandboxes via buildah
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_TAG="${1:-localhost/krun-agent-sandbox:latest}"
if [[ -f "${REPO_ROOT}/configs/Dockerfile" ]]; then
    DOCKERFILE="${REPO_ROOT}/configs/Dockerfile"
elif [[ -f "${REPO_ROOT}/configs/dockerfile" ]]; then
    DOCKERFILE="${REPO_ROOT}/configs/dockerfile"
elif [[ -f "${REPO_ROOT}/configs/Containerfile" ]]; then
    DOCKERFILE="${REPO_ROOT}/configs/Containerfile"
else
    echo "[ERROR] Dockerfile not found at '${REPO_ROOT}/configs/Dockerfile'." >&2
    exit 1
fi

echo "=========================================================================="
echo " Building Base OCI Sandbox Image"
echo " Image Tag:     $IMAGE_TAG"
echo " Dockerfile:    $DOCKERFILE"
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
        buildah bud -f "$DOCKERFILE" -t "$IMAGE_TAG" "$REPO_ROOT"
        ;;
    podman)
        podman build -f "$DOCKERFILE" -t "$IMAGE_TAG" "$REPO_ROOT"
        ;;
    docker)
        docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" "$REPO_ROOT"
        ;;
esac

echo "==> OCI image '$IMAGE_TAG' built successfully."
