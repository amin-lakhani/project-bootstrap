#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Project Bootstrap — fresh-machine setup for the bootstrap tools themselves
# Clones dotfiles + project-bootstrap, installs dotfiles, wires up Claude
# Code memory sync from the dotfiles repo.
#
# Run anywhere on a fresh WSL machine:
#   curl -fsSL https://raw.githubusercontent.com/amin-lakhani/project-bootstrap/main/dev-setup.sh | bash
# ============================================================================

GH_USER="amin-lakhani"
DOTFILES_REPO="git@github.com:${GH_USER}/dotfiles.git"
BOOTSTRAP_REPO="git@github.com:${GH_USER}/project-bootstrap.git"
DEFAULT_FOLDER="dev"
SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"
GIT_EMAIL="85595676+${GH_USER}@users.noreply.github.com"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
BLUE='\033[34m'; MAGENTA='\033[35m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
prompt()  { echo -e "${BLUE}[?]${NC} $1"; }
step()    { echo ""; echo -e "${MAGENTA}=== $1 ===${NC}"; }

open_url() {
    local url="$1"
    if command -v cmd.exe &> /dev/null; then
        (cd /mnt/c && nohup cmd.exe /c start "" "$url" < /dev/null > /dev/null 2>&1 &) 2>/dev/null
        sleep 1
        return 0
    fi
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" &> /dev/null &
        return 0
    fi
    return 1
}

clip_copy() {
    if command -v clip.exe &> /dev/null; then
        echo -n "$1" | clip.exe
        return 0
    fi
    return 1
}

require() {
    if ! command -v "$1" &> /dev/null; then
        error "Missing required tool: $1. Install it and re-run."
        exit 1
    fi
}

# ----- Preflight ------------------------------------------------------------
step "Preflight"
for tool in git curl ssh ssh-keygen; do
    require "$tool"
done
success "All required tools present."

# ----- Step 1: prompt for work directory -----------------------------------
step "Choose work directory"
echo ""
prompt "Name of the folder under \$HOME to use for these repos [default: ${DEFAULT_FOLDER}]:"
read -r folder_name < /dev/tty || folder_name=""
folder_name="${folder_name:-$DEFAULT_FOLDER}"
folder_name="${folder_name## }"
folder_name="${folder_name%% }"

