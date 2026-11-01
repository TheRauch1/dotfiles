local M = {}

--- File the user is "in": the current buffer's file, or, from a sidebar /
--- special buffer, the file in the biggest normal window.
local function current_file()
  local name = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype == "" and name ~= "" and not name:match("^%w+://") then return name end
  if vim.bo.filetype == "neo-tree" then
    local ok, state = pcall(function()
      return require("neo-tree.sources.manager").get_state(vim.b.neo_tree_source)
    end)
    if ok and state and state.path then return state.path end
  end
  local root = vim.b.livediff_root
  if root then return root end
  local best, area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local n = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == "" and n ~= "" and vim.api.nvim_win_get_config(win).relative == "" then
      local a = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if a > area then best, area = n, a end
    end
  end
  return best
end

--- Git root of the current file (or of the cwd), else the cwd.
function M.root(path)
  path = path or current_file() or vim.fn.getcwd()
  return vim.fs.root(path, ".git") or vim.fn.getcwd()
end

--- Directory of the current file (or the cwd).
function M.dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or name:match("^%w+://") then
    if vim.bo.filetype == "oil" then
      local ok, oil = pcall(require, "oil")
      if ok and oil.get_current_dir() then return oil.get_current_dir() end
    end
    return vim.fn.getcwd()
  end
  return vim.fs.dirname(name)
end

-- No cached file lists: agents create files behind our back, and fd is
-- fast enough to run on every SPC SPC (Doom: projectile-enable-caching nil).
function M.project_files()
  Snacks.picker.files({ cwd = M.root(), title = "Files in " .. vim.fn.fnamemodify(M.root(), ":~") })
end

function M.grep()
  Snacks.picker.grep({ cwd = M.root(), title = "Search " .. vim.fn.fnamemodify(M.root(), ":~") })
end

function M.cheatsheet()
  local file = vim.fn.stdpath("config") .. "/CHEATSHEET.md"
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.bo.readonly = false
end

--- Copy text to the clipboard (OSC 52 reaches the iPad) and say so.
function M.copy(text)
  vim.fn.setreg("+", text)
  vim.notify("Copied " .. text)
end

return M
