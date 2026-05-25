FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base packages
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    jq \
    openssh-client \
    ca-certificates \
    gnupg \
    sudo \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Latest npm + Claude Code
RUN npm install -g npm@latest && \
    npm install -g @anthropic-ai/claude-code

# Non-root user
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Ubuntu 24.04+ ships with a default 'ubuntu' user/group at UID/GID 1000.
# Remove it so we can claim 1000 for vscode (matches host UID for file ownership).
RUN userdel -r ubuntu 2>/dev/null || true

RUN groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME && \
    echo "$USERNAME ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME && \
    chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME
WORKDIR /workspace

# Pre-create ~/.claude/ so devcontainer.json's file-level bind mounts (which
# only mount settings.json + statusline.js, not the whole dir) have a parent
# to land in. Claude Code writes session-env/, history.jsonl, projects/, etc.
# into the rest of this dir at runtime — that part stays container-local +
# writable, separate from the host's ~/.claude/.
RUN mkdir -p /home/$USERNAME/.claude
