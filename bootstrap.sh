#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# bootstrap.sh — single entry point for the project-bootstrap-template system
#
# Run anywhere:
#   curl -fsSL https://raw.githubusercontent.com/<gh-user>/project-bootstrap-template/main/bootstrap.sh | bash
# (The README has a copy-pasteable snippet that resolves <gh-user> automatically.)
#
# What it does, depending on state:
#   - Fresh machine: walks you through identity setup + dotfiles (clone existing
#     OR create a new private dotfiles-<your-username> from dotfiles-template)
#   - Inside an empty project folder: per-project setup (deploy key + git
#     wiring + dev tooling install)
#   - Anywhere else: menu
#
# Identity resolution (same flow as before): env vars > cache > detect > prompt.
# Email is always derived as the GitHub noreply form — never prompted.
# ============================================================================

# ----- Constants ------------------------------------------------------------
DOTFILES_TEMPLATE_OWNER="${DOTFILES_TEMPLATE_OWNER:-amin-lakhani}"
DOTFILES_TEMPLATE_NAME="${DOTFILES_TEMPLATE_NAME:-dotfiles-template}"
DEFAULT_WORK_DIR="${BOOTSTRAP_WORK_DIR:-dev_env_setup}"
# Default base under $HOME for new per-project setups. Override via env var.
DEFAULT_CODE_DIR="${BOOTSTRAP_CODE_DIR:-${HOME}/dev_code}"

# ----- ANSI colors ----------------------------------------------------------
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
BLUE='\033[34m'; MAGENTA='\033[35m'; GRAY='\033[90m'; BOLD='\033[1m'; NC='\033[0m'

# ----- Logging --------------------------------------------------------------
LOG_DIR="${HOME}/.cache/project-bootstrap"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/bootstrap-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()      { date +%H:%M:%S; }
info()    { echo -e "${GRAY}[$(ts)]${NC} ${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GRAY}[$(ts)]${NC} ${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${GRAY}[$(ts)]${NC} ${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${GRAY}[$(ts)]${NC} ${RED}[ERROR]${NC} $1"; }
prompt()  { echo -e "${GRAY}[$(ts)]${NC} ${BLUE}[?]${NC} $1"; }
step()    { echo ""; echo -e "${GRAY}[$(ts)]${NC} ${MAGENTA}=== $1 ===${NC}"; }
debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${GRAY}[$(ts)] [DEBUG]${NC} $1" || true; }

on_err() {
    local exit_code=$?
    local line=$1
    local cmd=$2
    echo ""
    error "FATAL at line ${line}: command \`${cmd}\` exited ${exit_code}"
    error "Full log: ${LOG_FILE}"
    exit "$exit_code"
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

info "Log file: ${LOG_FILE}"
debug "DEBUG=1 — verbose tracing enabled"
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ----- Browser opener -------------------------------------------------------
open_url() {
    local url="$1"
    if command -v cmd.exe &> /dev/null; then
        (cd /mnt/c && nohup cmd.exe /c start "" "$url" < /dev/null > /dev/null 2>&1 &) 2>/dev/null
        sleep 1
        return 0
    fi
    command -v wslview &> /dev/null && wslview "$url" < /dev/null > /dev/null 2>&1 && return 0
    command -v code &> /dev/null && code --openExternal "$url" 2>/dev/null && return 0
    command -v xdg-open &> /dev/null && xdg-open "$url" &> /dev/null & return 0
    command -v open &> /dev/null && open "$url" &> /dev/null & return 0
    return 1
}

# ----- Clipboard ------------------------------------------------------------
CLIP_STATUS="none"
clip_copy() {
    local content="$1"
    CLIP_STATUS="none"
    for tool in clip.exe pbcopy wl-copy; do
        if command -v "$tool" &> /dev/null; then
            if printf '%s' "$content" | "$tool" 2>/dev/null; then
                CLIP_STATUS="ok"; return 0
            fi
        fi
    done
    if command -v xclip &> /dev/null; then
        if printf '%s' "$content" | xclip -selection clipboard 2>/dev/null; then
            CLIP_STATUS="ok"; return 0
        fi
    fi
    # OSC52 terminal escape fallback
    local b64
    b64="$(printf '%s' "$content" | base64 -w0 2>/dev/null || printf '%s' "$content" | base64 | tr -d '\n')" || b64=""
    [[ -n "$b64" ]] && { printf '\033]52;c;%s\007' "$b64"; CLIP_STATUS="osc52"; }
    return 0
}

copy_and_report() {
    local label="$1" value="$2"
    clip_copy "$value"
    case "$CLIP_STATUS" in
        ok)    success "${label} copied to clipboard." ;;
        osc52) warn "${label} sent via OSC52 — your terminal may or may not honor it." ;;
        *)     warn "Couldn't reach any clipboard tool — copy the ${label,,} from the box above manually." ;;
    esac
}

