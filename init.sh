#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Project Bootstrap — per-project setup
# Run from inside an empty new project folder.
#
# Identity (GitHub user, git name/email) is sourced in this priority order:
#   1. BOOTSTRAP_GH_USER / BOOTSTRAP_GH_USER_ID / BOOTSTRAP_GIT_NAME
#      / BOOTSTRAP_GIT_EMAIL env vars
#   2. Cache file at $XDG_CONFIG_HOME (or ~/.config) /project-bootstrap/user.env
#   3. `git config --global user.{name,email}` (for name/email only)
#   4. Interactive prompt over /dev/tty
# Whatever is resolved is written back to the cache file so future runs are
# non-interactive.
# ============================================================================

# Repo names default to the canonical pair but can be overridden if you forked
# them under different names.
BOOTSTRAP_REPO_NAME="${BOOTSTRAP_REPO_NAME:-project-bootstrap}"
DOTFILES_REPO_NAME="${DOTFILES_REPO_NAME:-dotfiles}"

# ----- Logging ---------------------------------------------------------------
# All output tees to a timestamped log file so failures stay diagnosable
# after the fact. Log helpers prefix each line with their own timestamp;
# we don't pipe through awk/while-read since that line-buffers interactive
# prompts (and breaks `read -p`'s newline-less prompt rendering).
LOG_DIR="${HOME}/.cache/project-bootstrap"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/init-$(date +%Y%m%d-%H%M%S).log"
# tee -a writes character-by-character so interactive prompts work normally.
exec > >(tee -a "$LOG_FILE") 2>&1

ts()      { date +%H:%M:%S; }
info()    { echo -e "\033[90m[$(ts)]\033[0m \033[36m[INFO]\033[0m $1"; }
success() { echo -e "\033[90m[$(ts)]\033[0m \033[32m[OK]\033[0m $1"; }
warn()    { echo -e "\033[90m[$(ts)]\033[0m \033[33m[WARN]\033[0m $1"; }
error()   { echo -e "\033[90m[$(ts)]\033[0m \033[31m[ERROR]\033[0m $1"; }
prompt()  { echo -e "\033[90m[$(ts)]\033[0m \033[34m[?]\033[0m $1"; }
step()    { echo ""; echo -e "\033[90m[$(ts)]\033[0m \033[35m=== $1 ===\033[0m"; }
debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "\033[90m[$(ts)] [DEBUG]\033[0m $1" || true; }

# Trap any unexpected exit and print the line/command that triggered it.
# Without this, `set -e` makes failures invisible — we'd see step N start
# then nothing more.
on_err() {
    local exit_code=$?
    local line=$1
    local cmd=$2
    echo ""
    error "FATAL at line ${line}: command \`${cmd}\` exited ${exit_code}"
    error "See full log: ${LOG_FILE}"
    exit "$exit_code"
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

info "Log file: ${LOG_FILE}"
debug "Set DEBUG=1 before running for extra-verbose tracing"

# ----- Identity (env > cache > git config > auto-fetch > prompt) ------------
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
        # Preserve dotfiles-path entry if a prior run (this script or
        # dev-setup.sh) recorded one. Re-emitting it here keeps the writeback
        # idempotent without losing other scripts' state.
        [[ -n "${CACHED_DOTFILES_PATH:-}" ]] && echo "CACHED_DOTFILES_PATH='${CACHED_DOTFILES_PATH}'"
    } > "$IDENTITY_CACHE"
    chmod 600 "$IDENTITY_CACHE"

    info "Identity: ${GIT_NAME} <${GIT_EMAIL}> (GitHub: ${GH_USER}, ID: ${GH_USER_ID})"
}

load_or_prompt_identity

# Derived URL (built from resolved identity).
BOOTSTRAP_RAW="https://raw.githubusercontent.com/${GH_USER}/${BOOTSTRAP_REPO_NAME}/main"

