# project-bootstrap

Per-project dev container and setup script. Run once per new project to get a fresh, isolated environment with Claude Code ready to go.

## Prerequisites

- WSL2 with Ubuntu
- Docker Desktop on Windows
- VS Code with the Dev Containers extension
- An empty GitHub repo created on github.com for the new project

## Use

Paste and run (no edits needed):

```bash
curl -fsSL https://raw.githubusercontent.com/amin-lakhani/project-bootstrap/main/start.sh | bash
```

It will:
1. Ask for the project name
2. Open `github.com/new` with the name pre-filled — click Create
3. Make the local folder and hand off to `init.sh`, which:
   - Updates OS + npm + Claude Code
   - Installs dotfiles if not already present
   - Drops a `.devcontainer/` into the folder
   - Generates a per-project SSH deploy key
   - Walks you through pasting it on GitHub + uploading any starter files
   - Wires up git and pulls down those starter files

Then open the folder in VS Code and "Reopen in Container."

### Skip the wrapper

If you've already created the GitHub repo yourself, you can run `init.sh` directly from inside an empty project folder:

```bash
PROJECT=my-project && mkdir "$PROJECT" && cd "$PROJECT" && curl -fsSL https://raw.githubusercontent.com/amin-lakhani/project-bootstrap/main/init.sh | bash
```

## Working on the bootstrap tools themselves

Fresh machine? One-liner that clones both repos (`dotfiles` + `project-bootstrap`), sets up a user-account SSH key, installs dotfiles, and wires up Claude Code memory sync:

```bash
curl -fsSL https://raw.githubusercontent.com/amin-lakhani/project-bootstrap/main/dev-setup.sh | bash
```

You'll be prompted for:
- Work directory name under `$HOME` (default: `dev`)
- SSH key — auto-generated if missing, then walked through GitHub upload

When done you'll have `~/<dir>/dotfiles/` and `~/<dir>/project-bootstrap/` ready to edit, plus the symlink that makes Claude Code load this project's synced memory from the dotfiles repo.

Note: this is a **user-account** SSH key (`~/.ssh/id_ed25519`), separate from the per-project deploy keys `init.sh` generates for new project repos.
