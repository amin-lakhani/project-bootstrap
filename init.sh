#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Project Bootstrap — per-project setup
# Run from inside an empty new project folder.
# ============================================================================

BOOTSTRAP_RAW="https://raw.githubusercontent.com/amin-lakhani/project-bootstrap/main"
DOTFILES_REPO="https://github.com/amin-lakhani/dotfiles.git"
GIT_NAME="Amin Lakhani"
GIT_EMAIL="85595676+amin-lakhani@users.noreply.github.com"

info()    { echo -e "\033[36m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[OK]\033[0m $1"; }
warn()    { echo -e "\033[33m[WARN]\033[0m $1"; }
error()   { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
step()    { echo ""; echo -e "\033[35m=== $1 ===\033[0m"; }

# Try several browser-opener tools. On WSL without wslview/xdg-open,
# falls back to cmd.exe which is always present via WSL interop.
open_url() {
    local url="$1"
    if command -v wslview &> /dev/null; then
        wslview "$url" 2>/dev/null && return 0
    fi
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" 2>/dev/null && return 0
    fi
    if command -v cmd.exe &> /dev/null; then
        # cd to /mnt/c so cmd.exe has a valid Windows cwd (silences UNC warning)
        (cd /mnt/c && cmd.exe /c start "" "$url") 2>/dev/null && return 0
    fi
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
if [[ ! -d "${HOME}/.dotfiles" ]]; then
    read -p "Dotfiles not found at ~/.dotfiles. Clone and install now? [Y/n] " -n 1 -r < /dev/tty
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        git clone "$DOTFILES_REPO" "${HOME}/.dotfiles"
        bash "${HOME}/.dotfiles/install.sh"
    fi
else
    success "Dotfiles already installed"
fi

# ----------------------------------------------------------------------------
# Step 5: Global git config
# ----------------------------------------------------------------------------
step "5/14: Configuring global git"
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main

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
echo "Paste the GitHub URL of your new (empty) repo."
echo "Accepted formats:"
echo "  https://github.com/user/repo"
echo "  https://github.com/user/repo.git"
echo "  git@github.com:user/repo.git"
read -p "URL: " REPO_URL < /dev/tty

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
echo ""
echo "============================================================"
echo "  PUBLIC KEY (copy this entire line):"
echo "============================================================"
cat "${KEY_PATH}.pub"
echo "============================================================"
echo ""
DEPLOY_KEYS_URL="https://github.com/${REPO_USER}/${REPO_NAME}/settings/keys/new"
REPO_PAGE_URL="https://github.com/${REPO_USER}/${REPO_NAME}"
echo "While you're on github.com, do BOTH of these:"
echo ""
echo "  1. Add the deploy key:"
echo "     ${DEPLOY_KEYS_URL}"
echo "     - Paste the key above"
echo "     - CHECK the 'Allow write access' box"
echo "     - Click 'Add key'"
echo ""
echo "  2. Upload any initial files for this project:"
echo "     ${REPO_PAGE_URL}"
echo "     - Drag and drop files into the repo"
echo "     - Commit them via the web UI"
echo ""

if open_url "$DEPLOY_KEYS_URL"; then
    info "Opened deploy keys page in your browser."
else
    warn "Could not auto-open browser — copy the URL above manually."
fi

read -p "Press Enter once BOTH the deploy key is added AND any initial files are uploaded... " < /dev/tty

# ----------------------------------------------------------------------------
# Step 12: Test SSH
# ----------------------------------------------------------------------------
step "12/14: Testing SSH connection"
SSH_TEST=$(ssh -T -o StrictHostKeyChecking=accept-new "git@${SSH_HOST_ALIAS}" < /dev/null 2>&1 || true)
echo "$SSH_TEST"
if echo "$SSH_TEST" | grep -q "successfully authenticated"; then
    success "SSH connection works"
else
    warn "SSH did not authenticate. Most common cause: deploy key not added on GitHub, or 'Allow write access' wasn't checked."
    read -p "Continue anyway? [y/N] " -n 1 -r < /dev/tty
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
# Step 14: Pull repo contents (any files Amin uploaded)
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
echo "Next steps:"
echo "  1. Open this folder in VS Code:    code ."
echo "  2. Command palette → 'Dev Containers: Reopen in Container'"
echo "  3. Inside the container, run:      claude"
echo ""
