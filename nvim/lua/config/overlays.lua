-- Overlays: other repos linked at ~/.config/dotfiles.d/<name>/ (or
-- $DOTFILES_D/<name>/) can add Neovim modules (nvim/lua/overlay/*.lua) on
-- top of this config without editing it. See README "Overlays".
local M = {}

function M.root()
  local d = vim.env.DOTFILES_D
  if d and d ~= "" then return d end
  return vim.fn.expand("~/.config/dotfiles.d")
end

-- Sorted absolute overlay dirs; symlinks are followed.
function M.dirs()
  local out = {}
  for _, p in ipairs(vim.fn.glob(M.root() .. "/*", false, true)) do
    if vim.fn.isdirectory(p) == 1 then out[#out + 1] = p end
  end
  table.sort(out)
  return out
end

-- lazy.nvim resets the runtimepath, so call this after lazy.setup.
function M.setup_rtp()
  for _, d in ipairs(M.dirs()) do
    vim.opt.rtp:append(d .. "/nvim")
  end
end

-- A broken module is reported and skipped; startup continues.
function M.load()
  for _, d in ipairs(M.dirs()) do
    local files = vim.fn.glob(d .. "/nvim/lua/overlay/*.lua", false, true)
    table.sort(files)
    for _, f in ipairs(files) do
      local stem = vim.fn.fnamemodify(f, ":t:r")
      local ok, err = pcall(require, "overlay." .. stem)
      if not ok then
        vim.notify(("overlay %s: %s"):format(stem, err), vim.log.levels.ERROR)
      end
    end
  end
end

return M
