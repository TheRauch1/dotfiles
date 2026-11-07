# dotfiles

Neovim and Doom Emacs, set up alike, tuned for terminal use from an iPad
(SSH/mosh into a Linux box) and for watching a coding agent
([pi](https://pi.dev)) work. Tools come from [mise](https://mise.jdx.dev),
so the same setup runs on Linux and macOS.

## Install

```bash
git clone https://github.com/TheRauch1/dotfiles ~/dev/dotfiles
~/dev/dotfiles/setup.sh
```

That's all Neovim needs. For Doom Emacs as well, first install Emacs
(`sudo apt install -y emacs build-essential`, or `brew install emacs-plus`
on macOS).

`setup.sh` symlinks the configs into place (backing up anything already
there), hooks `doom/shell.zsh` into `~/.zshrc` and `~/.bashrc`, installs
[mise](https://mise.jdx.dev) and the tools in `mise/config.toml` (gh, ripgrep,
fd, language servers, ...), installs Doom Emacs if
it's missing, and runs `doom sync`. Re-run it any time, e.g. after
`git pull`.

## What's here

| Path               | Linked to          | What                                     |
|--------------------|--------------------|------------------------------------------|
| `doom/`            | `~/.config/doom`   | Doom config, cheat sheet, shell helpers, GitHub UI (`gh.el`) |
| `nvim/`            | `~/.config/nvim`   | Neovim config with the same keys and features ([cheat sheet](nvim/CHEATSHEET.md)) |
| `mise/config.toml` | `~/.config/mise/config.toml` | CLI tools and language servers |
| `ghostty/config`   | `~/.config/ghostty/config`   | Option key works as Meta (M-d)  |
| `cockpit/`         | `~/.config/cockpit`          | `dev` session, demo, Docker box ([below](#cockpit-one-ssh-session-all-projects-and-agents)) |
| `pi/extensions/cockpit.ts` | `~/.pi/agent/extensions/` | Tells Neovim what pi is doing |

## Daily use

| Command   | Does                                                         |
|-----------|--------------------------------------------------------------|
| `dev`     | All projects + their agents in one Neovim that survives SSH drops and restarts (see Cockpit) |
| `ide`     | The same with tmux in charge: a tab per project, agent pane on the right (see Cockpit) |
| `e file`  | Open in the background Emacs (survives dropped connections)  |
| `pd`      | In a git repo: live-updating diff (same as `SPC g d` in Emacs) |
| `ekill`   | Stop the Emacs daemon                                        |

Inside Emacs press `SPC` for a menu of everything, `SPC ?` for the
[cheat sheet](doom/CHEATSHEET.org), and `jk` instead of Esc.

`SPC g p` is GitHub through the `gh` CLI (`gh auth login` once): pull
requests, reviews, merging, CI checks with their logs and reruns
([doom/gh.el](doom/gh.el)). Magit status and the git panel show the
current branch's PR and whether its checks pass.

In Neovim, URLs are real terminal links (OSC 8): Ctrl+click opens them,
even when wrapped; Shift+Ctrl+click if a multiplexer captures the mouse.
`vim.g.osc8_links = false` turns it off.
Markdown renders in place (render-markdown.nvim; `SPC t m` toggles), and
the text of `[text](url)` links is clickable too.

## Cockpit: one SSH session, all projects and agents

Built for a small laptop screen and nothing but an SSH session into the
dev machine. Every project is a tab with its own agent (pi); the tab line
shows which agent is working (`◐`) or waiting for you (`●`), and you get a
notification when one is done.

Two ways to work, per tab:

- **Watch layout** (default for `SPC p p`): the agent on the left, the live
  diff on the right, refreshing as the agent edits. For prompting and
  watching. `Alt+a` hops between the two (under 120 columns they share
  the screen and `Alt+a` flips).
- **Code + drawer** (`SPC a w` toggles): Neovim gets the whole width; the
  agent is a drawer that slides over the code with `Alt+a` and away again,
  still working.

```
dev            # open (or reattach to) the cockpit
dev work       # a separate one, e.g. per machine or client; `dev ls` lists them
```

- **Projects:** `SPC p p` opens a project from `~/dev` in its own tab,
  `SPC TAB 1..9` switches.
- **Conversations:** `SPC a p` lists this project's earlier pi
  conversations (newest first, with their first prompt) and reopens one;
  `SPC a n` starts a fresh one; `SPC a i` sends a prompt from anywhere.
- **Talk to the agent from the code:** select lines and `SPC a s` pastes
  them with `path:lines` into the agent (no Enter, so you add the
  question). `SPC a e` sends the file's errors, `SPC a h` the git change.
- **Review what it did:** `]a` / `[a` walk the files it changed (they reload
  by themselves), `SPC a r` is the live diff of everything.
- **Coming back:** `dev` runs Neovim inside a hidden tmux (own socket and
  config, `cockpit/tmux.conf`), so a dropped SSH connection or a closed
  laptop costs nothing: SSH in, `dev`, you're back mid-sentence. After the
  machine itself restarts, `dev` reopens every project with its layout and
  the file and line you left, and each agent resumes the exact conversation
  it had (`pi --session`; `pi -c` if unknown).
  Saved in `~/.local/state/nvim/cockpit/<name>.json`.
- **Small screens:** under 120 columns the drawer is fullscreen; `Alt+z`
  toggles fullscreen anywhere.

All keys: `SPC ?`, section "Agent drawer". Another agent CLI works too:
`vim.g.agent_cmd = { "claude" }` (state is then guessed from its output).

**Your model:** `cockpit/pi-endpoint.sh spark http://spark.r4uch.xyz:8000/v1`
adds an OpenAI-compatible endpoint to pi (`~/.pi/agent/models.json`) with
the models it lists, and makes it pi's default.

**Windows Terminal:** `cockpit/windows-terminal.json` has a profile that
SSHs into the VM and runs `dev` in one click, and frees the keys Neovim and
pi need (Alt+Enter, Alt+arrows). Alt+a and Alt+z already reach the VM.

### Or: `ide`, with tmux in charge

The same idea laid out like VS Code, for when you want the agent always in
view: tmux shows one tab per project (with the agent's ◐ / ● / ! in the
tab), and each project tab is Neovim (code, file tree, git panel) with the
agent in its own pane on the right, a quarter of the width. Agents run in
tmux, not inside Neovim, so they keep going if Neovim is closed or crashes.
Only the projects you open are active, so a big `~/dev` stays fast.

```
ide            # open (or reattach); after a reboot it reopens every project
               # and continues each agent's last conversation
```

| Key | Does |
|-----|------|
| `Ctrl+b p` / `Alt+p` | open a project (or `.cockpit` workspace) from `~/dev` |
| `Alt+1..9`, click a tab | switch project |
| `Alt+a` / `Alt+z` | editor ↔ agent / zoom a pane |
| `Ctrl+b g` / `Alt+g` | lazygit in a popup |
| `Ctrl+b t` | a normal shell in a popup |
| `Ctrl+b w` | jump to the next agent waiting for you |
| `Ctrl+b X` | close a project (not reopened next time) |
| `Ctrl+b ?` | all keys ([cockpit/ide/KEYS](cockpit/ide/KEYS)) |

In its Neovim, `SPC a s/e/h/i` paste into the agent pane next to it.
The agent is pi by default; `IDE_AGENT=claude ide`, or `echo codex >
.cockpit-agent` in a project, picks another. For their ◐ / ● / ! in the
tabs, add [cockpit/hooks/claude-settings.json](cockpit/hooks/claude-settings.json)
to `~/.claude/settings.json`, and for codex `notify = ["node",
"~/.config/cockpit/hooks/agent-state.mjs", "waiting"]` to
`~/.codex/config.toml` (codex only reports "done", so no ◐).

#### Projects that span several repos

Like a VS Code multi-root workspace: list the repos in a `.cockpit` file
anywhere under `~/dev`, and `Ctrl+b p` offers it next to the repos.

```
# ~/dev/acme.cockpit
api      ~/dev/acme-api
web      ~/dev/acme-web
~/dev/shared-lib          # name defaults to the folder name
agent    claude           # optional, default pi
```

It opens as one tab, `acme`, working in `~/ws/acme/` (a folder of links:
`api/`, `web/`, `shared-lib/`). One agent sees and edits all the repos and
is told they're separate repos (a generated `AGENTS.md`/`CLAUDE.md`). The
file tree shows each repo, the git panel follows the repo of the file
you're in, and `Ctrl+b g` opens lazygit on that repo (from the agent pane
it asks which one). Edit the `.cockpit` file and reopen the tab to change
the list.

### Try it in Docker

A throwaway "remote machine" with this repo installed, three small demo
projects and pi:

```bash
docker compose -f cockpit/docker/compose.yml up -d --build
ssh -p 2222 dev@localhost        # password: dev
dev                              # or: ide
```

pi uses `PI_BASE_URL` (default `http://spark.r4uch.xyz:8000/v1`) when the
container can reach it, else a scripted demo model
(`cockpit/demo/mock-llm.mjs`: no AI, it recognizes "app.py" and "index.js"
and replays edits). `docker compose ... restart` re-checks the endpoint.
Home is a volume, so `docker compose restart` behaves like a reboot: try
`dev` afterwards. If the build hits GitHub's rate limit (mise downloads
tools from GitHub), run it with `GITHUB_TOKEN=$(gh auth token)`.

## Overlays

Another repo can add to this setup without editing it. Link it at
`~/.config/dotfiles.d/<name>/` (or under `$DOTFILES_D`); everything in it
is optional:

| In the overlay                | Used by   | What happens |
|-------------------------------|-----------|--------------|
| `nvim/lua/overlay/<mod>.lua`  | Neovim    | `<overlay>/nvim` joins the runtimepath after lazy.nvim has started, then every `overlay/*.lua` is required (overlays and modules sorted by name) once the keymaps are set. A module that fails is reported with one error message and startup continues. |
| `shell.sh`                    | bash, zsh | `doom/shell.zsh` sources every `dotfiles.d/*/shell.sh` at its end. |
| `mise.toml`                   | mise      | The overlay's `setup.sh` links it to `~/.config/mise/conf.d/<name>.toml` (native mise feature). |
| `CHEATSHEET.md`               | Neovim    | Appended to `SPC ?` (cheat sheet). |
| `setup.sh`                    | you       | Run by hand: links the overlay into `dotfiles.d`, installs, logs in. Safe to re-run. |

Overlays only add, never edit files here. Removing the
`dotfiles.d/<name>` link (and its `conf.d` file) removes the overlay.

Tests for the Neovim config run headless:
`nvim --headless -c "luafile tests/nvim/run.lua"` (set `TEST_DIR` to run
another directory of `test_*.lua` files, `TEST_FILTER` to pick tests).

## Language servers

Optional; LSP features turn on per language when the server is on `PATH`.
See the table at the end of the [cheat sheet](doom/CHEATSHEET.org).
