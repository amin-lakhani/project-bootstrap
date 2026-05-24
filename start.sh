#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Project Bootstrap — kickoff wrapper
# Prompts for a project name, opens github.com/new with the name pre-filled,
# then creates the local folder and hands off to init.sh.
#
# Run anywhere (no edits needed):
#   curl -fsSL https://raw.githubusercontent.com/amin-lakhani/project-bootstrap/main/start.sh | bash
# ============================================================================

BOOTSTRAP_RAW="https://raw.githubusercontent.com/amin-lakhani/project-bootstrap/main"

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

# ----- Step 1: prompt for project name --------------------------------------
step "New project"
echo ""
prompt "Project name (lowercase, dashes ok — e.g. my-cool-thing):"
read -r project_name < /dev/tty

# Trim whitespace
project_name="${project_name## }"
project_name="${project_name%% }"

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
