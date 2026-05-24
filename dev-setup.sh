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
DEFAULT_FOLDER="dev"
GIT_EMAIL="85595676+${GH_USER}@users.noreply.github.com"

# Dotfiles is private — needs a per-repo read-only deploy key (scoped, no
# broad account access). project-bootstrap is public — anon HTTPS works.
DOTFILES_KEY_PATH="${HOME}/.ssh/dotfiles_ed25519"
DOTFILES_SSH_HOST="github.com-dotfiles"
DOTFILES_REPO="git@${DOTFILES_SSH_HOST}:${GH_USER}/dotfiles.git"
BOOTSTRAP_REPO="https://github.com/${GH_USER}/project-bootstrap.git"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
BLUE='\033[34m'; MAGENTA='\033[35m'; GRAY='\033[90m'; NC='\033[0m'

# ----- Logging --------------------------------------------------------------
# tee every byte to a timestamped log file so the run is debuggable after the
# fact. Char-by-char (not line-buffered) so interactive prompts still work.
LOG_DIR="${HOME}/.cache/project-bootstrap"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/dev-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()      { date +%H:%M:%S; }
info()    { echo -e "${GRAY}[$(ts)]${NC} ${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GRAY}[$(ts)]${NC} ${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${GRAY}[$(ts)]${NC} ${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${GRAY}[$(ts)]${NC} ${RED}[ERROR]${NC} $1"; }
prompt()  { echo -e "${GRAY}[$(ts)]${NC} ${BLUE}[?]${NC} $1"; }
step()    { echo ""; echo -e "${GRAY}[$(ts)]${NC} ${MAGENTA}=== $1 ===${NC}"; }
debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${GRAY}[$(ts)] [DEBUG]${NC} $1" || true; }

