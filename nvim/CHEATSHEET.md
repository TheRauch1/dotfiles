# Neovim on iPad — Cheat Sheet

Open anytime with `SPC ?`. Press `SPC` and wait: a menu shows every key.
Same keys as the Doom setup (`../doom/CHEATSHEET.org`) wherever it made sense.

## Modes (vim)

| Key         | Does                                       |
|-------------|--------------------------------------------|
| `i` / `a`   | start typing (before / after cursor)       |
| `jk`        | back to normal mode (iPad has no Esc)      |
| `C-[`       | also Esc                                   |
| `C-s`       | save (files also auto-save after 5 s idle) |
| `u` / `C-r` | undo / redo (undo survives restarts)       |
| `v` / `V`   | select chars / lines                       |

## Files & projects

| Key         | Does                                     |
|-------------|------------------------------------------|
| `SPC SPC`   | find file in project                     |
| `SPC .`     | browse files here (h up, l open, q close)|
| `SPC f f`   | find file below this file's folder       |
| `SPC f r`   | recent files                             |
| `SPC ,`     | switch buffer                            |
| `SPC p p`   | switch project (`~/dev`)                 |
| `SPC /`     | search text in project                   |
| `SPC *`     | search word under cursor in project      |
| `SPC s s`   | search in this file                      |
| `SPC s r`   | resume the last search                   |
| `` SPC ` `` | flip to previous file                    |
| `]b` / `[b` | next / prev open file                    |
| `SPC f y`   | copy file path                           |

In a picker: type to filter, `C-n`/`C-p` or arrows move, `RET` opens,
`jk` / `Esc` leaves the input, `Esc` again closes.

## Folder browser (oil, `SPC o -` or `SPC .`)

It's a text buffer: edit names, `dd` to delete, `o` to add, then `:w` applies.

| Key         | Does                    |
|-------------|-------------------------|
| `j` / `k`   | down / up               |
| `l` / `RET` | open file or folder     |
| `h` / `-`   | up one folder           |
| `g.`        | show / hide dotfiles    |
| `q`         | close                   |

## Right sidebar: file tree + git panel (like VS Code)

File tree (`SPC o p`) on top, git panel (`SPC o g`) below it.
`SPC w h` / `SPC w l` (or `C-w h` / `C-w l`) moves between sidebar and code.

The git panel opens by itself when you open a file in a git repo on a
wide screen (150+ columns), follows you between repos, and refreshes
when files change on disk. `q` / `SPC o g` hides it (stays hidden until
`SPC o g` again).

| Key (file tree) | Does                           |
|-----------------|--------------------------------|
| `j` / `k`       | move                           |
| `TAB` / `l`     | expand / open                  |
| `h`             | collapse                       |
| `RET`           | open file                      |
| `a` / `d` / `r` | new file (`dir/` = folder) / delete / rename |
| `H`             | show / hide hidden files       |
| `q`             | hide                           |
| `SPC o P`       | show the current file in the tree |

| Key (git panel) | Does                           |
|-----------------|--------------------------------|
| `RET`           | open file                      |
| `=`             | side-by-side diff of the file  |
| `s` / `u`       | stage / unstage file           |
| `S`             | stage everything               |
| `x`             | discard changes (asks first)   |
| `cc`            | commit staged (asks for message) |
| `P`             | push                           |
| `q`             | hide panel                     |

## Code

| Key         | Does                          |
|-------------|-------------------------------|
| `gd`        | go to definition              |
| `gD`        | references                    |
| `K`         | docs for symbol               |
| `SPC c a`   | code actions (LSP)            |
| `SPC c r`   | rename symbol                 |
| `SPC c f`   | format buffer                 |
| `SPC c x`   | list errors (file), `SPC c X` project |
| `]e` / `[e` | next / prev error             |
| `gcc`       | comment line (`gc` + motion)  |
| `ys` `cs` `ds` | add / change / delete surrounding |
| `SPC t f`   | format on save on / off       |

Completion pops up while typing: `Tab` / `S-Tab` move, `RET` accepts,
`C-e` closes, `C-space` opens it.

Python formats with ruff on save; Rust with rustfmt (if installed);
Typst via tinymist. JS/TS/JSON/YAML only if prettier is installed.

## Multi-cursor (like Cmd+D in VS Code)

| Key             | Does                                            |
|-----------------|-------------------------------------------------|
| `C-d` or `M-d`  | select word under cursor; again = add next match |
| `M-D`           | add previous match instead                      |
| `R` (visual)    | select all matches of the selection             |
| `c`             | change all selected matches: type the new text  |
| `RET`           | skip the match at the cursor                    |
| `Q`             | remove the match at the cursor                  |
| `n` / `N`       | add next / previous match                       |
| `Esc Esc`       | done (first Esc leaves typing, second ends it)  |

`M-` is Option on the iPad (Blink: Option as Meta) and in Ghostty
(`macos-option-as-alt`). `C-d` works everywhere, Windows Terminal too.
(It replaces vim's half-page-down; use `C-f` / `C-b` or the trackpad.)

## Windows & workspaces

| Key                   | Does                     |
|-----------------------|--------------------------|
| `SPC w v` / `SPC w s` | split right / below      |
| `SPC w h/j/k/l`       | go to window left/down/up/right |
| `SPC w w`             | next window              |
| `SPC w d`             | close window             |
| `SPC w m`             | maximize / restore       |
| `SPC 1..9`            | jump to window by number |
| `SPC TAB TAB`         | list workspaces (tabs)   |
| `SPC TAB n` / `d`     | new / close workspace    |
| `SPC TAB 1..9`        | switch workspace         |

## Live diff (watch a coding agent work)

`SPC g d` turns the current window into a live diff: every change in the
repo since the last commit, new files included, all expanded, refreshed
every 2 seconds when something changes. `:LiveDiff [dir]` does the same.

| Key (live diff)   | Does                                  |
|-------------------|---------------------------------------|
| `C-j` / `C-k`     | next / prev hunk or file              |
| `]f` / `[f`       | next / prev file (also `]]` `[[`)     |
| `TAB`             | fold / unfold a file                  |
| `RET`             | jump to that line in the file         |
| `s` / `u`         | stage / unstage the file              |
| `x`               | discard the file's changes (asks first) |
| `cc`              | commit (Neogit)                       |
| `gr`              | refresh now                           |
| `q`               | back to the previous buffer           |

Open files reload by themselves when changed on disk. If you have unsaved
edits in a file that also changed on disk, you get a warning instead (no
prompt): `:e!` takes the disk version, `:w` keeps yours.

## Git

| Key       | Does                                          |
|-----------|-----------------------------------------------|
| `SPC g g` | Neogit, a magit clone (s stage, u unstage, x discard, c c commit, P p push, TAB fold, q close) |
| `SPC g G` | lazygit                                       |
| `SPC g d` | live diff (see above)                         |
| `SPC g D` | side-by-side diff of all changes (Diffview)   |
| `SPC g h` | history of this file, `SPC g H` of the repo   |
| `SPC g l` | git log                                       |
| `SPC g S` | changed files (picker)                        |
| `]d` / `[d` | next / prev change in this file             |
| `SPC g s` / `SPC g r` | stage / revert the change at the cursor |
| `SPC g =` | show the change at the cursor                 |
| `SPC g b` | blame line, `SPC g B` whole file              |
| `SPC g o` | copy the GitHub URL of this line              |
| `SPC o g` | git panel in the right sidebar                |
| `SPC o e` | terminal popup, `SPC o E` in a new tab        |

## GitHub: pull requests, reviews, CI (gh CLI)

Needs `gh auth login` once. `SPC g p` opens the menu:

| Key         | Does                                    |
|-------------|-----------------------------------------|
| `SPC g p l` | open pull requests                      |
| `SPC g p m` | my pull requests                        |
| `SPC g p r` | waiting for my review                   |
| `SPC g p p` | this branch's pull request              |
| `SPC g p v` | view a PR by number or URL              |
| `SPC g p n` | new pull request                        |
| `SPC g p a` | GitHub Actions runs, `A` this branch's  |
| `SPC g p R` | any other repo (OWNER/REPO)             |
| `SPC g p o` | octo.nvim (line-by-line review comments) |

Commands: `:GhPrList [OWNER/REPO]`, `:GhPr 123 [OWNER/REPO]`,
`:GhRuns [OWNER/REPO]`, `:GhRun ID [OWNER/REPO]`.

Buffers with running checks refresh themselves every 15 s and say when CI
finishes.

| Key (gh buffers) | Does                                           |
|------------------|------------------------------------------------|
| `RET`            | open PR / run, log of a check, diff of a file  |
| `TAB`            | PR list: show a PR's checks; run: show steps   |
| `?`              | all keys of this buffer                        |
| `d`              | diff                                           |
| `c`              | check out the PR's branch                      |
| `a` / `r`        | approve / request changes                      |
| `C`              | comment (`C-c C-c` sends, `C-c C-k` cancels)   |
| `m`              | merge (squash / merge / rebase / auto-merge)   |
| `L`              | log of the check at the cursor (`]e` `[e`: errors) |
| `R`              | rerun failed checks (or the job at the cursor) |
| `X`              | cancel a run                                   |
| `f` / `/`        | PR list: filter / search (`label:bug`, ...)    |
| `b`              | runs: this branch / all                        |
| `O`              | open the PR in octo.nvim                       |
| `o` / `Y`        | copy the github.com URL                        |
| `gr` / `q`       | refresh / back                                 |

## Toggles & help

| Key       | Does                     |
|-----------|--------------------------|
| `SPC t z` | zen mode                 |
| `SPC t w` | word wrap                |
| `SPC t l` | relative line numbers    |
| `SPC h k` | search all keys          |
| `SPC h h` | help pages               |
| `SPC h n` | notification history     |
| `SPC h l` | plugins (lazy.nvim)      |
| `SPC :`   | run any command          |
| `SPC q q` | save all and quit        |

## iPad setup tips

- Blink Shell: Settings → Keyboard → Caps Lock → Esc, and Option as Meta.
- Copying (`y`) lands on the iPad clipboard via OSC 52 (also through tmux).
  To paste from the iPad, use Cmd+V (it types the text in).
- Touch / trackpad: tap to place the cursor, two-finger scroll, click in the tree.
- Nerd Font icons are off; set `vim.g.have_nerd_font = true` in `init.lua`
  if your terminal font has them.

## Language servers

From mise (`mise/config.toml`), found on PATH; missing ones are skipped.

| Language      | Server                                   |
|---------------|------------------------------------------|
| Python        | ty (types, hover, go to) + ruff (lint, format) |
| JS / TS       | TypeScript 7's own `tsc --lsp` (typescript-language-server if TS < 7) |
| Rust          | rust-analyzer                            |
| Typst         | tinymist                                 |
| Bash          | bash-language-server                     |
| YAML          | yaml-language-server                     |
| JSON/HTML/CSS | vscode-langservers-extracted             |
| Go            | gopls (if installed)                     |

Syntax highlighting uses Vim's built-in syntax files. Tree-sitter is used
only for the parsers Neovim ships (Lua, Vim, Markdown, C, help), because
building more needs a C compiler; nothing ever asks to install one.
