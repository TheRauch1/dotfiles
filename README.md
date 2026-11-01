# dotfiles

Doom Emacs + tmux, tuned for terminal use from an iPad (SSH/mosh into a
Linux box) and for watching a coding agent ([pi](https://pi.dev)) work.

## Install

```bash
sudo apt install -y emacs ripgrep fd-find
gh repo clone TheRauch1/dotfiles ~/dev/dotfiles
~/dev/dotfiles/setup.sh
```

`setup.sh` symlinks the configs into place (backing up anything already
there), hooks `doom/shell.zsh` into `~/.zshrc`, installs Doom Emacs if
it's missing, and runs `doom sync`. Re-run it any time, e.g. after
`git pull`.

## What's here

| Path               | Linked to          | What                                     |
|--------------------|--------------------|------------------------------------------|
| `doom/`            | `~/.config/doom`   | Doom config, cheat sheet, shell helpers  |
| `tmux/tmux.conf`   | `~/.tmux.conf`     | No Esc lag, mouse, truecolor, OSC 52     |

## Daily use

| Command   | Does                                                         |
|-----------|--------------------------------------------------------------|
| `e file`  | Open in the background Emacs (survives dropped connections)  |
| `pd`      | In a git repo: pi on one side, live-updating diff on the other |
| `ekill`   | Stop the Emacs daemon                                        |

Inside Emacs press `SPC` for a menu of everything, `SPC ?` for the
[cheat sheet](doom/CHEATSHEET.org), and `jk` instead of Esc.

## Language servers

Optional; LSP features turn on per language when the server is on `PATH`.
See the table at the end of the [cheat sheet](doom/CHEATSHEET.org).
