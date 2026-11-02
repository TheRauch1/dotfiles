-- SPC ? : personal cheat sheet, plus the sheets overlays ship.

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- Temp $HOME holding the overlay root and a personal config dir.
-- Returns the HOME dir and restores everything via env.restore().
local function env()
  local home = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(home, "p")
  local old_home, old_d, old_stdpath = vim.env.HOME, vim.env.DOTFILES_D, vim.fn.stdpath
  vim.env.HOME = home
  vim.env.DOTFILES_D = home .. "/overlays"
  vim.fn.mkdir(home .. "/overlays", "p")
  vim.fn.stdpath = function(what)
    if what == "config" then return home .. "/config" end
    return old_stdpath(what)
  end
  package.loaded["config.overlays"] = nil
  write(home .. "/config/CHEATSHEET.md", "# Personal\n\n| Key | Does |\n| `a` | alpha |\n")
  return {
    home = home,
    restore = function()
      vim.env.HOME, vim.env.DOTFILES_D, vim.fn.stdpath = old_home, old_d, old_stdpath
      package.loaded["config.overlays"] = nil
      vim.cmd("silent! %bwipeout!")
    end,
  }
end

local function with_env(fn)
  return function()
    local e = env()
    local ok, err = pcall(fn, e)
    e.restore()
    if not ok then error(err, 0) end
  end
end

return {
  files_lists_overlay_sheets = with_env(function(e)
    local o = require("config.overlays")
    write(e.home .. "/overlays/aaa/nvim/x.lua", "")
    T.eq(o.files("CHEATSHEET.md"), {})
    write(e.home .. "/overlays/work/CHEATSHEET.md", "# W\n")
    T.eq(o.files("CHEATSHEET.md"), { e.home .. "/overlays/work/CHEATSHEET.md" })
  end),

  cheatsheet_without_overlays_edits_file = with_env(function(e)
    require("config.util").cheatsheet()
    T.eq(vim.api.nvim_buf_get_name(0), e.home .. "/config/CHEATSHEET.md")
    T.ok(vim.bo.modifiable)
  end),

  cheatsheet_combined = with_env(function(e)
    write(e.home .. "/overlays/work/CHEATSHEET.md", "# Work title\n\nfirst\nsecond\n")
    require("config.util").cheatsheet()
    T.eq(vim.api.nvim_buf_get_name(0):match("cheatsheet://all") ~= nil, true)
    T.ok(not vim.bo.modifiable)
    T.eq(vim.bo.filetype, "markdown")
    T.eq(T.lines(0), {
      "# Personal", "", "| Key | Does |", "| `a` | alpha |",
      "", "---", "",
      "# work overlay  (~/overlays/work/CHEATSHEET.md)",
      "", "first", "second",
    })
    -- re-read on every call, reusing one buffer
    write(e.home .. "/overlays/work/CHEATSHEET.md", "# Work title\n\nchanged\n")
    local buf = vim.api.nvim_get_current_buf()
    require("config.util").cheatsheet()
    T.eq(vim.api.nvim_get_current_buf(), buf)
    T.eq(T.lines(0)[#T.lines(0)], "changed")
  end),

  cheatsheet_e_opens_source = with_env(function(e)
    local sheet = e.home .. "/overlays/work/CHEATSHEET.md"
    write(sheet, "# Work title\n\nfirst\nsecond\n")
    local util = require("config.util")
    util.cheatsheet()
    -- "second" is buffer line 11, line 4 of the overlay file
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    vim.api.nvim_feedkeys("e", "x", false)
    T.eq(vim.api.nvim_buf_get_name(0), sheet)
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 4)
    -- personal part
    util.cheatsheet()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_feedkeys("e", "x", false)
    T.eq(vim.api.nvim_buf_get_name(0), e.home .. "/config/CHEATSHEET.md")
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 4)
  end),
}
