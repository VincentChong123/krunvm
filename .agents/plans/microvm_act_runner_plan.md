# Implementation Plan: MicroVM Runner Pattern for `act` in `krunvm`

## 1. Goal Description
The purpose of this feature is to provide a dedicated **hardware-isolated microVM profile** in `krunvm` specifically engineered to run [`nektos/act`](https://github.com/nektos/act).

By running `act` inside a dedicated `krunvm` MicroVM (`krun-act-runner`) instead of a nested Docker-in-Docker container on the host:
- **True Network Parity:** `127.0.0.1` binds directly to the microVM's own kernel loopback interface, allowing `curl http://127.0.0.1:3100` and `curl http://127.0.0.1:3001` to test Docker Compose stacks (Langfuse, HyperDX, Grafana) without container bridging conflicts.
- **Hardware Sizing Parity:** Sized with 4 vCPUs and 7168 MB RAM to match GitHub's standard `ubuntu-latest` VM specs.
- **Host Isolation:** Tests run against an in-VM Docker daemon with ephemeral storage; no test containers, volumes, or networks pollute the host workstation.

---

## 2. Architecture Diagram

```
Host Workstation (Ubuntu 24.04 / 26.04)
  │
  │  (krunvm start krun-act-runner)
  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ krunvm MicroVM: `krun-act-runner` (4 vCPUs, 7GB RAM, KVM Hardware VM)   │
│                                                                        │
│  Mounted Volume:                                                       │
│    <host_path>/local-infra ──► /workspace                               │
│                                                                        │
│  In-VM Tooling:                                                        │
│    - Ubuntu 24.04 Base                                                 │
│    - In-VM Docker Engine & Compose v2                                  │
│    - Node.js 20 & Global Commitlint CLI                                │
│    - nektos/act CLI (/usr/local/bin/act)                               │
│                                                                        │
│  Execution:                                                            │
│    act workflow_dispatch -W /workspace/.github/workflows/ci.yml        │
│        -P ubuntu-latest=-self-hosted                                   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. User Review Required

> [!IMPORTANT]
> The target repository to mount is configured as `<host_path>/local-infra`. If you want to run CI for a different repo, simply adjust `VOLUMES` in `.env.act`.

> [!NOTE]
> Inside the `krun-act-runner` microVM, `act` executes with `-P ubuntu-latest=-self-hosted`. This instructs `act` to execute the workflow steps directly on the microVM's own OS (which is already an isolated VM) rather than spinning up another container layer.

---

## 4. Proposed Changes

### Component: Core MicroVM Image & Configuration

#### [NEW] `configs/Containerfile.act-runner`
OCI base image tailored for running GitHub Actions locally via `act`:
- Installs Docker CE / `docker.io`, `docker-compose-v2`, `build-essential`, `git`, `curl`.
- Installs Node.js 20 and globally installs `@commitlint/cli` and `@commitlint/config-conventional`.
- Installs `nektos/act` binary at `/usr/local/bin/act`.
- Grants `ubuntu` (UID 1000) membership in the `docker` group and passwordless `sudo`.
- Sets default workdir to `/workspace`.

#### [NEW] `.env.act.example` & `.env.act`
Dedicated environment profile for the act runner microVM:
- `VM_NAME="krun-act-runner"`
- `OCI_BASE_IMAGE="localhost/krun-act-runner:latest"`
- `CONTAINERFILE="configs/Containerfile.act-runner"`
- `VM_CPUS="4"`
- `VM_MEMORY="7168"` (7 GB matching GitHub Actions VM specs)
- `VOLUMES="${HOME}/ws/github/VincentChong123/local-infra:/workspace:rw"`

---

### Component: Build & Setup Automation

#### [MODIFY] `scripts/build_image.sh`
- Support an optional 2nd argument or `CONTAINERFILE` environment variable so callers can specify custom image definitions:
  ```bash
  CONTAINERFILE="${2:-${CONTAINERFILE:-${REPO_ROOT}/configs/Containerfile}}"
  ```

#### [MODIFY] `setup.sh`
- Pass `CONTAINERFILE` from the environment to `scripts/build_image.sh` during base image creation:
  ```bash
  bash "${SCRIPT_DIR}/scripts/build_image.sh" "$OCI_BASE_IMAGE" "${CONTAINERFILE:-}"
  ```

---

### Component: CLI Helper & Documentation

#### [NEW] `scripts/run_act_vm.sh`
Executable helper script on the host to run CI workflows inside the microVM with a single command:
```bash
# Usage:
#   ./scripts/run_act_vm.sh                               # Runs full CI workflow
#   ./scripts/run_act_vm.sh -j lint-commits               # Runs linting only
#   ./scripts/run_act_vm.sh -j test-hyperdx-stack         # Runs HyperDX + Grafana
#   ./scripts/run_act_vm.sh -j test-langfuse-stack        # Runs Langfuse stack
```
It handles:
1. Loading `.env.act`.
2. Booting `krun-act-runner`.
3. Ensuring the in-VM `dockerd` service is active.
4. Invoking `act` in self-hosted mode pointing at `/workspace/.github/workflows/ci.yml`.

#### [NEW] `docs/runbook_act_microvm_runner.md`
Detailed runbook explaining:
- Why MicroVMs provide 1:1 parity with `github.com`.
- Sizing and network isolation benefits.
- How to provision, run, update, and debug CI runs inside `krunvm`.

---

## 5. Verification Plan

### Automated Build Verification
1. Build the new OCI runner image:
   ```bash
   bash scripts/build_image.sh localhost/krun-act-runner:latest configs/Containerfile.act-runner
   ```
2. Verify image registration via `buildah images` / `podman images`.

### Provisioning Verification
1. Provision the microVM:
   ```bash
   ENV_FILE=.env.act ./setup.sh
   ```
2. Verify instance exists in `krunvm list`.

### End-to-End Workflow Execution
1. Run lint-commits job inside the microVM:
   ```bash
   ./scripts/run_act_vm.sh -j lint-commits
   ```
2. Run smoke tests (HyperDX + Grafana and Langfuse) inside the microVM and verify that `curl http://127.0.0.1:...` succeeds cleanly without network timeouts.
