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
if [[ ! "$project_name" =~ ^[a-z0-9._-]+$ ]]; then
    error "Project name must be lowercase letters, digits, dots, dashes, underscores only."
    error "(GitHub allows uppercase but lowercase keeps URLs and paths predictable.)"
    exit 1
fi
if [[ -e "$project_name" ]]; then
    error "'$project_name' already exists in $(pwd)."
    exit 1
fi

# ----- Step 2: create local folder (so user can drop files into it now) -----
step "Create local folder"
mkdir "$project_name"
PROJECT_DIR="$(pwd)/${project_name}"
success "Created: ${PROJECT_DIR}"

# ----- Step 3: open GitHub new-repo page with name pre-filled ---------------
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
info "Heads up: while you're doing that, you can also drop any starter"
info "files into ${PROJECT_DIR}/ — init.sh will commit + push them at the end."
echo ""
prompt "Press Enter once the repo exists on GitHub..."
read -r _ < /dev/tty || true

# ----- Step 4: hand off to init.sh ------------------------------------------
step "Bootstrap local project"
cd "$project_name"
info "Running init.sh in $(pwd)..."
echo ""
curl -fsSL "${BOOTSTRAP_RAW}/init.sh" | bash
