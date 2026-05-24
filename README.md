# project-bootstrap

Per-project dev container and setup script. Run once per new project to get a fresh, isolated environment with Claude Code ready to go.

## Prerequisites

- WSL2 with Ubuntu
- Docker Desktop on Windows
- VS Code with the Dev Containers extension
- An empty GitHub repo created on github.com for the new project

## Use

Replace `my-new-project` once, paste, run:

```bash
PROJECT=my-new-project && mkdir "$PROJECT" && cd "$PROJECT" && curl -fsSL https://raw.githubusercontent.com/amin-lakhani/project-bootstrap/main/init.sh | bash
```

The script will:
1. Update OS + npm + Claude Code
2. Install dotfiles if not already present
3. Drop a `.devcontainer/` into the folder
4. Generate a per-project SSH deploy key
5. Walk you through pasting it on GitHub + uploading any starter files
6. Wire up git and pull down those starter files

Then open the folder in VS Code and "Reopen in Container."
