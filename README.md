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
- A **read-only deploy key** scoped to the dotfiles repo — auto-generated, walked through GitHub upload

When done you'll have `~/<dir>/dotfiles/` (read-only on this machine) and `~/<dir>/project-bootstrap/` cloned anon (it's public), plus the symlink that makes Claude Code load this project's synced memory from the dotfiles repo.

**Security model:** the deploy key (`~/.ssh/dotfiles_ed25519`) is scoped to just the dotfiles repo and is read-only — no broad account access, no write access to anything. Same principle as `init.sh`'s per-project deploy keys. If you want to edit + push dotfiles from this machine, do it from a primary machine that has push auth set up separately (VS Code OAuth, a write deploy key, etc).
