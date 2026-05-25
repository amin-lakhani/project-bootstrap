#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Project Bootstrap — fresh-machine setup for the bootstrap tools themselves
# Clones dotfiles + project-bootstrap, installs dotfiles, wires up Claude
# Code memory sync from the dotfiles repo.
#
# Run anywhere on a fresh WSL machine — see README "Setting up a fresh
# machine" for the auto-detecting snippet that resolves <YOUR-GH-USER>
# from gh CLI / gitconfig / prompt before fetching this script.
#
# Identity (GitHub user, git name/email) is sourced in this priority order:
#   1. BOOTSTRAP_GH_USER / BOOTSTRAP_GH_USER_ID / BOOTSTRAP_GIT_NAME
#      / BOOTSTRAP_GIT_EMAIL env vars
#   2. Cache file at $XDG_CONFIG_HOME (or ~/.config) /project-bootstrap/user.env
#   3. Interactive prompt over /dev/tty
# Whatever is resolved is written back to the cache file so future runs are
# non-interactive.
# ============================================================================

DEFAULT_FOLDER="${BOOTSTRAP_WORK_DIR:-dev_env_setup}"

# Repo names default to the canonical pair but can be overridden if you forked
# them under different names.
DOTFILES_REPO_NAME="${DOTFILES_REPO_NAME:-dotfiles}"
BOOTSTRAP_REPO_NAME="${BOOTSTRAP_REPO_NAME:-project-bootstrap}"

# Dotfiles is private — needs a per-repo read-only deploy key (scoped, no
# broad account access). project-bootstrap is public — anon HTTPS works.
DOTFILES_KEY_PATH="${HOME}/.ssh/${DOTFILES_REPO_NAME}_ed25519"
DOTFILES_SSH_HOST="github.com-${DOTFILES_REPO_NAME}"

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

# ----- Identity (env > cache > auto-fetch > prompt) -------------------------
IDENTITY_CACHE="${XDG_CONFIG_HOME:-${HOME}/.config}/project-bootstrap/user.env"

# Fetch the numeric account ID from the public GitHub API. Unauthenticated
# (60 req/h per IP) so it's fine for a one-time bootstrap. Prints the ID on
# success, returns non-zero on any failure (offline, typo'd username, rate
# limit). No jq dependency — grep the JSON.
fetch_github_user_id() {
    local gh_user="$1"
    local response
    response="$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/users/${gh_user}" 2>/dev/null || true)"
    [[ -z "$response" ]] && return 1
    # The top-level "id" field is the account ID. It appears before any nested
    # objects in the response, so the first match is the right one.
    local id
    id="$(printf '%s' "$response" | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+')"
    [[ -z "$id" ]] && return 1
    printf '%s' "$id"
}

