#!/usr/bin/env bash
# ==============================================================================
# ensure-sshd.sh - Lightweight idempotent check to ensure PTY devices,
# AF_TSI port=0 preload library, and sshd daemon are active in krunvm.
# ==============================================================================
mkdir -p /dev/pts /run/sshd
chmod 0755 /run/sshd 2>/dev/null || true

if [ ! -e /dev/ptmx ] || [ ! -c /dev/ptmx ]; then
    rm -f /dev/ptmx
    ln -s /dev/pts/ptmx /dev/ptmx 2>/dev/null || mknod /dev/ptmx c 5 2 2>/dev/null || true
fi
chmod 666 /dev/ptmx /dev/pts/ptmx 2>/dev/null || true

if [ -f /usr/local/lib/libkrun_tsi_fix.so ]; then
    if ! grep -qxF "/usr/local/lib/libkrun_tsi_fix.so" /etc/ld.so.preload 2>/dev/null; then
        echo "/usr/local/lib/libkrun_tsi_fix.so" >> /etc/ld.so.preload
    fi
fi

if ! pgrep -x sshd >/dev/null 2>&1; then
    setsid /usr/sbin/sshd -E /var/log/sshd.log </dev/null >/dev/null 2>&1
fi
