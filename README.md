# dotfiles

Neovim, tuned for terminal use over SSH (a Linux box or VM, from a laptop
or an iPad) and for working with a coding agent ([pi](https://pi.dev)). Tools come from [mise](https://mise.jdx.dev),
so the same setup runs on Linux and macOS.

## Install

```bash
git clone https://github.com/TheRauch1/dotfiles ~/dev/dotfiles
~/dev/dotfiles/setup.sh
```

`setup.sh` is a plain bash script: it symlinks the configs into place
(backing up anything already there), links the commands in `bin/` to
`~/.local/bin`, adds one line to `~/.bashrc` / `~/.zshrc` that sources
`shell/rc.sh` (PATH, `EDITOR=nvim`), and installs [mise](https://mise.jdx.dev)
and the tools in `mise/config.toml` (gh, ripgrep, fd, lazygit, language
servers, ...). Re-run it any time, e.g. after `git pull`.

## What's here

| Path               | Linked to          | What                                     |
|--------------------|--------------------|------------------------------------------|
| `nvim/`            | `~/.config/nvim`   | Neovim config ([cheat sheet](nvim/CHEATSHEET.md)) |
| `bin/`             | `~/.local/bin/`    | `ide`, `dev`, `pd` |
| `shell/rc.sh`      | `~/.config/dotfiles/rc.sh` | PATH, editor, terminal fallback; sourced by your shell |
| `mise/config.toml` | `~/.config/mise/config.toml` | CLI tools and language servers |
| `ghostty/config`   | `~/.config/ghostty/config`   | Option key works as Alt; terminfo copied on ssh |
| `cockpit/`         | `~/.config/cockpit`          | `dev` and `ide` sessions, agent hooks ([below](#cockpit-one-ssh-session-all-projects-and-agents)) |
| `pi/extensions/cockpit.ts` | `~/.pi/agent/extensions/` | Tells Neovim what pi is doing |
| `pi/extensions/command-gate.ts` | `~/.pi/agent/extensions/` | Bash rules for pi: read-only oc/kubectl run, other oc/kubectl and git push/reset/rebase/... ask first (test: `node tests/pi/test_command_gate.ts`) |

## Daily use

| Command   | Does                                                         |
|-----------|--------------------------------------------------------------|
| `dev`     | All projects + their agents in one Neovim that survives SSH drops and restarts (see Cockpit) |
| `ide`     | The same with tmux in charge: a tab per project, agent pane on the right (see Cockpit) |
| `pd`      | In a git repo: live-updating diff (same as `SPC g d` in Neovim) |

In Neovim press `SPC` for a menu of everything and `SPC ?` for the
[cheat sheet](nvim/CHEATSHEET.md).

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

## Overlays

Another repo can add to this setup without editing it. Link it at
`~/.config/dotfiles.d/<name>/` (or under `$DOTFILES_D`); everything in it
is optional:

| In the overlay                | Used by   | What happens |
|-------------------------------|-----------|--------------|
| `nvim/lua/overlay/<mod>.lua`  | Neovim    | `<overlay>/nvim` joins the runtimepath after lazy.nvim has started, then every `overlay/*.lua` is required (overlays and modules sorted by name) once the keymaps are set. A module that fails is reported with one error message and startup continues. |
| `shell.sh`                    | bash, zsh | `shell/rc.sh` sources every `dotfiles.d/*/shell.sh` at its end. |
| `mise.toml`                   | mise      | The overlay's `setup.sh` links it to `~/.config/mise/conf.d/<name>.toml` (native mise feature). |
| `CHEATSHEET.md`               | Neovim    | Appended to `SPC ?` (cheat sheet). |
| `pi/command-gate.json`        | pi        | `{"rules": [{"match": "kubectl*", "approval": "deny"}]}`: `*`-glob rules (`allow`, `prompt`, `deny`) checked before the pi command gate's own; first match wins. A file that does not parse blocks every bash command until fixed and `/reload`ed. |
| `setup.sh`                    | you       | Run by hand: links the overlay into `dotfiles.d`, installs, logs in. Safe to re-run. |

Overlays only add, never edit files here. Removing the
`dotfiles.d/<name>` link (and its `conf.d` file) removes the overlay.

Tests for the Neovim config run headless:
`nvim --headless -c "luafile tests/nvim/run.lua"` (set `TEST_DIR` to run
another directory of `test_*.lua` files, `TEST_FILTER` to pick tests).

## Language servers

Optional; LSP features turn on per language when the server is on `PATH`.
See the table at the end of the [cheat sheet](nvim/CHEATSHEET.md#language-servers).