# Detect the user's GitHub username from local signals so we can offer it as
# an Enter-to-accept default. Tries (in order):
#   1. gh CLI (`gh api user`) if installed + authenticated
#   2. `git config --global user.email` if it parses as the GitHub
#      noreply format <id>+<user>@users.noreply.github.com
# Prints the username on success, nothing on failure. Never errors.
detect_github_username() {
    if command -v gh &>/dev/null; then
        local u
        u="$(gh api user 2>/dev/null | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"login"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
        if [[ -n "$u" ]]; then
            printf '%s' "$u"
            return 0
        fi
    fi
    local email
    email="$(git config --global --get user.email 2>/dev/null || true)"
    if [[ "$email" =~ ^[0-9]+\+([a-zA-Z0-9-]+)@users\.noreply\.github\.com$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Detect the user's preferred git author name. Tries (in order):
#   1. gh CLI (`gh api user`) if installed + authenticated
#   2. `git config --global user.name`
# Prints the name on success, nothing on failure.
detect_git_author_name() {
    if command -v gh &>/dev/null; then
        local n
        n="$(gh api user 2>/dev/null | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
        if [[ -n "$n" && "$n" != "null" ]]; then
            printf '%s' "$n"
            return 0
        fi
    fi
    local name
    name="$(git config --global --get user.name 2>/dev/null || true)"
    if [[ -n "$name" ]]; then
        printf '%s' "$name"
        return 0
    fi
    return 1
}

load_or_prompt_identity() {
    mkdir -p "$(dirname "$IDENTITY_CACHE")"
    local cached_gh_user="" cached_gh_user_id="" cached_git_name="" cached_git_email=""
    if [[ -f "$IDENTITY_CACHE" ]]; then
        # shellcheck disable=SC1090
        source "$IDENTITY_CACHE"
        cached_gh_user="${CACHED_GH_USER:-}"
        cached_gh_user_id="${CACHED_GH_USER_ID:-}"
        cached_git_name="${CACHED_GIT_NAME:-}"
        cached_git_email="${CACHED_GIT_EMAIL:-}"
    fi

    # Env > cache. (dev-setup runs on a fresh machine, so there's no
    # ~/.gitconfig to fall back to.)
    GH_USER="${BOOTSTRAP_GH_USER:-$cached_gh_user}"
    GH_USER_ID="${BOOTSTRAP_GH_USER_ID:-$cached_gh_user_id}"
    GIT_NAME="${BOOTSTRAP_GIT_NAME:-$cached_git_name}"
    GIT_EMAIL="${BOOTSTRAP_GIT_EMAIL:-$cached_git_email}"

    # Username: detect from gh CLI or .gitconfig (noreply parse) and offer as
    # Enter-to-accept default. No silent fallback — always give the user a
    # chance to confirm or type something else.
    if [[ -z "$GH_USER" ]]; then
        local detected_user
        detected_user="$(detect_github_username || true)"
        if [[ -n "$detected_user" ]]; then
            prompt "GitHub username [Enter for ${detected_user}]:"
            read -r GH_USER < /dev/tty
            GH_USER="${GH_USER:-$detected_user}"
        else
            prompt "GitHub username:"
            read -r GH_USER < /dev/tty
        fi
    fi

    # Auto-fetch the numeric ID from the GitHub API so the user never has to
    # look it up. Only prompts if the fetch fails (offline / rate-limited /
    # typo). Cached after first run so we don't re-hit the API every time.
    if [[ -z "$GH_USER_ID" ]]; then
        info "Looking up numeric GitHub user ID for '${GH_USER}'..."
        GH_USER_ID="$(fetch_github_user_id "$GH_USER" || true)"
        if [[ -n "$GH_USER_ID" ]]; then
            info "Resolved ID: ${GH_USER_ID}"
        else
            warn "Couldn't fetch from api.github.com (offline / typo / rate limit)."
            prompt "GitHub numeric user ID (find at https://api.github.com/users/${GH_USER}):"
            read -r GH_USER_ID < /dev/tty
        fi
    fi

    # Author name: same detect-then-confirm pattern.
    if [[ -z "$GIT_NAME" ]]; then
        local detected_name
        detected_name="$(detect_git_author_name || true)"
        if [[ -n "$detected_name" ]]; then
            prompt "Git author name [Enter for ${detected_name}]:"
            read -r GIT_NAME < /dev/tty
            GIT_NAME="${GIT_NAME:-$detected_name}"
        else
            prompt "Git author name (e.g. 'Jane Doe'):"
            read -r GIT_NAME < /dev/tty
        fi
    fi

    # Always derive the noreply email — never prompt. This is the whole point:
    # eliminating the chance of a real address landing in a public commit by
    # mistake. To override, set BOOTSTRAP_GIT_EMAIL explicitly (and accept the
    # warning below).
    if [[ -z "$GIT_EMAIL" ]]; then
        GIT_EMAIL="${GH_USER_ID}+${GH_USER}@users.noreply.github.com"
    fi
    if [[ "$GIT_EMAIL" != *"@users.noreply.github.com" ]]; then
        warn "GIT_EMAIL is '${GIT_EMAIL}' — NOT a GitHub noreply address."
        warn "Every commit will publicly expose this address. Clear BOOTSTRAP_GIT_EMAIL"
        warn "and delete ${IDENTITY_CACHE} to fall back to the noreply default."
    fi

    for var_name in GH_USER GH_USER_ID GIT_NAME GIT_EMAIL; do
        if [[ -z "${!var_name}" ]]; then
            error "Identity field ${var_name} ended up empty — aborting."
            exit 1
        fi
    done

    {
        echo "# Cached by project-bootstrap. Override with BOOTSTRAP_* env vars."
        echo "CACHED_GH_USER='${GH_USER}'"
        echo "CACHED_GH_USER_ID='${GH_USER_ID}'"
        echo "CACHED_GIT_NAME='${GIT_NAME}'"
        echo "CACHED_GIT_EMAIL='${GIT_EMAIL}'"
        # Preserve dotfiles-path entry if a prior run recorded one.
        [[ -n "${CACHED_DOTFILES_PATH:-}" ]] && echo "CACHED_DOTFILES_PATH='${CACHED_DOTFILES_PATH}'"
    } > "$IDENTITY_CACHE"
    chmod 600 "$IDENTITY_CACHE"

    info "Identity: ${GIT_NAME} <${GIT_EMAIL}> (GitHub: ${GH_USER}, ID: ${GH_USER_ID})"
}

# Update a single field in the identity cache without disturbing the others.
# Used when we learn something new mid-run (e.g. CACHED_DOTFILES_PATH after a
# successful clone) that load_or_prompt_identity didn't have at the time.
update_cache_field() {
    local name="$1"
    local value="$2"
    mkdir -p "$(dirname "$IDENTITY_CACHE")"
    touch "$IDENTITY_CACHE"
    chmod 600 "$IDENTITY_CACHE"
    if grep -q "^${name}=" "$IDENTITY_CACHE" 2>/dev/null; then
        sed -i "/^${name}=/d" "$IDENTITY_CACHE"
    fi
    echo "${name}='${value}'" >> "$IDENTITY_CACHE"
}

# Pull the latest commits into an existing dotfiles checkout. Always called
# when we reuse a checkout so it tracks the remote — the dotfiles repo can
# change between bootstraps and the user explicitly wants the latest. Uses
# --ff-only so local edits aren't clobbered; falls back to a warning if pull
# can't fast-forward (divergence, network down, etc.) so the bootstrap still
# completes.
update_dotfiles_checkout() {
    local path="$1"
    info "Pulling latest from origin for ${path}..."
    if git -C "$path" pull --ff-only --quiet 2>&1; then
        success "Dotfiles up to date."
    else
        warn "Couldn't fast-forward dotfiles (network down, local changes, or remote divergence)."
        warn "Continuing with the current local copy. Inspect: git -C ${path} status"
    fi
}

# Probe SSH auth to the dotfiles-scoped alias. Returns 0 if GitHub recognizes
# the deploy key. `ssh -T` always exits 1 on github.com, so look for one of
# the success signatures in the output instead.
test_dotfiles_ssh() {
    local output
    output="$(timeout 15 ssh -T \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        "git@${DOTFILES_SSH_HOST}" < /dev/null 2>&1 || true)"
    debug "test_dotfiles_ssh output: ${output}"
    echo "$output" | grep -qiE "successfully authenticated|deploy key|does not provide shell access"
}

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
# the OS clipboard" → "best-effort terminal escape" → "give up".
# Reports outcome via the global CLIP_STATUS instead of return codes so callers
# never trip the ERR trap (some bash builds fire ERR even with set +e).
# CLIP_STATUS values: "ok" | "osc52" | "none"
CLIP_STATUS="none"
clip_copy() {
    local content="$1"
    CLIP_STATUS="none"
    if command -v clip.exe &> /dev/null; then
        if printf '%s' "$content" | clip.exe 2>/dev/null; then
            debug "clip_copy: used clip.exe"
            CLIP_STATUS="ok"
            return 0
        fi
        warn "clip.exe present but failed."
    fi
    if command -v pbcopy &> /dev/null; then
        if printf '%s' "$content" | pbcopy 2>/dev/null; then
            debug "clip_copy: used pbcopy"
            CLIP_STATUS="ok"
            return 0
        fi
    fi
    if command -v wl-copy &> /dev/null; then
        if printf '%s' "$content" | wl-copy 2>/dev/null; then
            debug "clip_copy: used wl-copy"
            CLIP_STATUS="ok"
            return 0
        fi
    fi
    if command -v xclip &> /dev/null; then
        if printf '%s' "$content" | xclip -selection clipboard 2>/dev/null; then
            debug "clip_copy: used xclip"
            CLIP_STATUS="ok"
            return 0
        fi
    fi
    if command -v xsel &> /dev/null; then
        if printf '%s' "$content" | xsel --clipboard --input 2>/dev/null; then
            debug "clip_copy: used xsel"
            CLIP_STATUS="ok"
            return 0
        fi
    fi
    # OSC52 terminal escape — works in many modern terminals (VS Code,
    # Windows Terminal, iTerm2, kitty, tmux 3.3+). Fire-and-forget; we can't
    # confirm the terminal honored it, only that we emitted it.
    local b64=""
    b64="$(printf '%s' "$content" | base64 -w0 2>/dev/null)" \
        || b64="$(printf '%s' "$content" | base64 | tr -d '\n')" \
        || b64=""
    if [[ -n "$b64" ]]; then
        printf '\033]52;c;%s\007' "$b64"
        debug "clip_copy: emitted OSC52 escape (terminal may or may not honor)"
        CLIP_STATUS="osc52"
        return 0
    fi
    debug "clip_copy: no clipboard mechanism available"
    CLIP_STATUS="none"
    return 0
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
    # window (dev container, SSH, Codespaces). This is the right path when
    # running inside a dev-container or remote SSH context.
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

# ----- Resolve identity ----------------------------------------------------
step "Resolve identity"
load_or_prompt_identity

# Derived URLs / repo locations.
DOTFILES_REPO="git@${DOTFILES_SSH_HOST}:${GH_USER}/${DOTFILES_REPO_NAME}.git"
BOOTSTRAP_REPO="https://github.com/${GH_USER}/${BOOTSTRAP_REPO_NAME}.git"

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
step "Deploy key for ${DOTFILES_REPO_NAME} (read-only, repo-scoped)"
echo ""
echo "This sets up a READ-ONLY DEPLOY KEY scoped to just the ${DOTFILES_REPO_NAME} repo."
echo "Not a user-account key — no broad access to any of your other repos."
echo "(${BOOTSTRAP_REPO_NAME} is public, so it doesn't need any key.)"
echo ""

KEY_ALREADY_EXISTED=0
if [[ -f "$DOTFILES_KEY_PATH" ]]; then
    info "Existing ${DOTFILES_REPO_NAME} key found at ${DOTFILES_KEY_PATH} — reusing."
    KEY_ALREADY_EXISTED=1
else
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -C "${GIT_EMAIL} (${DOTFILES_REPO_NAME} read-only deploy key)" -f "$DOTFILES_KEY_PATH" -N ""
    success "Key generated at ${DOTFILES_KEY_PATH}"
fi

# SSH config alias so 'git@github.com-<dotfiles-repo>:...' uses this key.
SSH_CONFIG="${HOME}/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
if ! grep -q "^Host ${DOTFILES_SSH_HOST}$" "$SSH_CONFIG"; then
    {
        echo ""
        echo "# Added by project-bootstrap/dev-setup.sh — read-only key for ${DOTFILES_REPO_NAME}"
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
KEY_TITLE="$(hostname) - $(date +%Y-%m-%d)"

# Always walk through registration. If the key is already registered, the
# user just confirms quickly on the GitHub page (or re-adds idempotently).
# This avoids the failure mode of "yes it's registered" → SSH test fails.

# Helper to put a value on the clipboard with consistent status messaging.
copy_and_report() {
    local label="$1"
    local value="$2"
    clip_copy "$value"
    case "$CLIP_STATUS" in
        ok)    success "${label} copied to clipboard." ;;
        osc52) warn "${label} sent via OSC52 terminal escape — your terminal may or may not have honored it." ;;
        *)     warn "Couldn't reach any clipboard tool — copy the ${label,,} from the box above manually." ;;
    esac
}

GITHUB_KEYS_URL="https://github.com/${GH_USER}/${DOTFILES_REPO_NAME}/settings/keys/new"
info "Deploy key page: ${GITHUB_KEYS_URL}"
# open_url uses `if` so its non-zero return is safe re: ERR trap.
if open_url "$GITHUB_KEYS_URL"; then
    success "Tried to open browser. If nothing happened, use the URL above (in VS Code's terminal, Ctrl+Click on the URL works)."
else
    warn "No browser-opener was available. Open this URL manually:"
    boxed_print "URL" "${GITHUB_KEYS_URL}"
fi

# Copy title then pubkey back-to-back. Both will be in clipboard history (no
# intermediate prompt). A small sleep between copies so the OS clipboard
# subsystem registers two distinct events rather than coalescing them.
echo ""
boxed_print "TITLE — copy this if the clipboard didn't grab it" "${KEY_TITLE}"
copy_and_report "Title" "$KEY_TITLE"
sleep 1
echo ""
boxed_print "PUBLIC KEY — copy this if the clipboard didn't grab it" "${PUBKEY}"
copy_and_report "Public key" "$PUBKEY"

echo ""
info "On the page (both title + key are now in your clipboard history):"
echo "  1. Paste the TITLE into the 'Title' field"
echo "  2. Paste the PUBLIC KEY into the 'Key' field"
echo "  3. LEAVE 'Allow write access' UNCHECKED (read-only)"
echo "  4. Click 'Add key' — if the key is already there, GitHub will say so; that's fine"
echo ""
prompt "Press Enter once the key is added on GitHub..."
read -r _ < /dev/tty || true

# ----- Step 3: test SSH auth for the dotfiles alias ------------------------
step "Verify SSH auth (via ${DOTFILES_REPO_NAME} alias)"
# Loop the SSH test rather than exiting on the first failure — GitHub takes a
# beat to propagate a new deploy key, and the user may have mis-clicked the
# 'Add key' page. Give them a few chances to fix it without re-running.
info "Testing: ssh -T -o StrictHostKeyChecking=accept-new git@${DOTFILES_SSH_HOST}"

ssh_attempt=1
ssh_max_attempts=3
ssh_ok=0
# Disable ERR trap + set -e around the loop so weird exits from ssh/timeout
# can't kill the script silently.
trap - ERR
set +e
while (( ssh_attempt <= ssh_max_attempts )); do
    info "Attempt ${ssh_attempt}/${ssh_max_attempts}..."
    ssh_output="$(timeout 30 ssh -T \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        "git@${DOTFILES_SSH_HOST}" < /dev/null 2>&1)"
    ssh_exit=$?
    if [[ "$ssh_exit" == "124" ]]; then
        warn "ssh timed out after 30s (exit 124)."
    fi
    info "ssh exit code: ${ssh_exit}"
    if [[ -n "$ssh_output" ]]; then
        echo "$ssh_output" | sed 's/^/    /'
    else
        warn "(no output captured)"
    fi

    if echo "$ssh_output" | grep -qiE "successfully authenticated|deploy key|does not provide shell access"; then
        ssh_ok=1
        break
    fi

    if (( ssh_attempt < ssh_max_attempts )); then
        warn "SSH didn't authenticate. Common causes:"
        warn "  - Deploy key not actually added on GitHub (recheck the page)"
        warn "  - GitHub still propagating the key (wait 15-30s)"
        warn "  - Network/firewall blocking SSH on port 22"
        warn "Add key at: ${GITHUB_KEYS_URL}"
        echo ""
        if open_url "$GITHUB_KEYS_URL"; then
            info "Re-opened the deploy keys page in your browser."
        fi
        prompt "Press Enter to retry, or type 'q' to abort: "
        retry_reply=""
        read -r retry_reply < /dev/tty || retry_reply="q"
        if [[ "$retry_reply" == "q" || "$retry_reply" == "Q" ]]; then
            break
        fi
    fi
    ssh_attempt=$((ssh_attempt + 1))
done
set -e
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

if (( ssh_ok == 1 )); then
    success "SSH auth working for ${DOTFILES_REPO_NAME}."
else
    error "SSH auth check failed after ${ssh_max_attempts} attempts."
    error "Add the deploy key at: https://github.com/${GH_USER}/${DOTFILES_REPO_NAME}/settings/keys"
    error "Re-run this script when you're ready."
    error "Log file: ${LOG_FILE}"
    exit 1
fi

# ----- Step 4: clone repos --------------------------------------------------
step "Clone ${DOTFILES_REPO_NAME} + ${BOOTSTRAP_REPO_NAME}"
cd "$WORK_DIR"
if [[ -d "${WORK_DIR}/${DOTFILES_REPO_NAME}/.git" ]]; then
    info "${DOTFILES_REPO_NAME} repo already cloned."
    update_dotfiles_checkout "${WORK_DIR}/${DOTFILES_REPO_NAME}"
else
    git clone "$DOTFILES_REPO" "${WORK_DIR}/${DOTFILES_REPO_NAME}"
    success "Cloned ${DOTFILES_REPO_NAME}."
fi
# Record the dotfiles location so init.sh (per-project setup) can find this
# checkout instead of trying to re-clone into ~/.dotfiles.
update_cache_field "CACHED_DOTFILES_PATH" "${WORK_DIR}/${DOTFILES_REPO_NAME}"

if [[ -d "${WORK_DIR}/${BOOTSTRAP_REPO_NAME}/.git" ]]; then
    info "${BOOTSTRAP_REPO_NAME} repo already cloned — skipping."
else
    git clone "$BOOTSTRAP_REPO" "${WORK_DIR}/${BOOTSTRAP_REPO_NAME}"
    success "Cloned ${BOOTSTRAP_REPO_NAME}."
fi

# ----- Step 5: run dotfiles install ----------------------------------------
step "Install dotfiles"
"${WORK_DIR}/${DOTFILES_REPO_NAME}/install.sh"

# ----- Step 6: wire up Claude memory symlink -------------------------------
step "Wire up Claude Code memory sync"
MEMORY_SRC="${WORK_DIR}/${DOTFILES_REPO_NAME}/claude-memory-bootstrap"
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
NEXT_CMD="(cd ${WORK_DIR}/${BOOTSTRAP_REPO_NAME} && code .)"
echo "Next steps:"
echo "  1. Open ${BOOTSTRAP_REPO_NAME} in VS Code: ${NEXT_CMD}"
echo "  2. Or work on ${DOTFILES_REPO_NAME}:        (cd ${WORK_DIR}/${DOTFILES_REPO_NAME} && code .)"
echo ""
clip_copy "$NEXT_CMD"
case "$CLIP_STATUS" in
    ok)    info "Step 1 command copied to clipboard — just paste in your shell." ;;
    osc52) info "Step 1 command sent via OSC52 — may need to be copied manually." ;;
    *)     info "No clipboard available — copy the command from above." ;;
esac

info "Log file: ${LOG_FILE}"
