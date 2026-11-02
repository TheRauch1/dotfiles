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

## Daily use

| Command   | Does                                                         |
|-----------|--------------------------------------------------------------|
| `e file`  | Open in the background Emacs (survives dropped connections)  |
| `pd`      | In a git repo: live-updating diff (same as `SPC g d` in Emacs) |
| `ekill`   | Stop the Emacs daemon                                        |

Inside Emacs press `SPC` for a menu of everything, `SPC ?` for the
[cheat sheet](doom/CHEATSHEET.org), and `jk` instead of Esc.

`SPC g p` is GitHub through the `gh` CLI (`gh auth login` once): pull
requests, reviews, merging, CI checks with their logs and reruns
([doom/gh.el](doom/gh.el)). Magit status and the git panel show the
current branch's PR and whether its checks pass.

## Overlays

Another repo can add to this setup without editing it. Link it at
`~/.config/dotfiles.d/<name>/` (or under `$DOTFILES_D`); everything in it
is optional:

| In the overlay                | Used by   | What happens |
|-------------------------------|-----------|--------------|
| `nvim/lua/overlay/<mod>.lua`  | Neovim    | `<overlay>/nvim` joins the runtimepath after lazy.nvim has started, then every `overlay/*.lua` is required (overlays and modules sorted by name) once the keymaps are set. A module that fails is reported with one error message and startup continues. |
| `shell.sh`                    | bash, zsh | `doom/shell.zsh` sources every `dotfiles.d/*/shell.sh` at its end. |
| `mise.toml`                   | mise      | The overlay's `setup.sh` links it to `~/.config/mise/conf.d/<name>.toml` (native mise feature). |
| `setup.sh`                    | you       | Run by hand: links the overlay into `dotfiles.d`, installs, logs in. Safe to re-run. |

Overlays only add, never edit files here. Removing the
`dotfiles.d/<name>` link (and its `conf.d` file) removes the overlay.

Tests for the Neovim config run headless:
`nvim --headless -c "luafile tests/nvim/run.lua"` (set `TEST_DIR` to run
another directory of `test_*.lua` files, `TEST_FILTER` to pick tests).

## Language servers

Optional; LSP features turn on per language when the server is on `PATH`.
See the table at the end of the [cheat sheet](doom/CHEATSHEET.org).