# ERR trap so set -e failures aren't silent.
on_err() {
    local exit_code=$?
    local line=$1
    local cmd=$2
    echo ""
    error "FATAL at line ${line}: command \`${cmd}\` exited ${exit_code}"
    error "Log file: ${LOG_FILE}"
    exit "$exit_code"
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

info "Log file: ${LOG_FILE}"
debug "DEBUG=1 is on — verbose tracing enabled."
[[ "${DEBUG:-0}" == "1" ]] && set -x

# Detect environment for diagnostic context.
detect_env() {
    local notes=()
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && notes+=("WSL=${WSL_DISTRO_NAME}")
    [[ -n "${VSCODE_IPC_HOOK_CLI:-}" ]] && notes+=("VSCode-remote")
    [[ -n "${REMOTE_CONTAINERS:-}${CODESPACES:-}" ]] && notes+=("dev-container")
    [[ -f /.dockerenv ]] && notes+=("docker-container")
    command -v cmd.exe &> /dev/null && notes+=("cmd.exe-present")
    command -v clip.exe &> /dev/null && notes+=("clip.exe-present")
    command -v xdg-open &> /dev/null && notes+=("xdg-open-present")
    command -v wl-copy &> /dev/null && notes+=("wl-copy-present")
    command -v xclip &> /dev/null && notes+=("xclip-present")
    command -v pbcopy &> /dev/null && notes+=("pbcopy-present")
    command -v code &> /dev/null && notes+=("vscode-cli-present")
    info "Environment: user=$(id -un) host=$(hostname) ${notes[*]:-no-special-features}"
}

# Try every clipboard mechanism we know about, in order of "actually copies to
# the OS clipboard" → "best-effort terminal escape" → "give up". Logs which
# path succeeded so future failures are diagnosable.
clip_copy() {
    local content="$1"
    if command -v clip.exe &> /dev/null; then
        if printf '%s' "$content" | clip.exe 2>/dev/null; then
            debug "clip_copy: used clip.exe"
            return 0
        fi
        warn "clip.exe present but failed."
    fi
    if command -v pbcopy &> /dev/null; then
        if printf '%s' "$content" | pbcopy 2>/dev/null; then
            debug "clip_copy: used pbcopy"
            return 0
        fi
    fi
    if command -v wl-copy &> /dev/null; then
        if printf '%s' "$content" | wl-copy 2>/dev/null; then
            debug "clip_copy: used wl-copy"
            return 0
        fi
    fi
    if command -v xclip &> /dev/null; then
        if printf '%s' "$content" | xclip -selection clipboard 2>/dev/null; then
            debug "clip_copy: used xclip"
            return 0
        fi
    fi
    if command -v xsel &> /dev/null; then
        if printf '%s' "$content" | xsel --clipboard --input 2>/dev/null; then
            debug "clip_copy: used xsel"
            return 0
        fi
    fi
    # OSC52 terminal escape — works in many modern terminals (VS Code,
    # Windows Terminal, iTerm2, kitty, tmux 3.3+). Sends the content as a
    # base64-encoded clipboard set escape sequence; the terminal emulator
    # decodes it and copies to the OS clipboard. The user usually has to
    # confirm or have the feature enabled.
    local b64
    if b64="$(printf '%s' "$content" | base64 -w0 2>/dev/null)" || \
       b64="$(printf '%s' "$content" | base64 | tr -d '\n')"; then
        printf '\033]52;c;%s\007' "$b64"
        debug "clip_copy: emitted OSC52 escape (terminal may or may not honor)"
        # OSC52 is fire-and-forget; we can't tell if it worked. Return 2 to
        # mean "tried best-effort, can't confirm".
        return 2
    fi
    debug "clip_copy: no clipboard mechanism available"
    return 1
}

# Try to open a URL in the user's browser. Returns 0 only when we have
# reasonable confidence it actually opened.
open_url() {
    local url="$1"
    if command -v cmd.exe &> /dev/null; then
        # WSL: launch via Windows shell so it opens in the host browser.
        # Background + nohup avoids cmd.exe briefly grabbing the tty.
        (cd /mnt/c && nohup cmd.exe /c start "" "$url" < /dev/null > /dev/null 2>&1 &) 2>/dev/null
        sleep 1
        debug "open_url: used cmd.exe"
        return 0
    fi
    if command -v wslview &> /dev/null; then
        if wslview "$url" < /dev/null > /dev/null 2>&1; then
            debug "open_url: used wslview"
            return 0
        fi
    fi
    # VS Code's CLI can open URLs in the host browser when running in a remote
    # window (dev container, SSH, Codespaces). This is the right path for the
    # exact env Amin's hitting now.
    if command -v code &> /dev/null; then
        if code --openExternal "$url" 2>/dev/null; then
            debug "open_url: used code --openExternal"
            return 0
        fi
    fi
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" &> /dev/null &
        debug "open_url: used xdg-open"
        return 0
    fi
    if command -v open &> /dev/null; then
        open "$url" &> /dev/null &
        debug "open_url: used open (macOS)"
        return 0
    fi
    debug "open_url: no opener available"
    return 1
}

# Bordered URL/pubkey print so the user can copy it manually when automation
# fails. Borders make it easy to scroll up and find.
boxed_print() {
    local label="$1"
    local body="$2"
    echo ""
    echo "  ┌─[${label}]──────────────────────────────────────────"
    while IFS= read -r line; do
        echo "  │ ${line}"
    done <<< "$body"
    echo "  └────────────────────────────────────────────────────"
    echo ""
}

require() {
    if ! command -v "$1" &> /dev/null; then
        error "Missing required tool: $1. Install it and re-run."
        exit 1
    fi
}

detect_env

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

# ----- Step 2: read-only deploy key scoped to dotfiles ----------------------
step "Deploy key for dotfiles (read-only, repo-scoped)"
echo ""
echo "This sets up a READ-ONLY DEPLOY KEY scoped to just the dotfiles repo."
echo "Not a user-account key — no broad access to any of your other repos."
echo "(project-bootstrap is public, so it doesn't need any key.)"
echo ""

KEY_ALREADY_EXISTED=0
if [[ -f "$DOTFILES_KEY_PATH" ]]; then
    info "Existing dotfiles key found at ${DOTFILES_KEY_PATH} — reusing."
    KEY_ALREADY_EXISTED=1
else
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -C "${GIT_EMAIL} (dotfiles read-only deploy key)" -f "$DOTFILES_KEY_PATH" -N ""
    success "Key generated at ${DOTFILES_KEY_PATH}"
fi

# SSH config alias so 'git@github.com-dotfiles:...' uses this key.
SSH_CONFIG="${HOME}/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
if ! grep -q "^Host ${DOTFILES_SSH_HOST}$" "$SSH_CONFIG"; then
    {
        echo ""
        echo "# Added by project-bootstrap/dev-setup.sh — read-only key for dotfiles"
        echo "Host ${DOTFILES_SSH_HOST}"
        echo "    HostName github.com"
        echo "    User git"
        echo "    IdentityFile ${DOTFILES_KEY_PATH}"
        echo "    IdentitiesOnly yes"
    } >> "$SSH_CONFIG"
    success "Added SSH config alias '${DOTFILES_SSH_HOST}'"
else
    info "SSH config alias '${DOTFILES_SSH_HOST}' already present — skipping."
fi

PUBKEY="$(cat "${DOTFILES_KEY_PATH}.pub")"
boxed_print "PUBLIC KEY — copy this if the clipboard didn't grab it" "${PUBKEY}"

if [[ "$KEY_ALREADY_EXISTED" == "1" ]]; then
    prompt "If this key is already registered as a deploy key on dotfiles, press Enter. Otherwise type 'add' to walk through registration:"
    read -r add_key_response < /dev/tty || add_key_response=""
    [[ "$add_key_response" != "add" ]] && SKIP_KEY_REG=1 || SKIP_KEY_REG=0
    debug "Key reuse decision: SKIP_KEY_REG=${SKIP_KEY_REG} (response='${add_key_response}')"
else
    SKIP_KEY_REG=0
fi

if [[ "$SKIP_KEY_REG" == "0" ]]; then
    # Clipboard: report exact outcome so user knows whether to paste manually.
    set +e
    clip_copy "$PUBKEY"
    clip_status=$?
    set -e
    case "$clip_status" in
        0) success "Public key copied to clipboard." ;;
        2) warn "Public key sent via OSC52 terminal escape — your terminal may or may not have honored it." ;;
        *) warn "Couldn't reach any clipboard tool — copy the public key from the box above manually." ;;
    esac

    GITHUB_KEYS_URL="https://github.com/${GH_USER}/dotfiles/settings/keys/new"
    info "Deploy key page: ${GITHUB_KEYS_URL}"
    set +e
    open_url "$GITHUB_KEYS_URL"
    open_status=$?
    set -e
    if [[ "$open_status" == "0" ]]; then
        success "Tried to open browser. If nothing happened, use the URL above (in VS Code's terminal, Ctrl+Click on the URL works)."
    else
        warn "No browser-opener was available. Open this URL manually:"
        boxed_print "URL" "${GITHUB_KEYS_URL}"
    fi

    echo ""
    info "On the page:"
    echo "  1. Title: e.g. '$(hostname) - $(date +%Y-%m-%d)'"
    echo "  2. Paste the public key (clipboard, or copy from the box above)"
    echo "  3. LEAVE 'Allow write access' UNCHECKED (read-only)"
    echo "  4. Click 'Add key'"
    echo ""
    prompt "Press Enter once the key is added on GitHub..."
    read -r _ < /dev/tty || true
