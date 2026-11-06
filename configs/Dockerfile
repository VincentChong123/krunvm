# syntax=docker/dockerfile:1
# ==============================================================================
# Dockerfile - Base OCI Image for krunvm Agent Sandbox
# ==============================================================================

FROM ubuntu:24.04

# Prevent interactive prompts during apt operations
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Install core utilities and Python 3 runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    zsh \
    ca-certificates \
    curl \
    git \
    build-essential \
    jq \
    iproute2 \
    sudo \
    python3 \
    python3-venv \
    python3-pip \
    bubblewrap \
    podman \
    crun \
    fuse-overlayfs \
    podman-docker \
    podman-compose \
    && rm -rf /var/lib/apt/lists/*

# Configure Git to trust all mounted host workspaces (prevents dubious ownership errors)
RUN git config --system --add safe.directory "*"

# Configure Podman storage for rootless / virtiofs execution
RUN mkdir -p /etc/containers /run/containers/storage /var/lib/containers/storage && \
    touch /etc/containers/nodocker && \
    cat <<'EOF' > /etc/containers/storage.conf
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
EOF

# Install Astral uv binary
RUN curl -LsSf https://astral.sh/uv/install.sh | env CARGO_HOME=/usr/local UV_INSTALL_DIR=/usr/local/bin sh

# Install Antigravity CLI binary globally into /usr/local/bin
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin

# Install Zellij terminal multiplexer binary
RUN curl -fsSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz" | \
    tar -xz -C /usr/local/bin && \
    chmod +x /usr/local/bin/zellij

# Configure non-root sandbox-runner user (UID 1000, GID 1000) with passwordless sudo for YOLO mode
RUN if ! id -u sandbox-runner >/dev/null 2>&1; then \
        groupadd -g 1000 sandbox-runner && useradd -u 1000 -g 1000 -m -s /bin/bash sandbox-runner; \
    fi && \
    ln -sfn /home/sandbox-runner /home/ubuntu && \
    echo "sandbox-runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sandbox-runner && \
    chmod 0440 /etc/sudoers.d/sandbox-runner

# Pre-configure Zellij configuration and default layout
RUN mkdir -p /home/sandbox-runner/.config/zellij/layouts
COPY configs/layouts/agy-dev.kdl /home/sandbox-runner/.config/zellij/layouts/agy-dev.kdl
COPY configs/zellij-config.kdl /home/sandbox-runner/.config/zellij/config.kdl

# Create native ext4 Python virtual environment at /var/venv
RUN mkdir -p /var/venv && \
    /usr/local/bin/uv venv /var/venv --python 3.12 && \
    chown -R sandbox-runner:sandbox-runner /var/venv

# Pre-provision the Antigravity OTEL hooks virtual environment for Langfuse streaming
USER sandbox-runner
ENV HOME=/home/sandbox-runner
RUN mkdir -p /home/sandbox-runner/.gemini/antigravity-cli/hooks_env && \
    /usr/local/bin/uv venv /home/sandbox-runner/.gemini/antigravity-cli/hooks_env/.venv --python 3.12 && \
    /usr/local/bin/uv pip install --python /home/sandbox-runner/.gemini/antigravity-cli/hooks_env/.venv \
        opentelemetry-sdk \
        opentelemetry-exporter-otlp-proto-http \
        python-dotenv

# Copy centralized telemetry exporter scripts into guest
USER root
COPY scripts/export_agy_otel.sh /home/sandbox-runner/.gemini/antigravity-cli/scripts/export_agy_otel.sh
COPY scripts/export_agy_otel_to_langfuse.py /home/sandbox-runner/.gemini/antigravity-cli/scripts/export_agy_otel_to_langfuse.py
COPY scripts/get_active_agy_session.sh /home/sandbox-runner/.gemini/antigravity-cli/scripts/get_active_agy_session.sh
COPY scripts/test_connectivity.sh /home/sandbox-runner/.gemini/antigravity-cli/scripts/test_connectivity.sh
COPY scripts/test_smoke.sh /home/sandbox-runner/.gemini/antigravity-cli/scripts/test_smoke.sh

RUN chmod +x /home/sandbox-runner/.gemini/antigravity-cli/scripts/* && \
    ln -sf /home/sandbox-runner/.gemini/antigravity-cli/scripts/export_agy_otel.sh /usr/local/bin/export_agy_otel && \
    ln -sf /home/sandbox-runner/.gemini/antigravity-cli/scripts/get_active_agy_session.sh /usr/local/bin/get_active_agy_session && \
    ln -sf /home/sandbox-runner/.gemini/antigravity-cli/scripts/test_connectivity.sh /usr/local/bin/test_connectivity && \
    ln -sf /home/sandbox-runner/.gemini/antigravity-cli/scripts/test_smoke.sh /usr/local/bin/test_smoke && \
    chown -R sandbox-runner:sandbox-runner /home/sandbox-runner

# Set environment variables for login and subshell sessions
RUN echo 'export PATH="/usr/local/bin:$PATH"' >> /home/sandbox-runner/.bashrc && \
    echo 'export UV_PROJECT_ENVIRONMENT="/var/venv"' >> /home/sandbox-runner/.bashrc && \
    echo 'export VIRTUAL_ENV="/var/venv"' >> /home/sandbox-runner/.bashrc && \
    echo 'export PATH="/var/venv/bin:$PATH"' >> /home/sandbox-runner/.bashrc

# Ensure workspace mount point exists
RUN mkdir -p /mnt/workspace && chown sandbox-runner:sandbox-runner /mnt/workspace

USER sandbox-runner
WORKDIR /mnt/workspace

CMD ["/bin/bash"]