# Try several browser-opener tools. On WSL without wslview/xdg-open,
# falls back to cmd.exe which is always present via WSL interop.
open_url() {
    local url="$1"
    if command -v wslview &> /dev/null; then
        debug "open_url: trying wslview"
        if wslview "$url" < /dev/null > /dev/null 2>&1; then
            info "Opened via wslview"
            return 0
        fi
    fi
    if command -v xdg-open &> /dev/null; then
        debug "open_url: trying xdg-open"
        if xdg-open "$url" < /dev/null > /dev/null 2>&1; then
            info "Opened via xdg-open"
            return 0
        fi
    fi
    if command -v cmd.exe &> /dev/null; then
        debug "open_url: trying cmd.exe /c start (backgrounded)"
        # Detach fully: background + nohup so cmd.exe's brief tty grab
        # doesn't break the next interactive read on /dev/tty.
        (cd /mnt/c && nohup cmd.exe /c start "" "$url" < /dev/null > /dev/null 2>&1 &) 2>/dev/null
        sleep 1
        info "Opened via cmd.exe (Windows interop)"
        return 0
    fi
    debug "open_url: no opener found"
    return 1
}

# Try every clipboard mechanism we know about, in order of "actually copies to
# the OS clipboard" → "best-effort terminal escape" → "give up". Reports
# outcome via the global CLIP_STATUS instead of return codes so callers never
# trip the ERR trap (some bash builds fire ERR even with set +e).
# CLIP_STATUS values: "ok" | "osc52" | "none"
CLIP_STATUS="none"
clip_copy() {
    local content="$1"
    CLIP_STATUS="none"
    if command -v clip.exe &> /dev/null; then
        if printf '%s' "$content" | clip.exe 2>/dev/null; then
            CLIP_STATUS="ok"; return 0
        fi
    fi
    if command -v pbcopy &> /dev/null; then
        if printf '%s' "$content" | pbcopy 2>/dev/null; then
            CLIP_STATUS="ok"; return 0
        fi
    fi
    if command -v wl-copy &> /dev/null; then
        if printf '%s' "$content" | wl-copy 2>/dev/null; then
            CLIP_STATUS="ok"; return 0
        fi
    fi
    if command -v xclip &> /dev/null; then
        if printf '%s' "$content" | xclip -selection clipboard 2>/dev/null; then
            CLIP_STATUS="ok"; return 0
        fi
    fi
    if command -v xsel &> /dev/null; then
        if printf '%s' "$content" | xsel --clipboard --input 2>/dev/null; then
            CLIP_STATUS="ok"; return 0
        fi
    fi
    # OSC52 terminal escape — works in VS Code terminal, Windows Terminal,
    # iTerm2, kitty, tmux 3.3+. Fire-and-forget; can't confirm the terminal
    # honored it, only that we emitted it.
    local b64
    b64="$(printf '%s' "$content" | base64 -w0 2>/dev/null)" \
        || b64="$(printf '%s' "$content" | base64 | tr -d '\n')" \
        || b64=""
    if [[ -n "$b64" ]]; then
        printf '\033]52;c;%s\007' "$b64"
        CLIP_STATUS="osc52"; return 0
    fi
    return 0
}

# Put a value on the clipboard with consistent status messaging. Lets the
# caller stay quiet about which clipboard mechanism actually fired.
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

# Bordered print so the user can scroll up and find the value easily when
# clipboard automation fails.
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

# Update a single field in the identity cache without disturbing the others.
# Used when a script learns something new mid-run (e.g. CACHED_DOTFILES_PATH
# after a successful clone) that load_or_prompt_identity didn't know about.
update_cache_field() {
    local name="$1"
    local value="$2"
    mkdir -p "$(dirname "$IDENTITY_CACHE")"
    touch "$IDENTITY_CACHE"
    chmod 600 "$IDENTITY_CACHE"
    # Drop any prior entry for this field.
    if grep -q "^${name}=" "$IDENTITY_CACHE" 2>/dev/null; then
        sed -i "/^${name}=/d" "$IDENTITY_CACHE"
    fi
    echo "${name}='${value}'" >> "$IDENTITY_CACHE"
}

