#!/bin/bash
set -euo pipefail

echo "=== 1. Checking /home/ubuntu symlinks ==="
ls -l /home/ubuntu

echo "=== 2. Testing RO on /krunvm ==="
touch /krunvm/test_fail 2>&1 || echo "Write to /krunvm blocked (Read-only) as requested!"

echo "=== 3. Testing RO on /31_obsidian ==="
touch /31_obsidian/test_fail 2>&1 || echo "Write to /31_obsidian blocked (Read-only) as requested!"

echo "=== 4. Testing RW on /doc-micro-access-ctr ==="
touch /doc-micro-access-ctr/test_ok && rm -f /doc-micro-access-ctr/test_ok && echo "RW to /doc-micro-access-ctr verified!"

echo "=== 5. Checking guest telemetry secrets ==="
ls -la /home/ubuntu/.gemini/antigravity-cli/.env

echo "=== 6. Checking Antigravity CLI ==="
agy --version

echo "=== 7. Checking Nested Docker CLI Execution ==="
docker run --rm --net=host docker.io/library/alpine:latest uname -a
