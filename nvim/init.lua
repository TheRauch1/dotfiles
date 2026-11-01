-- Neovim config mirroring ../doom (Doom Emacs), for side-by-side comparison.
-- Built for terminal use from an iPad (Blink over SSH, usually in tmux),
-- Ghostty on macOS and Windows Terminal. Press SPC for a menu, SPC ? for
-- the cheat sheet (CHEATSHEET.md next to this file).

vim.g.mapleader = " "
vim.g.maplocalleader = " m" -- like Doom's SPC m (language menu)

-- Nerd Font glyphs in the file tree, status line and menus. Off by default:
-- Blink's stock fonts have none. Set to true if your terminal font has them.
vim.g.have_nerd_font = false

-- mise's shims make gh, rg, fd and the language servers visible no matter
-- how Neovim was started (like Doom's env file).
local shims = vim.fn.expand("~/.local/share/mise/shims")
if vim.fn.isdirectory(shims) == 1 and not vim.env.PATH:find(shims, 1, true) then
  vim.env.PATH = shims .. ":" .. vim.env.PATH
end

require("config.options")
require("config.clipboard")
require("config.autocmds")

-- lazy.nvim, cloned on first start. Never prompts: failures are reported
-- and Neovim starts without plugins.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable",
    "https://github.com/folke/lazy.nvim.git", lazypath })
  if vim.v.shell_error ~= 0 then
    vim.schedule(function()
      vim.notify("Could not install lazy.nvim:\n" .. out, vim.log.levels.ERROR)
    end)
  end
end

if vim.uv.fs_stat(lazypath) then
  vim.opt.rtp:prepend(lazypath)
  require("lazy").setup("plugins", {
    lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json",
    defaults = { lazy = true },
    install = { missing = true, colorscheme = { "onedark", "habamax" } },
    checker = { enabled = false },          -- no update nags
    change_detection = { notify = false },
    rocks = { enabled = false },            -- no luarocks / C toolchain needed
    ui = { border = "rounded", icons = vim.g.have_nerd_font and {} or {
      cmd = "⌘", config = "🛠", event = "📅", ft = "📂", init = "⚙", keys = "🗝",
      plugin = "🔌", runtime = "💻", require = "🌙", source = "📄", start = "🚀",
      task = "📌", lazy = "💤 ",
    } },
    performance = {
      rtp = {
        disabled_plugins = { "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin", "netrwPlugin" },
      },
    },
  })
end

require("config.keymaps")
require("config.sidebar") -- auto-shows the git panel on wide screens