# Pull the latest commits into an existing dotfiles checkout. Always called
# when we reuse a checkout so the installed config reflects what's on the
# remote — the repo can change between bootstraps and the user explicitly
# wants the latest. Uses --ff-only so local edits (someone actively iterating
# on dotfiles) aren't clobbered; falls back to a warning if pull can't fast-
# forward (divergence, network down, etc.) so the bootstrap still completes.
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
    local ssh_host_alias="github.com-${DOTFILES_REPO_NAME}"
    local output
    output="$(timeout 15 ssh -T \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        "git@${ssh_host_alias}" < /dev/null 2>&1 || true)"
    debug "test_dotfiles_ssh output: ${output}"
    echo "$output" | grep -qiE "successfully authenticated|deploy key|does not provide shell access"
}

# Clone the dotfiles repo into $1. Tries HTTPS (works anonymously for public
# repos); if that fails, walks the user through generating an SSH deploy key,
# registering it on GitHub, and retries via the SSH alias.
#
# Mirrors dev-setup.sh's deploy-key flow but is intentionally lighter — init.sh
# is per-project, not per-machine, so a few extra prompts are fine.
ensure_dotfiles_clone() {
    local target="$1"
    local https_url="https://github.com/${GH_USER}/${DOTFILES_REPO_NAME}.git"
    local ssh_host_alias="github.com-${DOTFILES_REPO_NAME}"
    local ssh_url="git@${ssh_host_alias}:${GH_USER}/${DOTFILES_REPO_NAME}.git"

    if [[ -d "${target}/.git" ]]; then
        return 0
    fi

    info "Attempting anonymous HTTPS clone of ${DOTFILES_REPO_NAME}..."
    # Run inside an if so a failed clone doesn't trip the ERR trap.
    if git clone "$https_url" "$target" 2>/dev/null; then
        success "Cloned via HTTPS."
        return 0
    fi
    warn "HTTPS clone failed — repo is probably private."
    info "Let's set up an SSH deploy key so we can read it."

    # 1. Generate the key (or reuse).
    local key_path="${HOME}/.ssh/${DOTFILES_REPO_NAME}_ed25519"
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    if [[ ! -f "$key_path" ]]; then
        ssh-keygen -t ed25519 \
            -C "${GIT_EMAIL} (${DOTFILES_REPO_NAME} read-only deploy key)" \
            -f "$key_path" -N ""
        success "Generated SSH key at ${key_path}"
    else
        info "Reusing existing SSH key at ${key_path}"
    fi

    # 2. Add the SSH config alias (so the SSH URL picks the right key).
    local ssh_config="${HOME}/.ssh/config"
    touch "$ssh_config"
    chmod 600 "$ssh_config"
    if ! grep -q "^Host ${ssh_host_alias}$" "$ssh_config"; then
        {
            echo ""
            echo "# Added by project-bootstrap/init.sh — read-only key for ${DOTFILES_REPO_NAME}"
            echo "Host ${ssh_host_alias}"
            echo "    HostName github.com"
            echo "    User git"
            echo "    IdentityFile ${key_path}"
            echo "    IdentitiesOnly yes"
        } >> "$ssh_config"
        success "Added SSH config alias '${ssh_host_alias}'"
    fi

    # 3. Maybe the key was registered on a prior run — try SSH first to skip
    #    the walk-through entirely.
    if test_dotfiles_ssh; then
        info "SSH already works (key was registered before)."
        if git clone "$ssh_url" "$target"; then
            success "Cloned via SSH deploy key."
            return 0
        fi
    fi

    # 4. Walk the user through adding the key on GitHub.
    local deploy_keys_url="https://github.com/${GH_USER}/${DOTFILES_REPO_NAME}/settings/keys/new"
    echo ""
    echo "============================================================"
    echo "  PUBLIC KEY (copy this entire line):"
    echo "============================================================"
    cat "${key_path}.pub"
    echo "============================================================"
    echo ""
    echo "Add it as a deploy key on:"
    echo "    ${deploy_keys_url}"
    echo ""
    echo "  - Paste the key above into the 'Key' field"
    echo "  - LEAVE 'Allow write access' UNCHECKED (this is read-only)"
    echo "  - Click 'Add key'"
    echo ""
    open_url "$deploy_keys_url" || warn "Couldn't auto-open browser — copy the URL above manually."

    # 5. Retry loop: give a few chances since GitHub takes a moment to
    #    propagate a new key and the user might mis-click.
    local attempt
    for attempt in 1 2 3; do
        echo ""
        local reply
        if ! read -r -p "Press Enter once the deploy key is added (or 'q' to skip dotfiles): " reply < /dev/tty; then
            warn "Couldn't read terminal — aborting dotfiles setup."
            return 1
        fi
        if [[ "$reply" == "q" || "$reply" == "Q" ]]; then
            warn "User quit dotfiles setup."
            return 1
        fi

        info "Testing SSH access (attempt ${attempt}/3)..."
        if test_dotfiles_ssh; then
            if git clone "$ssh_url" "$target"; then
                success "Cloned via SSH deploy key."
                return 0
            fi
            warn "SSH auth worked but clone failed. Trying once more..."
            continue
        fi

        warn "SSH still not authenticating. Common causes:"
        warn "  - Deploy key not actually added on GitHub (recheck the page)"
        warn "  - GitHub still propagating (wait 15-30s)"
        warn "  - Network blocking SSH on port 22"
        warn "Deploy keys page: ${deploy_keys_url}"
    done

    error "Gave up after 3 attempts — could not enable dotfiles access."
    return 1
}

