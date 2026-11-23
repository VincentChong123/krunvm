# Runbook: MicroVM CI Runner for `nektos/act` via `krunvm`

This runbook guides developers on using a dedicated **hardware-isolated `krunvm` MicroVM** (`krun-act-runner`) to run GitHub Actions CI workflows locally via **`nektos/act`**.

---

## 1. Overview & Architecture

When running complex CI workflows locally (e.g. workflows containing multi-container Docker Compose stacks like Langfuse, HyperDX, ClickHouse, and Grafana), standard `act` relies on **Docker-outside-of-Docker (DooD)** via `/var/run/docker.sock`. This often causes:
- **Port/Network split-brain:** Host ports (`127.0.0.1:3100`) cannot be reached by `curl` running inside the runner container.
- **Volume path mismatches:** Paths mounted inside the runner container don't resolve on the host daemon.
- **Dirty host state:** Stale database volumes and lingering containers pollute your host machine.

### The Solution: MicroVM Runner
By running `act` inside a dedicated `krunvm` MicroVM, the runner executes inside a **true Linux KVM hardware hypervisor boundary**:

```
Host Workstation (Ubuntu 24.04 / 26.04)
  │
  │  (krunvm start krun-act-runner)
  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ krunvm MicroVM: `krun-act-runner` (4 vCPUs, 6GB RAM, KVM Hardware VM)  │
│                                                                        │
│  Mounted Volume:                                                       │
│    <host_path>/local-infra ──► /workspace                              │
│                                                                        │
│  In-VM Tooling:                                                        │
│    - Ubuntu 24.04 Base                                                 │
│    - Dedicated In-VM Docker Engine & Compose v2                        │
│    - Node.js 20 & Global Commitlint CLI                                │
│    - nektos/act CLI (/usr/local/bin/act)                               │
│                                                                        │
│  Execution:                                                            │
│    act workflow_dispatch -W /workspace/.github/workflows/ci.yml        │
│        -P ubuntu-latest=-self-hosted                                   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Resource Allocation (Sized for 16 GB RAM ThinkPad)

Configured in [.env.act](file:///.env.act):
- **vCPUs:** `4` (leaves 4 logical threads for the host OS).
- **RAM:** `6144 MB` (6 GB). Leaves ~9 GB of available physical RAM and 14 GB swap for host applications.
- **GPU:** `0` (CI stacks are pure CPU/memory workloads).

---

## 3. Provisioning & Setup

### Step 1: Build the Runner Image
Build the OCI image containing Docker Engine, Compose, Node.js, and `act`:
```bash
bash scripts/build_image.sh localhost/krun-act-runner:latest configs/Containerfile.act-runner
```

### Step 2: Provision the MicroVM
Create and configure the `krun-act-runner` instance in `krunvm`:
```bash
ENV_FILE=.env.act ./setup.sh
```

Verify that the microVM exists:
```bash
krunvm list
```

---

## 4. Running CI Workflows

Use the helper script `scripts/run_act_vm.sh` to trigger runs seamlessly:

### Fast Linting (Commitlint)
```bash
./shared_dir_host_vm/scripts/run_act_vm.sh -j lint-commits
```

### Langfuse Stack Smoke Test
```bash
./shared_dir_host_vm/scripts/run_act_vm.sh -j test-langfuse-stack
```

### HyperDX + Grafana Smoke Test
```bash
./shared_dir_host_vm/scripts/run_act_vm.sh -j test-hyperdx-stack
```

### Full CI Workflow Execution
```bash
./shared_dir_host_vm/scripts/run_act_vm.sh
```

### Interactive Shell
If you need to debug or inspect the in-VM environment directly:
```bash
./shared_dir_host_vm/scripts/run_act_vm.sh shell
```

---

## 5. Maintenance & Lifecycle

- **Recreate MicroVM:** To completely wipe and rebuild the runner VM:
  ```bash
  RECREATE=true ENV_FILE=.env.act ./setup.sh
  ```
- **Delete MicroVM:**
  ```bash
  krunvm delete krun-act-runner
  ```
