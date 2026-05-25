# project-bootstrap

Per-project dev container and setup scripts. Two `curl | bash` entry points:

| Script | When to use |
|---|---|
| `start.sh` | Starting a **new project** on a machine that's already set up |
| `dev-setup.sh` | **Fresh machine** — set up the bootstrap tools themselves (clones `dotfiles` + `project-bootstrap`) |

(`init.sh` is what `start.sh` calls under the hood — don't invoke it directly.)

## Prerequisites

- WSL2 with Ubuntu (or any Linux/macOS env for `dev-setup.sh`)
- Docker Desktop (or compatible) for the dev containers `init.sh` produces
- VS Code with the Dev Containers extension
- For `start.sh` / `init.sh`: an empty GitHub repo for the new project

## Identity

On first run the scripts ask for two things:
- **GitHub username** — used for clone URLs and as the GitHub noreply email handle
- **Git author name** — what appears as the author of every commit

If you're already signed into GitHub locally, each prompt is pre-filled with a detected default — press **Enter to accept** or type a different value. Detection sources (in order):
- `gh` CLI (`gh api user`) if it's installed and authenticated
- `~/.gitconfig` — the username is recovered from `user.email` if it's in GitHub's `<id>+<user>@users.noreply.github.com` form; the author name is taken from `user.name` directly

If nothing is detected, the prompt is just blank — type your answer.

Everything else is derived:
- **Numeric GitHub user ID** is fetched from the public GitHub API (`https://api.github.com/users/<your-username>`) so you never have to look it up.
- **Git email** is always derived as `<id>+<user>@users.noreply.github.com` (GitHub's noreply format). This is the whole point: no chance of a real address slipping into a public commit by accident — there's no prompt to mis-type into.

Both confirmed answers are cached at `$XDG_CONFIG_HOME/project-bootstrap/user.env` (defaults to `~/.config/project-bootstrap/user.env`). Subsequent runs are silent.

You can pre-seed any/all of these via environment variables (skips the corresponding prompt or fetch):

| Variable | Example |
|---|---|
| `BOOTSTRAP_GH_USER` | `jane-doe` |
| `BOOTSTRAP_GH_USER_ID` | `12345678` (only needed if offline / API rate-limited) |
| `BOOTSTRAP_GIT_NAME` | `Jane Doe` |
| `BOOTSTRAP_GIT_EMAIL` | `12345678+jane-doe@users.noreply.github.com` |

If you set `BOOTSTRAP_GIT_EMAIL` to anything that isn't a `@users.noreply.github.com` address, the scripts will emit a warning on every run pointing out the public-exposure risk — but won't block you. To get back to the safe noreply default, clear the env var and delete the cache file.

If you forked the bootstrap repos under different names, override these too:

| Variable | Default |
|---|---|
| `BOOTSTRAP_REPO_NAME` | `project-bootstrap` |
| `DOTFILES_REPO_NAME` | `dotfiles` |
| `BOOTSTRAP_WORK_DIR` | `development` (used as default folder name under `$HOME` in `dev-setup.sh`) |

## Starting a new project

Paste and run — the snippet detects your GitHub username from `gh` CLI or your `~/.gitconfig` (the noreply email), and only prompts if neither is set up:

```bash
GH_USER="${BOOTSTRAP_GH_USER:-}"
[ -z "$GH_USER" ] && GH_USER="$(gh api user 2>/dev/null | grep -oE '"login":[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"login":[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$GH_USER" ] && GH_USER="$(git config --global user.email 2>/dev/null | sed -nE 's/^[0-9]+\+(.+)@users\.noreply\.github\.com$/\1/p')"
[ -z "$GH_USER" ] && read -rp "GitHub username: " GH_USER
curl -fsSL "https://raw.githubusercontent.com/${GH_USER}/project-bootstrap/main/start.sh" | bash
```

(Set `BOOTSTRAP_GH_USER=<your-username>` to bypass detection entirely. If you forked this repo, also set `BOOTSTRAP_REPO_NAME` to your fork's name and `start.sh` will fetch the rest of the scripts from your fork.)

It will:
1. Resolve identity (env vars / cache / prompt) and write to the cache
2. Ask for the project name
3. Open `github.com/new` with the name pre-filled — click Create (you can also use the page's "uploading an existing file" link to drop in starter files)
4. Make the local folder and hand off to `init.sh`, which:
   - Updates OS + npm + Claude Code
   - **Installs dotfiles**: reuses an existing checkout (recorded by `dev-setup.sh`, or at `~/.dotfiles`), or clones fresh. **Always `git pull --ff-only`s the latest** from the dotfiles remote before running `install.sh` so each new project picks up the most recent config (safe pull — local edits to the dotfiles repo, if you're iterating on it, are never clobbered; if the pull can't fast-forward, it warns and uses what's on disk). If the dotfiles repo is private and HTTPS clone fails, walks you through generating an SSH deploy key, registering it on GitHub, and retries — same recovery flow as `dev-setup.sh`. If it can't enable access, the rest of the bootstrap still runs without dotfiles.
   - Drops a `.devcontainer/` into the folder
   - Generates a per-project read-write SSH deploy key + walks you through registering it
   - Wires up git and pulls down anything you uploaded via the web UI

Then open the folder in VS Code and "Reopen in Container."

## Setting up a fresh machine

When you want to work on these bootstrap tools themselves on a brand new machine. On a fresh machine you almost certainly don't have `gh` configured or a noreply `~/.gitconfig` yet, so this snippet will prompt for your username — the detection chain is here for symmetry with the new-project snippet:

```bash
GH_USER="${BOOTSTRAP_GH_USER:-}"
[ -z "$GH_USER" ] && GH_USER="$(gh api user 2>/dev/null | grep -oE '"login":[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"login":[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$GH_USER" ] && GH_USER="$(git config --global user.email 2>/dev/null | sed -nE 's/^[0-9]+\+(.+)@users\.noreply\.github\.com$/\1/p')"
[ -z "$GH_USER" ] && read -rp "GitHub username: " GH_USER
curl -fsSL "https://raw.githubusercontent.com/${GH_USER}/project-bootstrap/main/dev-setup.sh" | bash
```

You'll be prompted for:
- Identity (first run only — cached after that; see [Identity](#identity))
- Work directory name under `$HOME` (default: `development`, override with `BOOTSTRAP_WORK_DIR`)
- A **read-only deploy key** scoped to the `dotfiles` repo — auto-generated, with title + pubkey copied to your clipboard (back-to-back, both live in clipboard history) and a browser walk-through. The SSH-auth check loops up to 3 times so you can fix a missing key without re-running the whole script.

When done you'll have:
- `~/<dir>/dotfiles/` — cloned via the deploy key (read-only on this machine), and the path is recorded in the identity cache so `init.sh` finds it on later per-project runs
- `~/<dir>/project-bootstrap/` — cloned anon HTTPS (it's public)
- A symlink wiring Claude Code's memory to the synced files in the dotfiles repo

## Security model

Every credential generated by these scripts is **scoped to a single repo**:

- `dev-setup.sh` → read-only deploy key for `dotfiles` only (`~/.ssh/<dotfiles-repo-name>_ed25519`)
- `init.sh` → per-project read/write deploy key for the new project repo (`~/.ssh/<project>_ed25519`)

No user-account SSH keys, no PATs. Blast radius = one repo per key. If you need to edit + push to `dotfiles` from a secondary machine, do it via a separately-set-up auth path (VS Code OAuth, a per-machine write deploy key, etc.) — `dev-setup.sh` deliberately doesn't grant that.

## Logs

All scripts tee their output to `$HOME/.cache/project-bootstrap/<script>-<timestamp>.log`. Each run prints the log path at start and (on error) end. Set `DEBUG=1` before the snippet to enable `set -x` tracing — just prefix the `curl` line:

```bash
GH_USER="${BOOTSTRAP_GH_USER:-}"
[ -z "$GH_USER" ] && GH_USER="$(gh api user 2>/dev/null | grep -oE '"login":[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"login":[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$GH_USER" ] && GH_USER="$(git config --global user.email 2>/dev/null | sed -nE 's/^[0-9]+\+(.+)@users\.noreply\.github\.com$/\1/p')"
[ -z "$GH_USER" ] && read -rp "GitHub username: " GH_USER
DEBUG=1 curl -fsSL "https://raw.githubusercontent.com/${GH_USER}/project-bootstrap/main/dev-setup.sh" | bash
```

## Files

- `start.sh` — new-project wrapper, prompts for name + opens GitHub `new` page
- `init.sh` — per-project setup (dev container + deploy key + git wiring)
- `dev-setup.sh` — fresh-machine setup of the bootstrap tools
- `.devcontainer/` — dev container template copied into new projects by `init.sh`. The dev container bind-mounts your host `~/.gitconfig`, `~/.ssh`, and `~/.claude/{settings.json,statusline.js}` so identity flows through without being hardcoded.