PROJECT_NAME="$(basename "$(pwd)")"
info "Bootstrapping project: $PROJECT_NAME"

# ----------------------------------------------------------------------------
# Step 1: Update OS packages
# ----------------------------------------------------------------------------
step "1/14: Updating OS packages"
sudo apt-get update && sudo apt-get upgrade -y

# ----------------------------------------------------------------------------
# Step 2: Ensure system Node.js + latest npm
# ----------------------------------------------------------------------------
# Check what sudo sees, not the user's PATH — nvm-managed node lives in
# ~/.nvm and isn't visible to root, so sudo npm install -g would fail.
step "2/14: Ensuring system Node.js"
if ! sudo bash -c 'command -v node && command -v npm' &> /dev/null; then
    info "System Node.js/npm not found — installing LTS via NodeSource"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -
    sudo apt-get install -y nodejs
fi
sudo npm install -g npm@latest

# ----------------------------------------------------------------------------
# Step 3: Install Claude Code (npm install -g is idempotent)
# ----------------------------------------------------------------------------
step "3/14: Installing Claude Code"
sudo npm install -g @anthropic-ai/claude-code
success "Claude Code ready"

# ----------------------------------------------------------------------------
# Step 4: Dotfiles
# ----------------------------------------------------------------------------
step "4/14: Checking dotfiles"
# Resolve where dotfiles already lives (if anywhere). Priority:
#   1. CACHED_DOTFILES_PATH from the identity cache (set by dev-setup.sh on
#      fresh-machine setup, or by a prior init.sh run).
#   2. ~/.dotfiles (legacy / init.sh's own clone target).
# If neither exists, walk through ensure_dotfiles_clone — which tries HTTPS
# first and falls back to a guided SSH deploy-key flow if the repo is private.
DOTFILES_PATH=""
if [[ -n "${CACHED_DOTFILES_PATH:-}" && -d "${CACHED_DOTFILES_PATH}/.git" ]]; then
    DOTFILES_PATH="$CACHED_DOTFILES_PATH"
    success "Dotfiles already at ${DOTFILES_PATH} (from cache)"
    update_dotfiles_checkout "$DOTFILES_PATH"
elif [[ -d "${HOME}/.dotfiles/.git" ]]; then
    DOTFILES_PATH="${HOME}/.dotfiles"
    success "Dotfiles already at ${DOTFILES_PATH}"
    update_dotfiles_checkout "$DOTFILES_PATH"
else
    read -p "Dotfiles not found locally. Clone and install now? [Y/n] " -n 1 -r < /dev/tty
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if ensure_dotfiles_clone "${HOME}/.dotfiles"; then
            DOTFILES_PATH="${HOME}/.dotfiles"
        else
            warn "Continuing without dotfiles. Re-run init.sh later, or run dev-setup.sh, to retry."
        fi
    else
        info "Skipping dotfiles install."
    fi
fi

if [[ -n "$DOTFILES_PATH" ]]; then
    info "Running ${DOTFILES_PATH}/install.sh"
    bash "${DOTFILES_PATH}/install.sh"
    update_cache_field "CACHED_DOTFILES_PATH" "$DOTFILES_PATH"
