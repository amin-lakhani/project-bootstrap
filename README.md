# project-bootstrap-template

A one-script bootstrap for new projects and new machines that wires up:
- a per-user dotfiles repo (cloned, or created from [`dotfiles-template`](https://github.com/amin-lakhani/dotfiles-template))
- a per-project SSH deploy key with deploy-key registration on GitHub
- Node.js + Claude Code on the host
- git remote + initial pull

Marked as a [GitHub Template repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template) — click **Use this template** above to fork it under your own account, or just use it directly via the curl snippet below.

## Quickstart

Paste this into your terminal — it detects your GitHub username from `gh` CLI or your noreply-format `~/.gitconfig`, prompts if neither is set up, then runs `bootstrap.sh` from the canonical fork:

```bash
GH_USER="${BOOTSTRAP_GH_USER:-}"
[ -z "$GH_USER" ] && GH_USER="$(gh api user 2>/dev/null | grep -oE '"login":[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"login":[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$GH_USER" ] && GH_USER="$(git config --global user.email 2>/dev/null | sed -nE 's/^[0-9]+\+(.+)@users\.noreply\.github\.com$/\1/p')"
[ -z "$GH_USER" ] && read -rp "GitHub username: " GH_USER
curl -fsSL "https://raw.githubusercontent.com/${GH_USER}/project-bootstrap-template/main/bootstrap.sh" | bash
```

Set `BOOTSTRAP_GH_USER=<your-username>` ahead of time to skip the detection. If you forked this repo under a different name and want to fetch `bootstrap.sh` from your own fork, change the URL in the snippet directly — the snippet hardcodes `project-bootstrap-template` as the path.

## What it does, depending on where you run it

`bootstrap.sh` detects the state of your machine + current directory and branches:

| State | Trigger | What happens |
|---|---|---|
| **Fresh machine** | No dotfiles checkout found anywhere | Resolves identity → prompts: clone existing `dotfiles-<username>` OR create new from `dotfiles-template` OR skip. Walks through deploy key registration. Runs `install.sh`. Offers to chain into a new project (prompts for name + location, default base `~/dev_code/`). |
| **In an empty project folder** | cwd is somewhere under `$HOME` (not the workdir root) and has no `.git` | Skips dotfiles (already set up) and runs per-project setup against cwd: OS updates → Node.js + Claude Code → git config → per-project SSH key → deploy-key registration → `git init` → pull starter files. |
| **Ambiguous** | Dotfiles set up but cwd doesn't look project-shaped | Shows a menu: [1] new project (prompts for name + location, default base `~/dev_code/`), [2] re-install dotfiles, [q] quit. |

When [1] is chosen (from a fresh-machine chain or the ambiguous menu), `bootstrap.sh` prompts: "**Project folder name**" (lowercase letters/digits/`._-`), then shows the default location `~/dev_code/<name>` — press Enter to accept, or type an alternative absolute path (`~` allowed). If the path doesn't exist it's `mkdir -p`'d; an existing dir is accepted as long as it doesn't already contain a `.git` (lets you layer bootstrap onto a folder you've pre-populated with starter files). The script then `cd`s in and runs per-project setup. `$HOME` and `/` are rejected — must be a real sub-directory. Re-running the script for a new project goes in the right place automatically.

## Identity

`bootstrap.sh` resolves four identity values for you. First non-empty wins:

| Field | Sources (in priority order) |
|---|---|
| `GH_USER` | `BOOTSTRAP_GH_USER` env var → cache → `gh api user` → noreply-email parse from `~/.gitconfig` → prompt with detected default |
| `GH_USER_ID` | `BOOTSTRAP_GH_USER_ID` env var → cache → **auto-fetch from `api.github.com/users/<user>`** → prompt only on fetch failure |
| `GIT_NAME` | `BOOTSTRAP_GIT_NAME` env var → cache → `gh api user`'s name → `git config --global user.name` → prompt with detected default |
| `GIT_EMAIL` | `BOOTSTRAP_GIT_EMAIL` env var → cache → **always derived** as `<id>+<user>@users.noreply.github.com` (no prompt — eliminates real-email leak risk) |

Cached at `$XDG_CONFIG_HOME/project-bootstrap/user.env` (defaults to `~/.config/project-bootstrap/user.env`) after first resolution. Subsequent runs are silent.

If you set `BOOTSTRAP_GIT_EMAIL` to anything that isn't a noreply address, every run emits a warning about public-exposure risk.

## Other env vars worth knowing

| Variable | Default | Purpose |
|---|---|---|
| `DOTFILES_REPO_NAME` | `dotfiles-${GH_USER}` | Your per-user dotfiles repo name |
| `DOTFILES_TEMPLATE_OWNER` | `amin-lakhani` | Owner of the template to "Use template" from |
| `DOTFILES_TEMPLATE_NAME` | `dotfiles-template` | Repo name of the template |
| `BOOTSTRAP_WORK_DIR` | `dev_env_setup` | Folder name under `$HOME` for the dotfiles checkout. An existing `~/development/` is reused if present. |
| `BOOTSTRAP_CODE_DIR` | `~/dev_code` | Default base directory for **new project setups**. When you pick "Set up a new project" (from fresh-machine flow or ambiguous menu), the default location is `${BOOTSTRAP_CODE_DIR}/<name>`. You can still override per-project at the prompt. |

## `gh` CLI usage + auto-cleanup

If `gh` (the GitHub CLI) is installed, `bootstrap.sh` uses it for:
- Creating your dotfiles repo from the template (`gh repo create --template`)
- Registering deploy keys (`gh repo deploy-key add`)

This is dramatically smoother than the browser-walk fallback. If `gh` isn't installed or you haven't authenticated, the script falls back to opening the relevant GitHub pages in your browser for you to click through.

**Important security behavior** when `gh` is used:

- `bootstrap.sh` runs `gh auth login` if you're not already authed
- A trap fires at script exit (success OR crash) that ALWAYS runs `gh auth logout` — wiping the local credential regardless of whether the script created it or it pre-existed
- The browser is then opened to `https://github.com/settings/applications` and a red warning prints, strongly suggesting you also revoke the OAuth grant on GitHub itself (the `gh auth logout` only removes the local copy; the grant on GitHub persists until you revoke it)

If you have pre-existing `gh auth` you don't want wiped, you have 3 seconds at the start of the script to Ctrl-C.

## Security model

Every credential generated by `bootstrap.sh` is **scoped to a single repo**:

- The dotfiles deploy key is read-only and scoped to your `dotfiles-<username>` repo
- Each per-project deploy key is read/write and scoped to that one project repo
- `gh` auth (if used) is wiped from disk when the script exits

Combined: no broad-access user-account tokens persist on the machine after bootstrap. Blast radius = one repo per key.

## Sharing this with a class or other users

Two paths:

1. **Beginner**: send students the quickstart snippet above with `<username>` replaced by your own (so they fetch *your* canonical `bootstrap.sh`). They run it, get prompted for their identity, walked through creating a `dotfiles-<their-username>` from the template, and end up with their own private dotfiles + a project-ready machine. They never touch your private repos.
2. **Advanced**: have them fork both `project-bootstrap-template` and `dotfiles-template` under their own account. They customize freely. The `gh auth` cleanup + browser walks all still work.

## Logs

Every run tees output to `$HOME/.cache/project-bootstrap/bootstrap-<timestamp>.log`. Set `DEBUG=1` before the snippet for `set -x` tracing:

```bash
GH_USER="${BOOTSTRAP_GH_USER:-}"
[ -z "$GH_USER" ] && GH_USER="$(gh api user 2>/dev/null | grep -oE '"login":[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"login":[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$GH_USER" ] && GH_USER="$(git config --global user.email 2>/dev/null | sed -nE 's/^[0-9]+\+(.+)@users\.noreply\.github\.com$/\1/p')"
[ -z "$GH_USER" ] && read -rp "GitHub username: " GH_USER
DEBUG=1 curl -fsSL "https://raw.githubusercontent.com/${GH_USER}/project-bootstrap-template/main/bootstrap.sh" | bash
```

## Files

- `bootstrap.sh` — the single entry point (~875 lines, structured into clearly-delimited sections: logging, browser/clipboard helpers, identity, gh auth + cleanup trap, dotfiles flow, per-project setup, state detection, main)
- `README.md` — this file