fi

# ----- Step 3: test SSH auth for the dotfiles alias ------------------------
step "Verify SSH auth (via dotfiles alias)"
# `ssh -T` to GitHub exits 1 even on success; deploy keys authenticate as
# the repo, not the user, so the message is different ("appears to be a
# deploy key" or "does not provide shell access").
info "Running: ssh -T -o StrictHostKeyChecking=accept-new git@${DOTFILES_SSH_HOST}"
ssh_output="$(ssh -T -v -o StrictHostKeyChecking=accept-new "git@${DOTFILES_SSH_HOST}" 2>&1 || true)"
# Stash the verbose output only into the log; print the non-verbose summary
# lines to the user (anything not starting with 'debug1:').
echo "${ssh_output}" | grep -vE '^debug[0-9]+:|^OpenSSH' || true
debug "Full ssh -T -v output:"
debug "$(echo "$ssh_output" | sed 's/^/    /')"
if echo "$ssh_output" | grep -qiE "successfully authenticated|deploy key|does not provide shell access"; then
    success "SSH auth working for dotfiles."
else
    error "SSH auth failed. Common causes:"
    error "  - The deploy key wasn't actually added on GitHub (re-check the page)"
    error "  - GitHub still resolving the key (try waiting 15-30 seconds + re-run)"
    error "  - Network/firewall blocking SSH on port 22 (try \`ssh -T -p 443 git@ssh.github.com\` to test ssh-over-https)"
    error "Re-run after fixing, OR add the key at: https://github.com/${GH_USER}/dotfiles/settings/keys"
    error "Log file: ${LOG_FILE}"
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
set +e
clip_copy "$NEXT_CMD"
final_clip_status=$?
set -e
case "$final_clip_status" in
    0) info "Step 1 command copied to clipboard — just paste in your shell." ;;
    2) info "Step 1 command sent via OSC52 — may need to be copied manually." ;;
    *) info "No clipboard available — copy the command from above." ;;
esac

info "Log file: ${LOG_FILE}"