fi

# ----------------------------------------------------------------------------
# Step 5: Global git config
# ----------------------------------------------------------------------------
# Dotfiles' install.sh symlinks ~/.gitconfig to its own .gitconfig, so writing
# `git config --global` here would silently mutate the dotfiles repo. Detect
# that and skip — trust whatever the symlink points to.
step "5/14: Configuring global git"
if [[ -L "${HOME}/.gitconfig" ]]; then
    info "~/.gitconfig is a symlink (managed by dotfiles) — leaving it alone"
else
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    git config --global init.defaultBranch main
    success "Wrote ~/.gitconfig"
fi

# ----------------------------------------------------------------------------
# Step 6: Copy .devcontainer files
# ----------------------------------------------------------------------------
step "6/14: Setting up dev container"
mkdir -p .devcontainer
curl -fsSL "${BOOTSTRAP_RAW}/.devcontainer/devcontainer.json" -o .devcontainer/devcontainer.json
curl -fsSL "${BOOTSTRAP_RAW}/.devcontainer/Dockerfile" -o .devcontainer/Dockerfile
success "Dev container files copied"

# ----------------------------------------------------------------------------
# Step 7: Get repo URL
# ----------------------------------------------------------------------------
step "7/14: Repository setup"
DEFAULT_REPO_URL="https://github.com/${GH_USER}/${PROJECT_NAME}"
echo "Paste the GitHub URL of your new (empty) repo, or press Enter to use:"
echo "  ${DEFAULT_REPO_URL}"
echo "Accepted formats:"
echo "  https://github.com/user/repo"
echo "  https://github.com/user/repo.git"
echo "  git@github.com:user/repo.git"
read -p "URL [Enter for ${DEFAULT_REPO_URL}]: " REPO_URL < /dev/tty
REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"

