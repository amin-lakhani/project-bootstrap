#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Project Bootstrap — kickoff wrapper
# Prompts for a project name, opens github.com/new with the name pre-filled,
# then creates the local folder and hands off to init.sh.
#
# Run anywhere — see README "Starting a new project" for the auto-detecting
# snippet that resolves <YOUR-GH-USER> from gh CLI / gitconfig / prompt
# before fetching this script.
#
# Identity (GitHub user, git name/email) is sourced in this priority order:
#   1. BOOTSTRAP_GH_USER / BOOTSTRAP_GH_USER_ID / BOOTSTRAP_GIT_NAME
#      / BOOTSTRAP_GIT_EMAIL env vars
#   2. Cache file at $XDG_CONFIG_HOME (or ~/.config) /project-bootstrap/user.env
#   3. `git config --global user.{name,email}` (for name/email only)
#   4. Interactive prompt over /dev/tty
# Whatever is resolved is written back to the cache file (and exported so
# init.sh sees it through the curl|bash pipe).
# ============================================================================

# Repo names default to the canonical pair but can be overridden if you forked
# them under different names.
BOOTSTRAP_REPO_NAME="${BOOTSTRAP_REPO_NAME:-project-bootstrap-template}"
DOTFILES_REPO_NAME="${DOTFILES_REPO_NAME:-dotfiles}"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
BLUE='\033[34m'; MAGENTA='\033[35m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
prompt()  { echo -e "${BLUE}[?]${NC} $1"; }
step()    { echo ""; echo -e "${MAGENTA}=== $1 ===${NC}"; }

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
    local id
    id="$(printf '%s' "$response" | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+')"
    [[ -z "$id" ]] && return 1
    printf '%s' "$id"
}

# Detect the user's GitHub username from local signals so we can offer it as
# an Enter-to-accept default. Tries gh CLI then .gitconfig (noreply parse).
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

# Detect the user's preferred git author name. Tries gh CLI then git config.
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
    # look it up. Only prompts if the fetch fails.
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

    # Always derive the noreply email — never prompt. To override, set
    # BOOTSTRAP_GIT_EMAIL explicitly (and accept the warning below).
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

    # Export so init.sh (fetched + piped to bash) inherits these and skips
    # its own prompts.
    export BOOTSTRAP_GH_USER="$GH_USER"
    export BOOTSTRAP_GH_USER_ID="$GH_USER_ID"
    export BOOTSTRAP_GIT_NAME="$GIT_NAME"
    export BOOTSTRAP_GIT_EMAIL="$GIT_EMAIL"

    info "Identity: ${GIT_NAME} <${GIT_EMAIL}> (GitHub: ${GH_USER})"
}

open_url() {
    local url="$1"
    if command -v cmd.exe &> /dev/null; then
        # Background + nohup so cmd.exe's brief tty grab doesn't break
        # the next interactive read on /dev/tty.
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

# ----- Step 0: identity -----------------------------------------------------
step "Identity"
load_or_prompt_identity

# Derived URL.
BOOTSTRAP_RAW="https://raw.githubusercontent.com/${GH_USER}/${BOOTSTRAP_REPO_NAME}/main"
info "Will fetch init.sh from ${BOOTSTRAP_RAW}"

# ----- Step 1: prompt for project name --------------------------------------
step "New project"
echo ""
prompt "Project name (lowercase, dashes ok — e.g. my-cool-thing):"
read -r project_name < /dev/tty

# Trim leading + trailing whitespace (handles multiple spaces, tabs, etc.).
project_name="${project_name#"${project_name%%[![:space:]]*}"}"
project_name="${project_name%"${project_name##*[![:space:]]}"}"

if [[ -z "$project_name" ]]; then
    error "Project name cannot be empty."
    exit 1
fi
# Tight regex (first char must be alnum) so 'rm -rf -- "$project_name"' below
# can never resolve to "." / ".." / "-something".
if [[ ! "$project_name" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    error "Project name must start with a lowercase letter or digit, then only"
    error "lowercase letters, digits, dots, dashes, underscores."
    exit 1
fi
# Reject names that would collide with the read-only dotfiles deploy key.
# init.sh derives the per-project SSH key as `~/.ssh/<project>_ed25519`, so a
# project named `dotfiles` (or whatever DOTFILES_REPO_NAME is) would silently
# "reuse" the read-only dotfiles key and fail later at git push.
if [[ "$project_name" == "$DOTFILES_REPO_NAME" ]]; then
    error "Project name '${project_name}' would collide with the dotfiles deploy key"
    error "at ~/.ssh/${project_name}_ed25519 (read-only). Pick a different name."
    exit 1
fi

# Existing-folder handling: empty → reuse; non-empty → confirm wipe.
NEEDS_MKDIR=1
if [[ -e "$project_name" ]]; then
    if [[ ! -d "$project_name" ]]; then
        error "'$project_name' exists in $(pwd) but isn't a directory. Move it aside and re-run."
        exit 1
    fi
    if [[ -z "$(ls -A "$project_name" 2>/dev/null)" ]]; then
        info "Folder '${project_name}/' already exists and is empty — reusing it."
        NEEDS_MKDIR=0
    else
        warn "Folder '${project_name}/' already exists and is NOT empty:"
        ls -A "$project_name" | head -10 | sed 's/^/    /'
        entry_count=$(ls -A "$project_name" | wc -l)
        if [[ "$entry_count" -gt 10 ]]; then
            echo "    ... and $((entry_count - 10)) more"
        fi
        echo ""
        prompt "To wipe and reuse it, re-type the project name. Anything else aborts."
        read -r confirm < /dev/tty || confirm=""
        if [[ "$confirm" != "$project_name" ]]; then
            error "Name didn't match — aborting. No files changed."
            exit 1
        fi
        info "Wiping ${project_name}/ ..."
        rm -rf -- "$project_name"
        success "Wiped."
        NEEDS_MKDIR=1
    fi
fi

# ----- Step 2: open GitHub new-repo page with name pre-filled ---------------
step "Create the repo on GitHub"
GITHUB_NEW_URL="https://github.com/new?name=${project_name}"

if clip_copy "$project_name"; then
    success "Project name copied to clipboard (backup)."
fi

info "Opening: ${GITHUB_NEW_URL}"
if open_url "$GITHUB_NEW_URL"; then
    success "Browser opened. Repo name should already be filled in."
else
    warn "Couldn't auto-open browser. Visit this URL manually:"
    echo "    ${GITHUB_NEW_URL}"
fi

echo ""
info "On the page:"
echo "  1. Confirm the name is '${project_name}'"
echo "  2. Private or Public — your call"
echo "  3. Do NOT initialize with README, .gitignore, or license"
echo "  4. Click 'Create repository'"
echo ""
info "Tip: upload starter files via GitHub now; init.sh will pull them at the end."
echo ""
prompt "Press Enter once the repo exists on GitHub..."
read -r _ < /dev/tty || true

# ----- Step 3: create local folder (if needed) and hand off to init.sh ------
step "Bootstrap local project"
if [[ "$NEEDS_MKDIR" == "1" ]]; then
    mkdir "$project_name"
fi
cd "$project_name"
success "Working in: $(pwd)"

info "Running init.sh..."
echo ""
curl -fsSL "${BOOTSTRAP_RAW}/init.sh" | bash