boxed_print() {
    local label="$1" body="$2"
    echo ""
    echo "  ┌─[${label}]──────────────────────────────────────────"
    while IFS= read -r line; do echo "  │ ${line}"; done <<< "$body"
    echo "  └────────────────────────────────────────────────────"
    echo ""
}

# ============================================================================
# IDENTITY
# ============================================================================
IDENTITY_CACHE="${XDG_CONFIG_HOME:-${HOME}/.config}/project-bootstrap/user.env"

fetch_github_user_id() {
    local gh_user="$1" response
    response="$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/users/${gh_user}" 2>/dev/null || true)"
    [[ -z "$response" ]] && return 1
    local id
    id="$(printf '%s' "$response" | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+')"
    [[ -z "$id" ]] && return 1
    printf '%s' "$id"
}

detect_github_username() {
    if command -v gh &>/dev/null; then
        local u
        u="$(gh api user 2>/dev/null | grep -oE '"login":[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"login":[[:space:]]*"([^"]+)".*/\1/')"
        [[ -n "$u" ]] && { printf '%s' "$u"; return 0; }
    fi
    local email
    email="$(git config --global --get user.email 2>/dev/null || true)"
    if [[ "$email" =~ ^[0-9]+\+([a-zA-Z0-9-]+)@users\.noreply\.github\.com$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"; return 0
    fi
    return 1
}

detect_git_author_name() {
    if command -v gh &>/dev/null; then
        local n
        n="$(gh api user 2>/dev/null | grep -oE '"name":[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"name":[[:space:]]*"([^"]+)".*/\1/')"
        [[ -n "$n" && "$n" != "null" ]] && { printf '%s' "$n"; return 0; }
    fi
    local name
    name="$(git config --global --get user.name 2>/dev/null || true)"
    [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
    return 1
}

update_cache_field() {
    local name="$1" value="$2"
    mkdir -p "$(dirname "$IDENTITY_CACHE")"
    touch "$IDENTITY_CACHE"
    chmod 600 "$IDENTITY_CACHE"
    grep -q "^${name}=" "$IDENTITY_CACHE" 2>/dev/null && sed -i "/^${name}=/d" "$IDENTITY_CACHE"
    echo "${name}='${value}'" >> "$IDENTITY_CACHE"
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

    # Username: detect-and-confirm
    if [[ -z "$GH_USER" ]]; then
        local detected
        detected="$(detect_github_username || true)"
        if [[ -n "$detected" ]]; then
            prompt "GitHub username [Enter for ${detected}]:"
            read -r GH_USER < /dev/tty
            GH_USER="${GH_USER:-$detected}"
        else
            prompt "GitHub username:"
            read -r GH_USER < /dev/tty
        fi
    fi

    # Numeric ID: auto-fetch from GitHub API; prompt only on failure
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

    # Name: detect-and-confirm
    if [[ -z "$GIT_NAME" ]]; then
        local detected
        detected="$(detect_git_author_name || true)"
        if [[ -n "$detected" ]]; then
            prompt "Git author name [Enter for ${detected}]:"
            read -r GIT_NAME < /dev/tty
            GIT_NAME="${GIT_NAME:-$detected}"
        else
            prompt "Git author name (e.g. 'Jane Doe'):"
            read -r GIT_NAME < /dev/tty
        fi
    fi

    # Email: always noreply form, never prompted
    [[ -z "$GIT_EMAIL" ]] && GIT_EMAIL="${GH_USER_ID}+${GH_USER}@users.noreply.github.com"
    if [[ "$GIT_EMAIL" != *"@users.noreply.github.com" ]]; then
        warn "GIT_EMAIL is '${GIT_EMAIL}' — NOT a noreply address. Public commits will leak it."
        warn "Clear BOOTSTRAP_GIT_EMAIL + delete ${IDENTITY_CACHE} to fall back to noreply."
    fi

    for var in GH_USER GH_USER_ID GIT_NAME GIT_EMAIL; do
        if [[ -z "${!var}" ]]; then error "Identity field ${var} empty — aborting."; exit 1; fi
    done

    # Persist (preserve CACHED_DOTFILES_PATH if previously set)
    {
        echo "# Cached by project-bootstrap. Override with BOOTSTRAP_* env vars."
        echo "CACHED_GH_USER='${GH_USER}'"
        echo "CACHED_GH_USER_ID='${GH_USER_ID}'"
        echo "CACHED_GIT_NAME='${GIT_NAME}'"
        echo "CACHED_GIT_EMAIL='${GIT_EMAIL}'"
        [[ -n "${CACHED_DOTFILES_PATH:-}" ]] && echo "CACHED_DOTFILES_PATH='${CACHED_DOTFILES_PATH}'"
    } > "$IDENTITY_CACHE"
    chmod 600 "$IDENTITY_CACHE"

    # Per-user dotfiles repo name default
    DOTFILES_REPO_NAME="${DOTFILES_REPO_NAME:-dotfiles-${GH_USER}}"

    info "Identity: ${GIT_NAME} <${GIT_EMAIL}> (GitHub: ${GH_USER})"
    info "Dotfiles repo: ${GH_USER}/${DOTFILES_REPO_NAME}"
}

# ============================================================================
# GH AUTH (with always-wipe cleanup trap)
# ============================================================================
GH_AUTH_ACTIVE=0  # set to 1 if we want cleanup at exit

cleanup_gh_auth() {
    (( GH_AUTH_ACTIVE == 0 )) && return 0
    local revoke_url="https://github.com/settings/applications"
    gh auth logout --hostname github.com 2>/dev/null || true
    open_url "$revoke_url" || true
    echo ""
    echo -e "${RED}${BOLD}============================================================${NC}"
    echo -e "${RED}${BOLD}  REVOKE THE GITHUB CLI OAUTH GRANT — DO THIS NOW${NC}"
    echo -e "${RED}${BOLD}============================================================${NC}"
    echo -e "${RED}  Local gh credential removed. The OAuth grant on GitHub is${NC}"
    echo -e "${RED}  still active with broad scopes (repo, workflow, etc.).${NC}"
    echo -e "${RED}  Until you revoke it, anyone who captured the token in transit${NC}"
    echo -e "${RED}  can use it.${NC}"
    echo ""
    echo -e "${RED}  Browser is opening:  ${BOLD}${revoke_url}${NC}"
    echo -e "${RED}  Find ${BOLD}'GitHub CLI'${NC}${RED} → Revoke.${NC}"
    echo -e "${RED}${BOLD}============================================================${NC}"
    echo ""
}
trap cleanup_gh_auth EXIT

# Returns 0 if gh is usable (installed + authenticated) for the script's
# auth-requiring ops. If gh is installed but not authed, prompts to log in.
# Sets GH_AUTH_ACTIVE=1 if a credential is in place — the EXIT trap will
# wipe it regardless of who set it up.
ensure_gh_auth() {
    if ! command -v gh &>/dev/null; then
        return 1
    fi

    if gh auth status &>/dev/null; then
        warn "Pre-existing gh CLI auth detected on this machine."
        warn "It will be WIPED when this script exits (whether pre-existing or just logged in)."
        warn "Ctrl-C now if you want to keep it; otherwise continuing in 3s..."
        sleep 3
        GH_AUTH_ACTIVE=1
        return 0
    fi

    info "Logging in to GitHub via gh CLI for repo creation + deploy-key registration."
    info "The local credential will be REMOVED from this machine when the script exits."
    info "(The OAuth grant on GitHub itself you'll need to revoke manually — script will open the page at the end.)"
    if ! gh auth login --hostname github.com --git-protocol https; then
        warn "gh auth login failed or was cancelled. Falling back to browser flow."
        return 1
    fi
    GH_AUTH_ACTIVE=1
    return 0
}

# ============================================================================
# DOTFILES
# ============================================================================
update_dotfiles_checkout() {
    local path="$1"
    info "Pulling latest from origin for ${path}..."
    if git -C "$path" pull --ff-only --quiet 2>&1; then
        success "Dotfiles up to date."
    else
        warn "Couldn't fast-forward (network down, local changes, or remote divergence)."
        warn "Continuing with the current local copy."
    fi
}

test_dotfiles_ssh() {
    local alias="$1" output
    output="$(timeout 15 ssh -T \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        "git@${alias}" < /dev/null 2>&1 || true)"
    debug "test_dotfiles_ssh output: ${output}"
    echo "$output" | grep -qiE "successfully authenticated|deploy key|does not provide shell access"
}

# Generate SSH key + add ~/.ssh/config alias + (if gh) auto-register deploy
# key, else walk user through registering it on the GitHub UI. Returns 0 if
# SSH access works at the end.
setup_dotfiles_ssh_key() {
    local repo_full="$1"   # e.g. amin-lakhani/dotfiles-amin-lakhani
    local alias="${2:-github.com-${DOTFILES_REPO_NAME}}"
    local key_path="${HOME}/.ssh/${DOTFILES_REPO_NAME}_ed25519"

    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    if [[ ! -f "$key_path" ]]; then
        ssh-keygen -t ed25519 \
            -C "${GIT_EMAIL} (${repo_full} read-only deploy key)" \
            -f "$key_path" -N ""
        success "Generated SSH key at ${key_path}"
    else
        info "Using existing SSH key at ${key_path}"
    fi

    local ssh_config="${HOME}/.ssh/config"
    touch "$ssh_config"
    chmod 600 "$ssh_config"
    if ! grep -q "^Host ${alias}$" "$ssh_config"; then
        {
            echo ""
            echo "# Added by bootstrap.sh — deploy key for ${repo_full}"
            echo "Host ${alias}"
            echo "    HostName github.com"
            echo "    User git"
            echo "    IdentityFile ~/.ssh/${DOTFILES_REPO_NAME}_ed25519"
            echo "    IdentitiesOnly yes"
        } >> "$ssh_config"
        success "Added SSH config alias '${alias}'"
    fi

    # If SSH already works, we're done
    if test_dotfiles_ssh "$alias"; then
        success "SSH access to ${repo_full} already works."
        return 0
    fi

    # Try to register via gh
    if (( GH_AUTH_ACTIVE == 1 )); then
        info "Registering deploy key on ${repo_full} via gh CLI..."
        local title="$(hostname) - $(date +%Y-%m-%d) - bootstrap"
        if gh repo deploy-key add "${key_path}.pub" --repo "$repo_full" --title "$title" 2>&1; then
            success "Deploy key registered."
            sleep 3   # let GitHub propagate
            if test_dotfiles_ssh "$alias"; then
                success "SSH access confirmed."
                return 0
            fi
            warn "Deploy key registered but SSH test still failing — GitHub may need more time to propagate."
        else
            warn "gh repo deploy-key add failed; falling back to browser flow."
        fi
    fi

    # Browser-walk fallback
    local pubkey="$(cat "${key_path}.pub")"
    local key_title="$(hostname) - $(date +%Y-%m-%d) - bootstrap"
    local keys_url="https://github.com/${repo_full}/settings/keys/new"
    info "Deploy key page: ${keys_url}"
    open_url "$keys_url" || true

    boxed_print "TITLE" "${key_title}"
    copy_and_report "Title" "$key_title"
    sleep 1
    boxed_print "PUBLIC KEY" "${pubkey}"
    copy_and_report "Public key" "$pubkey"

    echo ""
    info "On ${keys_url} (title + key are in clipboard history):"
    echo "  1. Paste TITLE → 'Title' field"
    echo "  2. Paste PUBLIC KEY → 'Key' field"
    echo "  3. Leave 'Allow write access' UNCHECKED (read-only)"
    echo "  4. Click 'Add key'"
    echo ""

    local attempt
    for attempt in 1 2 3; do
        echo ""
        local reply=""
        read -r -p "Press Enter once deploy key is added (or 'q' to skip dotfiles): " reply < /dev/tty || reply="q"
        if [[ "$reply" == "q" || "$reply" == "Q" ]]; then
            warn "User skipped deploy key setup."
            return 1
        fi
        info "Testing SSH (attempt ${attempt}/3)..."
        if test_dotfiles_ssh "$alias"; then
            success "SSH access confirmed."
            return 0
        fi
        warn "Still not authenticating. Common causes: key not added, GitHub propagation lag, or port-22 blocked."
    done

    error "Gave up after 3 attempts."
    return 1
}

# Clone an existing user's dotfiles repo (private, needs SSH deploy key).
# Returns 0 on success, with DOTFILES_PATH set to the local checkout.
ensure_dotfiles_clone_existing() {
    local target="$1"   # local dest dir, e.g. ~/dev_env_setup/dotfiles-jane-doe
    local repo_full="${GH_USER}/${DOTFILES_REPO_NAME}"
    local alias="github.com-${DOTFILES_REPO_NAME}"
    local ssh_url="git@${alias}:${repo_full}.git"

    if [[ -d "${target}/.git" ]]; then
        success "Already cloned at ${target}"
        return 0
    fi

    if ! setup_dotfiles_ssh_key "$repo_full" "$alias"; then
        warn "Could not enable SSH access to ${repo_full}."
        return 1
    fi

    info "Cloning ${repo_full} via SSH alias..."
    git clone "$ssh_url" "$target"
    success "Cloned to ${target}"
    return 0
}

# Create a new private dotfiles-<user> repo from the dotfiles-template,
# then clone it. Requires gh (with auth) or a browser walk-through.
ensure_dotfiles_from_template() {
    local target="$1"
    local repo_full="${GH_USER}/${DOTFILES_REPO_NAME}"
    local template_full="${DOTFILES_TEMPLATE_OWNER}/${DOTFILES_TEMPLATE_NAME}"

    if [[ -d "${target}/.git" ]]; then
        success "Already cloned at ${target}"
        return 0
    fi

    # Step 1: create the repo from template
    if (( GH_AUTH_ACTIVE == 1 )); then
        info "Creating ${repo_full} from template ${template_full} via gh..."
        if gh repo create "$repo_full" --private --template "$template_full" 2>&1; then
            success "Repo created."
        else
            warn "gh repo create failed (does ${repo_full} already exist?). Trying browser flow."
        fi
    fi

    # Verify the repo exists before proceeding (handles both gh-success and pre-existing cases)
    local check_url="https://github.com/${repo_full}"

    # If still not there, walk through browser
    if ! curl -fsI "$check_url" &>/dev/null; then
        local generate_url="https://github.com/${template_full}/generate?owner=${GH_USER}&name=${DOTFILES_REPO_NAME}&visibility=private"
        echo ""
        warn "Open this URL to create ${repo_full} from the template:"
        boxed_print "URL" "$generate_url"
        open_url "$generate_url" || true
        echo "  Settings on the page:"
        echo "    Owner:      ${GH_USER}"
        echo "    Repository: ${DOTFILES_REPO_NAME}"
        echo "    Visibility: ${BOLD}Private${NC}"
        echo "    Include all branches: leave unchecked"
        echo ""
        read -r -p "Press Enter once you've clicked 'Create repository from template': " _ < /dev/tty || true
    fi

    # Step 2: deploy key + clone
    if ! setup_dotfiles_ssh_key "$repo_full" "github.com-${DOTFILES_REPO_NAME}"; then
        warn "Could not enable SSH access to ${repo_full}."
        return 1
    fi

    info "Cloning ${repo_full} via SSH alias..."
    git clone "git@github.com-${DOTFILES_REPO_NAME}:${repo_full}.git" "$target"
    success "Cloned to ${target}"
    return 0
}

# Wraps everything — figure out where dotfiles should live + install it.
setup_dotfiles() {
    step "Dotfiles setup"

    # Already on disk?
    DOTFILES_PATH=""
    # If the cache points somewhere that no longer exists (workdir renamed,
    # checkout deleted), say so loudly before falling through — silent
    # fallthrough is the bug class that "no other machine has /dev" cleanup
    # was meant to prevent.
    if [[ -n "${CACHED_DOTFILES_PATH:-}" && ! -d "${CACHED_DOTFILES_PATH}/.git" ]]; then
        warn "CACHED_DOTFILES_PATH='${CACHED_DOTFILES_PATH}' no longer has a checkout (renamed or deleted). Re-discovering and updating the cache."
    fi
    if [[ -n "${CACHED_DOTFILES_PATH:-}" && -d "${CACHED_DOTFILES_PATH}/.git" ]]; then
        DOTFILES_PATH="$CACHED_DOTFILES_PATH"
        success "Dotfiles already at ${DOTFILES_PATH} (from cache)"
        update_dotfiles_checkout "$DOTFILES_PATH"
    elif [[ -d "${HOME}/.dotfiles/.git" ]]; then
        DOTFILES_PATH="${HOME}/.dotfiles"
        success "Dotfiles already at ${DOTFILES_PATH}"
        update_dotfiles_checkout "$DOTFILES_PATH"
    else
        # Need to set up — prompt
        local work_dir="${HOME}/${DEFAULT_WORK_DIR}"
        # Use existing workdir if present (don't surprise the user with a new one)
        for candidate in "${HOME}/${DEFAULT_WORK_DIR}" "${HOME}/development"; do
            if [[ -d "$candidate" ]]; then work_dir="$candidate"; break; fi
        done
        mkdir -p "$work_dir"
        local target="${work_dir}/${DOTFILES_REPO_NAME}"

        echo ""
        info "No dotfiles checkout found on this machine."
        echo "  Does a dotfiles repo already exist on GitHub under your account?"
        echo "    [1] Yes — clone ${GH_USER}/${DOTFILES_REPO_NAME} onto this machine  (default; use this on every new machine after the first)"
        echo "    [2] No  — create ${GH_USER}/${DOTFILES_REPO_NAME} from the template ${DOTFILES_TEMPLATE_OWNER}/${DOTFILES_TEMPLATE_NAME}  (one-time, the very first time you ever run bootstrap)"
        echo "    [s] Skip dotfiles entirely on this machine"
        prompt "Choice [1]: "
        local choice=""
        read -r choice < /dev/tty || choice=""
        choice="${choice:-1}"

        case "${choice,,}" in
            1)
                # gh auth lets us register the deploy key without the browser walk
                ensure_gh_auth || true
                if ensure_dotfiles_clone_existing "$target"; then
                    DOTFILES_PATH="$target"
                fi
                ;;
            2)
                ensure_gh_auth || true
                if ensure_dotfiles_from_template "$target"; then
                    DOTFILES_PATH="$target"
                fi
                ;;
            s)
                warn "Skipping dotfiles setup."
                ;;
            *)
                error "Unknown choice. Aborting dotfiles step."
                ;;
        esac
    fi

    if [[ -n "$DOTFILES_PATH" ]]; then
        info "Running ${DOTFILES_PATH}/install.sh"
        bash "${DOTFILES_PATH}/install.sh"
        update_cache_field "CACHED_DOTFILES_PATH" "$DOTFILES_PATH"
        wire_claude_memory_symlink "$DOTFILES_PATH"
    fi
}

# Create the symlink Claude Code uses to pick up the synced memory files.
# Claude reads memory from ~/.claude/projects/<hashed-workdir>/memory/ where
# the hash is the absolute workdir path with `/` AND `_` both mapped to `-`
# (verified empirically — Claude Code normalizes underscores too, so a workdir
# like ~/dev_env_setup encodes to -home-<user>-dev-env-setup, not
# -home-<user>-dev_env_setup). The dotfiles repo carries the memory files in
# claude-memory-bootstrap/; this symlink wires them together so a fresh
# machine sees the synced memories on first claude-code run.
wire_claude_memory_symlink() {
    local dotfiles_path="$1"
    local memory_src="${dotfiles_path}/claude-memory-bootstrap"
    if [[ ! -d "$memory_src" ]]; then
        debug "No claude-memory-bootstrap/ dir in ${dotfiles_path} — skipping memory symlink"
        return 0
    fi
    # workdir is dotfiles' parent (e.g. ~/dev_env_setup for ~/dev_env_setup/dotfiles-amin-lakhani)
    local workdir
    workdir="$(dirname "$dotfiles_path")"
    local hash
    hash="$(echo "$workdir" | sed 's|/|-|g; s|_|-|g')"
    local claude_dir="${HOME}/.claude/projects/${hash}"
    local memory_link="${claude_dir}/memory"
    mkdir -p "$claude_dir"
    if [[ -L "$memory_link" ]]; then
        local current
        current="$(readlink -f "$memory_link" 2>/dev/null || true)"
        if [[ "$current" == "$memory_src" ]]; then
            info "Claude memory symlink already correct — skipping"
            return 0
        fi
        info "Refreshing Claude memory symlink target"
        rm "$memory_link"
    elif [[ -e "$memory_link" ]]; then
        local backup="${memory_link}.backup.$(date +%Y%m%d%H%M%S)"
        warn "Existing ${memory_link} is not a symlink — backing up to ${backup}"
        mv "$memory_link" "$backup"
    fi
    ln -s "$memory_src" "$memory_link"
    success "Claude memory: ${memory_link} → ${memory_src}"
}

# ============================================================================
# PER-PROJECT SETUP (formerly init.sh)
# ============================================================================

# Asks the user for a project folder name and resolves where it should live.
# Default location is ${DEFAULT_CODE_DIR}/<name>. User can press Enter to
# accept, or type an alternative absolute path (with `~` allowed). If the
# target doesn't exist it's mkdir -p'd; existing dirs without `.git` are
# accepted (lets you layer bootstrap on top of a pre-populated folder).
# Sets PROJECT_PATH for the caller.
#
# Returns 0 on success (PROJECT_PATH set); 1 on user cancel / bad input
# (PROJECT_PATH cleared).
#
# IMPORTANT: this helper returns 1 on validation failure. ONLY call it
# from a tested context (`if prompt_for_project_location; then ...`) —
# bash suppresses the ERR trap for conditional returns. Calling it
# unconditionally would let `set -euo pipefail` exit the whole script
# on the first validation failure.
PROJECT_PATH=""
prompt_for_project_location() {
    PROJECT_PATH=""
    local pname="" input="" target=""

    while :; do
        prompt "Project folder name (lowercase, e.g. 'my-thing'):"
        read -r pname < /dev/tty || return 1
        pname="${pname#"${pname%%[![:space:]]*}"}"
        pname="${pname%"${pname##*[![:space:]]}"}"
        if [[ -z "$pname" ]]; then
            warn "Name can't be empty. Try again or Ctrl-C to bail."
            continue
        fi
        if [[ ! "$pname" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
            warn "Use lowercase alphanumerics and . _ - (must start with alnum). Try again."
            continue
        fi
        if [[ "$pname" == "$DOTFILES_REPO_NAME" ]]; then
            warn "Name '${pname}' would collide with the dotfiles deploy key. Pick something else."
            continue
        fi
        break
    done

    local default_path="${DEFAULT_CODE_DIR}/${pname}"
    info "Default location: ${default_path}"
    prompt "Press Enter to accept, or type an alternative ABSOLUTE path (~ is allowed):"
    read -r input < /dev/tty || return 1
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    target="${input:-$default_path}"
    # Expand leading ~ ourselves (read doesn't do shell expansion)
    target="${target/#\~/$HOME}"
    # Strip trailing slash so $HOME/ compares equal to $HOME for the guard below
    target="${target%/}"

    if [[ "$target" != /* ]]; then
        error "Path must be absolute (start with / or ~). Got: '${input}'"
        return 1
    fi
    # Reject targets that would scope project-setup at $HOME or root —
    # `git init` against $HOME is almost never what you want and is a real
    # footgun if you happen to type ~ or / at the prompt.
    if [[ "$target" == "$HOME" || "$target" == "" || "$target" == "/" ]]; then
        error "Target must be a sub-directory, not \$HOME or filesystem root. Got: '${input}' (resolved to '${target:-/}')"
        return 1
    fi
    if [[ -e "$target" && ! -d "$target" ]]; then
        error "Path exists but is not a directory: ${target}"
        return 1
    fi
    if [[ -d "${target}/.git" ]]; then
        error "Path already contains a git repository (${target}/.git). Pick a different folder or run inside it."
        return 1
    fi

    mkdir -p "$target" || { error "Could not create ${target}"; return 1; }
    success "Project folder ready: ${target}"
    PROJECT_PATH="$target"
}

project_setup() {
    local project_name="$(basename "$(pwd)")"
    step "Per-project setup for: ${project_name}"

    if [[ "$project_name" == "$DOTFILES_REPO_NAME" ]]; then
        error "Project name '${project_name}' would collide with dotfiles deploy key. Rename folder."
        return 1
    fi

    # 1. OS + tooling
    step "1/9: System packages + Node + Claude Code"
    sudo apt-get update && sudo apt-get upgrade -y
    if ! sudo bash -c 'command -v node && command -v npm' &> /dev/null; then
        info "Installing Node.js LTS via NodeSource..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -
        sudo apt-get install -y nodejs
    fi
    sudo npm install -g npm@latest
    sudo npm install -g @anthropic-ai/claude-code
    success "Claude Code ready"

    # 2. Configure git (skip if symlinked)
    step "2/9: Global git config"
    if [[ -L "${HOME}/.gitconfig" ]]; then
        info "~/.gitconfig is a symlink (managed by dotfiles) — leaving it alone"
    else
        git config --global user.name "$GIT_NAME"
        git config --global user.email "$GIT_EMAIL"
        git config --global init.defaultBranch main
    fi

    # 3. Project repo URL
    step "3/9: Repository setup"
    local default_repo_url="https://github.com/${GH_USER}/${project_name}"
    echo "Press Enter for ${default_repo_url} or paste a different URL:"
    local repo_url=""
    read -r -p "URL [Enter for ${default_repo_url}]: " repo_url < /dev/tty
    repo_url="${repo_url:-$default_repo_url}"
    local repo_user repo_name
    if [[ "$repo_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
        repo_user="${BASH_REMATCH[1]}"
        repo_name="${BASH_REMATCH[2]}"
    else
        error "Could not parse repo URL"
        return 1
    fi
    info "Repo: ${repo_user}/${repo_name}"

    # 4. Per-project SSH deploy key
    step "4/9: Generate per-project SSH key"
    local key_name="${project_name}_ed25519"
    local key_path="${HOME}/.ssh/${key_name}"
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    if [[ -f "$key_path" ]]; then
        warn "Key already exists at $key_path (reusing)"
    else
        ssh-keygen -t ed25519 -C "${GIT_EMAIL} (${repo_user}/${repo_name})" -f "$key_path" -N ""
        success "Generated key"
    fi

    # 5. SSH config alias
    step "5/9: SSH config alias"
    local ssh_host_alias="github.com-${project_name}"
    local ssh_config="${HOME}/.ssh/config"
    touch "$ssh_config"
    chmod 600 "$ssh_config"
    if ! grep -q "^Host ${ssh_host_alias}$" "$ssh_config"; then
        cat >> "$ssh_config" <<EOF

Host ${ssh_host_alias}
    HostName github.com
    User git
    IdentityFile ~/.ssh/${key_name}
    IdentitiesOnly yes
EOF
        success "Alias added"
    fi

    # 6. Register deploy key (gh if available, else browser walk)
    step "6/9: Register deploy key + upload starter files"
    local deploy_keys_url="https://github.com/${repo_user}/${repo_name}/settings/keys/new"
    local repo_page_url="https://github.com/${repo_user}/${repo_name}"

    # Try to enable the gh fast path. If user already has it or chooses to log in,
    # gh handles deploy-key registration in one command; otherwise we fall back
    # to the browser walk below.
    ensure_gh_auth || true

    if (( GH_AUTH_ACTIVE == 1 )); then
        info "Registering deploy key via gh..."
        local title="$(hostname) - $(date +%Y-%m-%d) - ${project_name}"
        if gh repo deploy-key add "${key_path}.pub" --repo "${repo_user}/${repo_name}" --title "$title" --allow-write 2>&1; then
            success "Deploy key registered (read-write)"
        else
            warn "gh deploy-key add failed; falling back to browser walk."
            GH_AUTH_ACTIVE=0   # so the fallback fires below
        fi
    fi

    if (( GH_AUTH_ACTIVE == 0 )); then
        local pubkey="$(cat "${key_path}.pub")"
        local key_title="$(hostname) - $(date +%Y-%m-%d) - ${project_name}"
        open_url "$deploy_keys_url" || true
        boxed_print "TITLE" "${key_title}"
        copy_and_report "Title" "$key_title"
        sleep 1
        boxed_print "PUBLIC KEY" "${pubkey}"
        copy_and_report "Public key" "$pubkey"
        echo ""
        echo "  1. Add the deploy key at: ${deploy_keys_url}"
        echo "     - Paste title + key, CHECK 'Allow write access', click 'Add key'"
        echo "  2. Upload any starter files at: ${repo_page_url}"
        echo ""
        read -r -p "Press Enter once BOTH steps are done... " _ < /dev/tty || true
    else
        echo ""
        info "If you want to upload starter files now, do it at: ${repo_page_url}"
        read -r -p "Press Enter when ready... " _ < /dev/tty || true
    fi

    # 7. Test SSH
    step "7/9: Test SSH connection"
    local ssh_test
    ssh_test=$(ssh -T -o StrictHostKeyChecking=accept-new "git@${ssh_host_alias}" < /dev/null 2>&1 || true)
    echo "$ssh_test"
    if ! echo "$ssh_test" | grep -q "successfully authenticated"; then
        warn "SSH did not authenticate. Most common cause: deploy key not actually added."
        read -r -p "Continue anyway? [y/N] " -n 1 reply < /dev/tty || reply="N"
        echo
        [[ ! "$reply" =~ ^[Yy]$ ]] && return 1
    fi

    # 8. Init local repo + set remote
    step "8/9: Initialize local git"
    [[ ! -d .git ]] && git init -b main
    local remote_url="git@${ssh_host_alias}:${repo_user}/${repo_name}.git"
    if git remote get-url origin &> /dev/null; then
        git remote set-url origin "$remote_url"
    else
        git remote add origin "$remote_url"
    fi
    success "Remote: ${remote_url}"

    # 9. Pull anything uploaded via web UI
    step "9/9: Pull initial content"
    git fetch origin 2>/dev/null || true
    local default_branch
    default_branch=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo "main")
    if git ls-remote --exit-code --heads origin "$default_branch" &> /dev/null; then
        git pull origin "$default_branch" --allow-unrelated-histories || warn "Pull had issues — check manually"
        success "Pulled from ${default_branch}"
    else
        warn "Remote branch '${default_branch}' not found (repo may still be empty)"
    fi

    echo ""
    success "Project bootstrap complete!"
    echo ""
    local next_cmd="(cd $(pwd) && code .)"
    echo "Next steps:"
    echo "  1. Open in VS Code:               ${next_cmd}"
    echo "  2. In the integrated terminal:    claude"
    echo ""
    if command -v clip.exe &> /dev/null; then
        echo -n "${next_cmd}" | clip.exe 2>/dev/null && info "Step 1 copied to clipboard"
    fi
}

# ============================================================================
# STATE DETECTION + MAIN
# ============================================================================

# Returns one of:
#   "needs-dotfiles"     — no dotfiles checkout anywhere
#   "in-project-folder"  — cwd is an empty project folder (no .git, not workdir root)
#   "ambiguous"          — dotfiles set up, cwd not clearly a project folder
detect_state() {
    local has_dotfiles=0
    if [[ -n "${CACHED_DOTFILES_PATH:-}" && -d "${CACHED_DOTFILES_PATH}/.git" ]]; then has_dotfiles=1; fi
    [[ -d "${HOME}/.dotfiles/.git" ]] && has_dotfiles=1

    if (( has_dotfiles == 0 )); then echo "needs-dotfiles"; return; fi

    # Cwd "looks like" a project folder if: not $HOME, not a workdir, no .git
    local cwd="$(pwd)"
    if [[ "$cwd" == "$HOME" ]]; then echo "ambiguous"; return; fi
    if [[ -d "${cwd}/.git" ]]; then echo "ambiguous"; return; fi
    # If cwd parent is a workdir-like directory (contains other clones)
    local parent="$(dirname "$cwd")"
    if [[ "$parent" == "$HOME" ]]; then
        # ~/<something> — probably the workdir root itself, not a project
        echo "ambiguous"; return
    fi
    echo "in-project-folder"
}

prompt_yn() {
    local q="$1" default="${2:-N}"
    local hint="[y/N]"; [[ "$default" == "Y" ]] && hint="[Y/n]"
    local reply
    read -r -p "$(echo -e "${BLUE}[?]${NC} ${q} ${hint}: ")" reply < /dev/tty || reply=""
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

main() {
    step "project-bootstrap-template :: bootstrap.sh"
    load_or_prompt_identity

    local state
    state="$(detect_state)"
    info "Detected machine state: ${state}"
    info "cwd: $(pwd)"

    case "$state" in
        needs-dotfiles)
            setup_dotfiles
            echo ""
            if prompt_yn "Set up a new project now?" "N"; then
                if prompt_for_project_location; then
                    cd "$PROJECT_PATH"
                    project_setup
                else
                    info "Skipping project setup. Re-run when ready."
                fi
            fi
            ;;
        in-project-folder)
            project_setup
            ;;
        ambiguous)
            echo ""
            echo "  [1] Set up a new project  (you'll be asked for a name + location; default base is ${DEFAULT_CODE_DIR})"
            echo "  [2] Re-install dotfiles   (re-run install.sh after changes)"
            echo "  [q] Quit"
            prompt "Choice: "
            local choice=""
            read -r choice < /dev/tty || choice="q"
            case "$choice" in
                1)
                    if prompt_for_project_location; then
                        cd "$PROJECT_PATH"
                        project_setup
                    fi
                    ;;
                2) setup_dotfiles ;;
                *) info "Quit." ;;
            esac
            ;;
    esac

    info "Full log saved to: ${LOG_FILE}"
}

main "$@"