if [[ "$REPO_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
    REPO_USER="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
else
    error "Could not parse repo URL"
    exit 1
fi
info "Repo: ${REPO_USER}/${REPO_NAME}"

# ----------------------------------------------------------------------------
# Step 8: Generate per-project SSH key
# ----------------------------------------------------------------------------
step "8/14: Generating SSH key"
KEY_NAME="${PROJECT_NAME}_ed25519"
KEY_PATH="${HOME}/.ssh/${KEY_NAME}"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
if [[ -f "$KEY_PATH" ]]; then
    warn "Key already exists at $KEY_PATH (reusing)"
else
    ssh-keygen -t ed25519 -C "${GIT_EMAIL} (${REPO_USER}/${REPO_NAME})" -f "$KEY_PATH" -N ""
    success "Key generated"
fi

# ----------------------------------------------------------------------------
# Step 9: SSH config entry
# ----------------------------------------------------------------------------
step "9/14: Configuring SSH"
SSH_HOST_ALIAS="github.com-${PROJECT_NAME}"
SSH_CONFIG="${HOME}/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

if ! grep -q "Host ${SSH_HOST_ALIAS}$" "$SSH_CONFIG"; then
    cat >> "$SSH_CONFIG" <<EOF

Host ${SSH_HOST_ALIAS}
    HostName github.com
    User git
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
EOF
    success "SSH config entry added"
else
    info "SSH config entry already present"
fi

# ----------------------------------------------------------------------------
# Step 10 & 11: Print key, open browser, prompt for upload
# ----------------------------------------------------------------------------
step "10-11/14: Add deploy key + upload initial files"

DEPLOY_KEYS_URL="https://github.com/${REPO_USER}/${REPO_NAME}/settings/keys/new"
REPO_PAGE_URL="https://github.com/${REPO_USER}/${REPO_NAME}"
PUBKEY="$(cat "${KEY_PATH}.pub")"
KEY_TITLE="$(hostname) - $(date +%Y-%m-%d)"

# Open the deploy-keys page first so the user can switch over while we copy.
if open_url "$DEPLOY_KEYS_URL"; then
    info "Opened deploy keys page in your browser."
else
    warn "Could not auto-open browser — visit this URL manually: ${DEPLOY_KEYS_URL}"
fi

# Copy title then pubkey back-to-back. Both end up in clipboard history (no
# intermediate prompt). Small sleep between copies so the OS clipboard
# subsystem registers two distinct events rather than coalescing them.
boxed_print "TITLE — copy this if the clipboard didn't grab it" "${KEY_TITLE}"
copy_and_report "Title" "$KEY_TITLE"
sleep 1
boxed_print "PUBLIC KEY — copy this if the clipboard didn't grab it" "${PUBKEY}"
copy_and_report "Public key" "$PUBKEY"

echo ""
echo "On github.com, do BOTH of these (both title + key are in your clipboard history):"
echo ""
echo "  1. Add the deploy key at:"
echo "     ${DEPLOY_KEYS_URL}"
echo "     - Paste the TITLE into the 'Title' field"
echo "     - Paste the PUBLIC KEY into the 'Key' field"
echo "     - CHECK the 'Allow write access' box"
echo "     - Click 'Add key'"
echo ""
echo "  2. Upload any initial files for this project at:"
echo "     ${REPO_PAGE_URL}"
echo "     - Drag and drop files into the repo"
echo "     - Commit them via the web UI"
echo ""

# Use a tolerant read — if /dev/tty isn't readable (e.g. interop briefly
# disrupted it), don't crash; just continue. User can re-run if needed.
if ! read -p "Press Enter once BOTH the deploy key is added AND any initial files are uploaded... " < /dev/tty; then
    warn "Could not read from terminal; assuming you're ready. Re-run if you need more time."
fi

# ----------------------------------------------------------------------------
# Step 12: Test SSH
# ----------------------------------------------------------------------------
step "12/14: Testing SSH connection"
debug "Running: ssh -T -o StrictHostKeyChecking=accept-new git@${SSH_HOST_ALIAS}"
SSH_TEST=$(ssh -T -o StrictHostKeyChecking=accept-new "git@${SSH_HOST_ALIAS}" < /dev/null 2>&1 || true)
echo "$SSH_TEST"
if echo "$SSH_TEST" | grep -q "successfully authenticated"; then
    success "SSH connection works"
else
    warn "SSH did not authenticate. Most common cause: deploy key not added on GitHub, or 'Allow write access' wasn't checked."
    if ! read -p "Continue anyway? [y/N] " -n 1 -r < /dev/tty; then
        error "Could not read response; aborting"
        exit 1
    fi
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# ----------------------------------------------------------------------------
# Step 13: Init local repo, set remote
# ----------------------------------------------------------------------------
step "13/14: Initializing local git"
if [[ ! -d .git ]]; then
    git init -b main
fi
REMOTE_URL="git@${SSH_HOST_ALIAS}:${REPO_USER}/${REPO_NAME}.git"
if git remote get-url origin &> /dev/null; then
    git remote set-url origin "$REMOTE_URL"
else
    git remote add origin "$REMOTE_URL"
fi
success "Remote: $REMOTE_URL"

# ----------------------------------------------------------------------------
# Step 14: Pull repo contents (any files uploaded via the web UI)
# ----------------------------------------------------------------------------
step "14/14: Pulling repo contents"
git fetch origin 2>/dev/null || true
DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo "main")
if git ls-remote --exit-code --heads origin "$DEFAULT_BRANCH" &> /dev/null; then
    git pull origin "$DEFAULT_BRANCH" --allow-unrelated-histories || warn "Pull had issues — check manually"
    success "Files pulled from $DEFAULT_BRANCH"
else
    warn "Remote branch '$DEFAULT_BRANCH' not found (repo may still be empty)"
fi

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
echo ""
success "Bootstrap complete!"
echo ""
NEXT_CMD="(cd $(pwd) && code .)"
echo "Next steps:"
echo "  1. Open in VS Code:                 ${NEXT_CMD}"
echo "  2. Command palette → 'Dev Containers: Reopen in Container'"
echo "  3. Inside the container, run:       claude"
echo ""
if command -v clip.exe &> /dev/null; then
    if echo -n "${NEXT_CMD}" | clip.exe 2>/dev/null; then
        info "Step 1 command copied to clipboard — just paste in your shell."
    fi
fi
info "Full log saved to: ${LOG_FILE}"
echo ""
