# Walkthrough: `krunvm` VS Code Remote-SSH Fix & Host PC Scripts

## 1. Root Cause Summary

1. **`libkrunfw` `AF_TSI` (`tsi_hijack`) Ephemeral `port=0` Kernel Bug:**
   - When VS Code Remote-SSH started `code-server --host=127.0.0.1 --port=0`, Node.js called `bind("127.0.0.1", 0)` and `listen()`.
   - In `libkrunfw`'s kernel (`net/tsi/af_tsi.c`), `tsi_bind()` bound the guest-internal socket (`isock`) to `127.0.0.1:0` (allocating an ephemeral port such as `39707`), **but saved the original `sockaddr` with `sin_port = 0` into `tsi->addr`**.
   - When `tsi_listen()` ran, it sent `TSI_LISTEN` with `sin_port = 0` to `libkrun` on the Host PC, which bound a *different* random port on the Host PC and returned `0`, causing `tsi_listen()` to skip `isock->ops->listen()`.
   - `getsockname()` returned `isock`'s non-listening port (`39707`), causing `sshd` port forwarding (`connect to 127.0.0.1 port 39707`) to fail with `Connection refused`.
2. **`ss -tlpn` False Negatives Under `AF_TSI`:**
   - Because `AF_TSI` sockets use `PF_TSI` rather than standard `PF_INET` (`/proc/net/tcp` has `0` entries), `ss -tlpn | grep :22` falsely reported `sshd` as down and spawned duplicate `sshd` instances.

---

## 2. Changes Made

### Guest VM (`/shared_dir_host_vm/ssh/`)
- **[libkrun_tsi_fix.c](file:///shared_dir_host_vm/ssh/libkrun_tsi_fix.c)** (`/usr/local/lib/libkrun_tsi_fix.so` in `/etc/ld.so.preload`):
  - Intercepts glibc `bind()` for `SOCK_STREAM` `AF_INET`/`AF_INET6` sockets when `sin_port == 0` and substitutes an explicit non-zero port in `20000..32000` (retrying on `EADDRINUSE`).
  - Fixes `code-server --port=0` as well as all VS Code child processes (`McpGatewayService`, debuggers, language servers, Jupyter).
- **[setup_vscode.sh](file:///shared_dir_host_vm/ssh/setup_vscode.sh)**:
  - Compiles and installs `/usr/local/lib/libkrun_tsi_fix.so` into `/etc/ld.so.preload`.
  - Installs `/usr/local/bin/ensure-sshd.sh` and hooks it into `/etc/bash.bashrc` so `/dev/ptmx`, `/etc/ld.so.preload`, and `sshd` start automatically whenever the VM boots.
  - Verifies `sshd` via its `/proc/<pid>/fd` `AF_TSI` socket and a live round-trip banner check on `127.0.0.1:2222`.
- **[check_vscode_health.sh](file:///shared_dir_host_vm/ssh/check_vscode_health.sh)**:
  - Updated with `AF_TSI`-aware `sshd` checks, `127.0.0.1:2222` round-trip SSH banner test, and live `port=0` loopback verification.

### Host PC Scripts (`/shared_dir_host_vm/vm2host/`)
- **[setup_host_vscode_ssh.sh](file:///shared_dir_host_vm/vm2host/setup_host_vscode_ssh.sh)**:
  - Heavily commented Host PC script that exports `~/.ssh/id_ed25519.pub`, updates `Host krun-act-runner` in `/home/vin/.ssh/config`, configures `/home/vin/.config/Code/User/settings.json`, and cleans up stale SSH forwarding processes.
- **[test_host_to_vm_ssh.sh](file:///shared_dir_host_vm/vm2host/test_host_to_vm_ssh.sh)**:
  - Heavily commented Host PC diagnostic script that runs 5 end-to-end tests (TCP banner, passwordless SSH auth, PTY allocation, SSH `-L` TCP port forwarding to a `port=0` VM listener, and SSH Unix domain socket forwarding) and supports `--launch` to open VS Code directly.
  - Test 4 and Test 5 daemonize their Python test listeners (`os.setsid()` and standard fd redirection to `/dev/null`) so the remote SSH command returns immediately to the Host PC without waiting for the listener socket timeout.

### Workspace Rules & Plans
- **[plans-directory.md](file:///shared_dir_host_vm/.agents/rules/plans-directory.md)**:
  - Workspace rule ensuring future agent plans are written to `/shared_dir_host_vm/plans/` and Host PC scripts to `/shared_dir_host_vm/vm2host/`.
- **[implementation_plan.md](file:///shared_dir_host_vm/plans/implementation_plan.md)**:
  - Synced to `/shared_dir_host_vm/plans/implementation_plan.md`.

---

## 3. Validation Results Inside the VM

- **`setup_vscode.sh` & `check_vscode_health.sh`:**
  - `libkrun_tsi_fix.so` compiled with zero warnings and registered in `/etc/ld.so.preload`.
  - Round-trip `127.0.0.1:2222 -> Guest:22` SSH banner verified: `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20`.
- **VS Code Node.js `listen(0, "127.0.0.1")` Test:**
  - Before fix: `Node port 0 FAILED: ECONNREFUSED`
  - After fix: `VS Code Node bound port=0 -> assigned port: 22752` / `VS Code Node port=0 connect SUCCEEDED: NODE_PORT_0_OK`

---

## 4. How to Run the Host PC Scripts

On your **Host PC**, run:

```bash
# 1. Configure ~/.ssh/config, export pubkey, and configure VS Code settings.json
/home/vin/ws/github/VincentChong123/krunvm/shared_dir_host_vm/vm2host/setup_host_vscode_ssh.sh

# 2. Run all 5 end-to-end SSH & port-forwarding tests (and launch VS Code)
/home/vin/ws/github/VincentChong123/krunvm/shared_dir_host_vm/vm2host/test_host_to_vm_ssh.sh --launch
```
