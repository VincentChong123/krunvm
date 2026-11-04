#!/bin/bash
# Test OCI / Docker container execution inside krunvm microVM
set -euo pipefail

echo "===> Testing Docker CLI Emulation (via Podman + crun):"
docker --version

echo "===> Testing Alpine Container Run:"
docker run --rm --net=host docker.io/library/alpine:latest uname -a

echo "===> Testing Network Egress inside Container:"
docker run --rm --net=host docker.io/library/alpine:latest wget -qO- https://httpbin.org/get | grep -E 'origin|Host'
