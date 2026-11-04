# Architectural Comparison & Migration Evaluation: Canonical Multipass vs. krunvm

**Target Environment:** 16 GB RAM, 8-Core CPU, Ubuntu 26.04 LTS  
**Source Repository:** [`Vincentchong123/multipass`](file:///home/vin/ws/20_projects/21_github/Vincentchong123/multipass)  
**Target Architecture:** `krunvm` / `libkrun` MicroVM runtime  

---

## 1. Executive Summary & Architectural Advisory

This evaluation assesses the viability, trade-offs, and migration path of replacing the Canonical Multipass two-tier provisioning framework with `krunvm` microVMs on a resource-constrained workstation (16 GB RAM, 8 vCPUs) running Ubuntu 26.04 LTS.

> [!WARNING]
> ### ⚠️ DevOps Architectural Warning: Impedance Mismatch & Upstream Packaging Drift
> - **Packaging & Maintenance Debt on Ubuntu 26.04:** Canonical Multipass is a first-class, natively packaged Ubuntu orchestration tool. In contrast, `krunvm` and its companion C libraries (`libkrunfw`, `libkrun`) are primarily maintained for Fedora/RHEL/macOS. Operating `krunvm` on Ubuntu 26.04 requires building from source via `cargo` and GCC, introducing severe drift and rebuild overhead across host Linux kernel updates.
> - **Paradigm Shift (Full OS vs. OCI MicroVM):** The existing Multipass codebase relies on a **Two-Tier Persistent OS VM** architecture configured via Cloud-Init ([`setup.yaml`](file:///home/vin/ws/20_projects/21_github/Vincentchong123/multipass/setup.yaml)), persistent `systemd` services ([`multipass-ro-mounts.service`](file:///home/vin/ws/20_projects/21_github/Vincentchong123/multipass/setup.sh#L365-L380)), and a native OpenSSH daemon for VS Code Remote integration. `krunvm` does not run Cloud-Init or multi-user `systemd` by default; it boots an ephemeral Linux kernel directly into an OCI container entrypoint.

> [!TIP]
> ### 💡 Modern Industry Standard
> - **Persistent Developer & Agent Sandboxes:** Retain hypervisor-based full OS virtualization (Multipass or Libvirt/KVM) where standard SSH, systemd, and local IDE remoting are first-class citizens.
> - **Ultra-High Density / Ephemeral Code Execution:** Utilize microVMs (`krunvm`, Firecracker, or Kata Containers) for sub-second, disposable tasks (e.g. running untrusted Python snippets or isolated browser testing) without attempting to turn them into interactive developer workstations.

---

## 2. Technical Comparison Matrix

| Evaluation Dimension | Canonical Multipass (Current) | `krunvm` (`libkrun` MicroVM) |
| :--- | :--- | :--- |
| **Virtualization Backend** | QEMU / KVM (full machine emulation) | `libkrun` (lightweight in-process VMM via KVM) |
| **Guest Environment** | Full Ubuntu OS (kernel + `systemd` PID 1) | OCI Container rootfs (minimal kernel directly to app PID 1) |
| **Boot & Spin-up Latency** | 15 – 30 seconds (cloud-init + OS boot) | **< 100 milliseconds** (instantaneous microVM cold start) |
| **RAM Footprint (16GB Host)** | **Static reservation** (e.g., 2 GB pinned via QEMU) | **Dynamic in-process allocation** (memory yields back to host) |
| **Idle Memory Overhead** | ~300 – 600 MB (snapd, journald, system services) | **~30 – 50 MB** (only libkrun runtime + target binary) |
| **Provisioning Mechanism** | Cloud-Init (`#cloud-config` in `setup.yaml`) | Containerfiles / Dockerfile builds (`buildah bud`) |
| **Background Daemons / Services** | Supported via standard `systemd` unit files | Not supported natively; requires custom process managers |
| **Remote Access & IDE** | Native OpenSSH daemon (`VS Code Remote - SSH`) | Interactive TTY (`krunvm start`) or container remoting |
| **Filesystem Sharing** | VirtioFS native mount (`--type native`, UID 1000) | VirtioFS host directory mounts (`-v /host:/guest`) |
| **Networking Model** | Bridge / NAT subnet (`VM_IPV4`, host gateway) | TSI (Transparent Socket Impersonation) over `AF_VSOCK` |
| **Telemetry / Host Reverse Route** | Predictable gateway (`http://${HOST_GATEWAY_IP}:4318`) | Requires port publishing (`-p`) or specific vsock forwarders |
| **Ubuntu 26.04 Upstream Support** | **First-class Canonical package** (Snap / APT) | **Build from source** (`libkrunfw`, `libkrun`, `cargo`) |

---

## 3. Deep-Dive Trade-Off Analysis

### 3.1 Compute & Memory Efficiency on a 16 GB Workstation
- **Multipass:** Pre-allocates and wires guest memory (e.g., `VM_MEMORY="2G"` in `.env.host`). On a 16 GB host concurrently running VS Code, Chrome, Docker services, and an LLM telemetry bridge (Langfuse on port 3100), dedicated VM memory reservations increase swapping risks under peak workloads.
- **krunvm:** Allocates guest memory dynamically via host process heap. When the guest process finishes a compilation or execution step, memory is reclaimed by the host operating system. The 8-core host CPU experiences lower context-switch overhead due to minimal device emulation.

### 3.2 Developer Experience & IDE Remoting
- **Multipass:** Injects host SSH public keys directly into `/home/ubuntu/.ssh/authorized_keys` ([`setup.sh#L386-L399`](file:///home/vin/ws/20_projects/21_github/Vincentchong123/multipass/setup.sh#L386-L399)). This enables drop-in configuration for `Host multipass-assistant` in `~/.ssh/config` and instant compatibility with VS Code Remote - SSH.
- **krunvm:** Designed around standard I/O redirection (`stdin`/`stdout`). To use VS Code Remote - SSH with `krunvm`, you must package OpenSSH server into the base OCI image, maintain host keys, run an init wrapper script to keep `sshd` alive, and map port 22 to an external host port (`krunvm create -p 2222:22`). Alternatively, you must switch to VS Code Dev Containers.

### 3.3 Provisioning Lifecycle & State Management
- **Multipass:** Employs a Two-Tier provisioning model:
  1. *Tier 1:* Base VM infrastructure via Cloud-Init ([`setup.yaml`](file:///home/vin/ws/20_projects/21_github/Vincentchong123/multipass/setup.yaml)) installing `uv`, Python 3.12, and build tools.
  2. *Tier 2:* Project hydration locking dependencies in an isolated ext4 virtual environment (`/var/venv`), keeping shared VirtioFS mounts clean.
- **krunvm:** Replaces Cloud-Init with container image layering. You must build an immutable base image via `buildah bud` containing the toolchain. While layer caching accelerates image builds, deterministic host mounts and post-boot configuration must be managed through container entrypoints.

---

## 4. In-VM Web Browser Support Analysis

A critical requirement for autonomous AI coding agents is in-VM browser capability (for automated verification, end-to-end testing, or web research).

### 4.1 Headless Browsers (Playwright, Puppeteer, Chromium `--headless`)
* **Status:** **Fully Supported & Superior in `krunvm`.**
* **Network & DNS:** Outbound TLS/HTTP requests route seamlessly through `libkrun`'s Transparent Socket Impersonation (TSI) without requiring host network bridge configuration.
* **Cold-Start Advantage:** An AI agent can launch a dedicated microVM, execute a Playwright test script, and tear down the VM in less than 500 milliseconds total.
* **Essential Runtime Flags:**
  * Chromium relies on `/dev/shm` for internal IPC. Containers default to 64MB `/dev/shm`, triggering `SIGBUS` tab crashes. Launch Chromium with `--disable-dev-shm-usage` or pass `-v /dev/shm:/dev/shm`.
  * Run Chromium with `--no-sandbox` unless user namespaces are fully mapped inside the unprivileged microVM.

### 4.2 Interactive GUI Desktop Browsers (Display Window on Host)
* **Status:** **Not Native to `krunvm`, requires Display Sockets or `muvm`.**
* **The Display Gap:** `krunvm` is a CLI process supervisor; it does not provision a virtual display adapter or route window buffers to the host desktop by default.
* **Architectural Options:**
  1. **Socket Bridging:** Mount the host X11 socket (`-v /tmp/.X11-unix:/tmp/.X11-unix -e DISPLAY=$DISPLAY`) and permit access via `xhost +local:`.
  2. **`muvm` Integration:** For native desktop GUI applications, the `libkrun` community created [`muvm`](https://github.com/AsahiLinux/muvm), which bridges Wayland, X11, and `virtio-gpu` (Virgl/Venus) with hardware acceleration.
  3. **In-VM Web/VNC:** Run a headless Xvfb + noVNC server inside the container, expose port 6080 (`-p 6080:6080`), and access the browser through a host browser window.

---

## 5. Migration Impact on the Codebase

Migrating from the current Multipass engine to `krunvm` requires the following architectural refactoring:

| Existing Component | Status | Required Replacement / Migration Action |
| :--- | :--- | :--- |
| [`setup.yaml`](file:///home/vin/ws/20_projects/21_github/Vincentchong123/multipass/setup.yaml) | **Obsolete** | Replaced with an OCI `Containerfile` built using `buildah`. |
| [`setup.sh`](file:///home/vin/ws/20_projects/21_github/Vincentchong123/multipass/setup.sh) | **Major Rewrite** | Replace `multipass launch/mount/exec` commands with `buildah` and `krunvm create/start`. |
| `.env.host` | **Modified** | Remove `VM_IMAGE="24.04"` and `VM_DISK="15G"`; add `OCI_IMAGE_TAG` and port maps. |
| `multipass-ro-mounts.service` | **Incompatible** | Mount flags (`:ro`) must be handled directly at `krunvm create -v /host:/guest:ro` time. |
| VS Code SSH Config | **Modified** | Requires container SSH entrypoint or pivot to VS Code Dev Containers. |
| Host Telemetry Bridge | **Modified** | Guest cannot simply route to `ip route default`; must publish ports explicitly or use TSI forwarders. |

---

## 6. Strategic Verdict & Recommendation

1. **Retain Canonical Multipass if:**
   - Your primary workflow depends on **VS Code Remote - SSH**, background `systemd` services, and drop-in Ubuntu LTS stability.
   - You want zero compilation maintenance overhead on Ubuntu 26.04 LTS.
   - The 2 GB static RAM footprint is acceptable for your daily multitasking.

2. **Migrate to `krunvm` (or Podman with `krun`) if:**
   - Your primary constraint on the 16 GB machine is **RAM exhaustion**, and you need idle sandboxes to consume near-zero memory.
   - You are redesigning your AI agent workflow to use **ephemeral, disposable tasks** (e.g., executing a single script or running headless Playwright browser automation in <100ms) rather than maintaining an interactive virtual workstation.
   - For graphical workloads, evaluate **`muvm`** alongside `krunvm` to achieve hardware-accelerated Wayland/X11 desktop window integration.