# Tight regex (first char must be alnum) so destructive paths are safe.
if [[ ! "$folder_name" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    error "Folder name must start with lowercase letter or digit, then only"
    error "lowercase letters, digits, dots, dashes, underscores."
    exit 1
fi

WORK_DIR="${HOME}/${folder_name}"
NEEDS_MKDIR=1
if [[ -e "$WORK_DIR" ]]; then
    if [[ ! -d "$WORK_DIR" ]]; then
        error "'$WORK_DIR' exists but isn't a directory. Move it aside and re-run."
        exit 1
    fi
    if [[ -z "$(ls -A "$WORK_DIR" 2>/dev/null)" ]]; then
        info "Folder '${WORK_DIR}/' already exists and is empty — reusing it."
        NEEDS_MKDIR=0
    else
        warn "Folder '${WORK_DIR}/' already exists and is NOT empty:"
        ls -A "$WORK_DIR" | head -10 | sed 's/^/    /'
        entry_count=$(ls -A "$WORK_DIR" | wc -l)
        if [[ "$entry_count" -gt 10 ]]; then
            echo "    ... and $((entry_count - 10)) more"
        fi
        echo ""
        prompt "To wipe and reuse it, re-type the folder name. Anything else aborts."
        read -r confirm < /dev/tty || confirm=""
        if [[ "$confirm" != "$folder_name" ]]; then
            error "Name didn't match — aborting. No files changed."
            exit 1
        fi
        info "Wiping ${WORK_DIR}/ ..."
        rm -rf -- "$WORK_DIR"
        success "Wiped."
        NEEDS_MKDIR=1
    fi
fi
[[ "$NEEDS_MKDIR" == "1" ]] && mkdir -p "$WORK_DIR"
success "Work directory: ${WORK_DIR}"

# ----- Step 2: ensure a user-account SSH key exists ------------------------
step "User-account SSH key"
echo ""
echo "This step sets up a USER-ACCOUNT SSH key (not a per-project deploy key)."
echo "It's used to clone + push your personal repos (dotfiles, project-bootstrap)."
echo ""
KEY_ALREADY_EXISTED=0
if [[ -f "$SSH_KEY_PATH" ]]; then
    info "Existing key found at ${SSH_KEY_PATH} — reusing."
    KEY_ALREADY_EXISTED=1
else
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -C "${GIT_EMAIL} (user account)" -f "$SSH_KEY_PATH" -N ""
    success "Key generated at ${SSH_KEY_PATH}"
fi

PUBKEY="$(cat "${SSH_KEY_PATH}.pub")"
echo ""
echo "Public key:"
echo "  ${PUBKEY}"
echo ""

if [[ "$KEY_ALREADY_EXISTED" == "1" ]]; then
    prompt "If this key is already registered on GitHub, press Enter. Otherwise type 'add' to walk through registration:"
    read -r add_key_response < /dev/tty || add_key_response=""
    if [[ "$add_key_response" != "add" ]]; then
        info "Skipping key registration."
        SKIP_KEY_REG=1
    else
        SKIP_KEY_REG=0
    fi
else
    SKIP_KEY_REG=0
fi

if [[ "$SKIP_KEY_REG" == "0" ]]; then
    if clip_copy "$PUBKEY"; then
        success "Public key copied to clipboard."
    fi
    GITHUB_KEYS_URL="https://github.com/settings/ssh/new"
    info "Opening: ${GITHUB_KEYS_URL}"
    if open_url "$GITHUB_KEYS_URL"; then
        success "Browser opened."
    else
        warn "Couldn't auto-open browser. Visit manually: ${GITHUB_KEYS_URL}"
    fi
    echo ""
    info "On the page:"
    echo "  1. Title: anything, e.g. '$(hostname) - $(date +%Y-%m-%d)'"
    echo "  2. Key type: Authentication Key"
    echo "  3. Paste the public key (it's on your clipboard)"
    echo "  4. Click 'Add SSH key'"
    echo ""
    prompt "Press Enter once the key is added on GitHub..."
    read -r _ < /dev/tty || true
fi

# ----- Step 3: test SSH auth ------------------------------------------------
step "Verify SSH auth"
# `ssh -T git@github.com` exits 1 even on success, so capture output.
ssh_output="$(ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"
echo "${ssh_output}"
if echo "$ssh_output" | grep -q "successfully authenticated"; then
    success "SSH auth working."
else
    error "SSH auth failed. Key may not be registered yet."
    error "Re-run after confirming the key is on https://github.com/settings/keys"
    exit 1
fi

# ----- Step 4: clone repos --------------------------------------------------
step "Clone dotfiles + project-bootstrap"
cd "$WORK_DIR"
if [[ -d "${WORK_DIR}/dotfiles/.git" ]]; then
    info "dotfiles repo already cloned — skipping."
else
    git clone "$DOTFILES_REPO" "${WORK_DIR}/dotfiles"
    success "Cloned dotfiles."
fi
if [[ -d "${WORK_DIR}/project-bootstrap/.git" ]]; then
    info "project-bootstrap repo already cloned — skipping."
else
    git clone "$BOOTSTRAP_REPO" "${WORK_DIR}/project-bootstrap"
    success "Cloned project-bootstrap."
fi

# ----- Step 5: run dotfiles install ----------------------------------------
step "Install dotfiles"
"${WORK_DIR}/dotfiles/install.sh"

# ----- Step 6: wire up Claude memory symlink -------------------------------
step "Wire up Claude Code memory sync"
MEMORY_SRC="${WORK_DIR}/dotfiles/claude-memory-bootstrap"
if [[ ! -d "$MEMORY_SRC" ]]; then
    warn "${MEMORY_SRC} doesn't exist in the dotfiles repo — skipping memory symlink."
    warn "(If memories haven't been migrated yet, this is normal on the first machine setup.)"
else
    # Compute the hashed path Claude Code uses for this work dir.
    CLAUDE_HASH="$(echo "$WORK_DIR" | sed 's|/|-|g')"
    CLAUDE_DIR="${HOME}/.claude/projects/${CLAUDE_HASH}"
    mkdir -p "$CLAUDE_DIR"
    MEMORY_LINK="${CLAUDE_DIR}/memory"
    if [[ -L "$MEMORY_LINK" ]]; then
        info "Memory symlink already exists — refreshing target."
        rm "$MEMORY_LINK"
    elif [[ -e "$MEMORY_LINK" ]]; then
        backup="${MEMORY_LINK}.backup.$(date +%Y%m%d%H%M%S)"
        warn "Existing ${MEMORY_LINK} is not a symlink — backing up to ${backup}"
        mv "$MEMORY_LINK" "$backup"
    fi
    ln -s "$MEMORY_SRC" "$MEMORY_LINK"
    success "Memory linked: ${MEMORY_LINK} -> ${MEMORY_SRC}"
fi

# ----- Done -----------------------------------------------------------------
echo ""
success "Dev environment ready!"
echo ""
NEXT_CMD="(cd ${WORK_DIR}/project-bootstrap && code .)"
echo "Next steps:"
echo "  1. Open project-bootstrap in VS Code: ${NEXT_CMD}"
echo "  2. Or work on dotfiles:                (cd ${WORK_DIR}/dotfiles && code .)"
echo ""
if clip_copy "$NEXT_CMD"; then
    info "Step 1 command copied to clipboard — just paste in your shell."
fi
