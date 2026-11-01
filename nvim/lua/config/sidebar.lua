-- Right sidebar, like VS Code: file tree (SPC o p) above a git changes
-- panel (SPC o g). Both are neo-tree windows that edgy.nvim stacks on the
-- right. Mirrors Doom's treemacs + git panel:
--   * the git panel opens by itself when you open a file in a git repo on
--     a wide screen (150+ columns) and follows you between repos;
--   * it refreshes when files change on disk (a coding agent at work);
--   * q / SPC o g hides it, and it stays hidden until SPC o g again.
local util = require("config.util")
local M = {}

M.auto = true          -- auto-show the git panel
M.min_columns = 150

local function find(source)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "neo-tree" and vim.b[buf].neo_tree_source == source then
      return win
    end
  end
end
M.find = find

-- neo-tree keeps one window per position, so the two sources use different
-- positions; edgy then moves both into the right sidebar.
local position = { filesystem = "right", git_status = "top" }

local function neotree(action, source, dir)
  require("edgy") -- make sure the layout manager is there before the window appears
  local cmd = ("Neotree action=%s source=%s position=%s"):format(action, source, position[source])
  if dir then cmd = cmd .. " dir=" .. vim.fn.fnameescape(dir) end
  vim.cmd(cmd)
end

--- Biggest normal (non-sidebar, non-floating) window in this tab.
function M.main_window()
  local best, area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative == "" and vim.bo[buf].filetype ~= "neo-tree" then
      local a = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if a > area then best, area = win, a end
    end
  end
  return best
end

--- Run an Ex command in the main area (so diffs don't squeeze into the sidebar).
function M.main_window_do(cmd)
  local win = M.main_window()
  if win then vim.api.nvim_set_current_win(win) end
  vim.cmd(cmd)
end

function M.toggle_tree()
  local win = find("filesystem")
  if win and vim.api.nvim_get_current_win() ~= win then
    vim.api.nvim_set_current_win(win)
  elseif win then
    neotree("close", "filesystem")
  else
    neotree("focus", "filesystem", util.root())
  end
end

function M.reveal()
  require("edgy")
  vim.cmd("Neotree action=focus source=filesystem position=right reveal=true")
end

local timer
local fingerprint

local function refresh_tick()
  local win = find("git_status")
  if not win then
    if timer then timer:stop(); timer:close(); timer = nil end
    return
  end
  local ok, state = pcall(function() return require("neo-tree.sources.manager").get_state("git_status") end)
  local dir = ok and state and state.path or util.root()
  vim.system({ "sh", "-c", "git rev-parse HEAD 2>/dev/null; git status --porcelain 2>/dev/null; git diff --numstat 2>/dev/null" },
    { cwd = dir, text = true }, function(res)
      local fp = res.stdout or ""
      if fp ~= fingerprint then
        fingerprint = fp
        vim.schedule(function()
          pcall(function() require("neo-tree.sources.manager").refresh("git_status") end)
        end)
      end
    end)
end

local function start_timer()
  if timer then return end
  timer = vim.uv.new_timer()
  timer:start(2000, 2000, vim.schedule_wrap(refresh_tick))
end

function M.show_git(root)
  root = root or util.root()
  if not vim.fs.root(root, ".git") then
    vim.notify("Not inside a git repo", vim.log.levels.WARN)
    return
  end
  local cur = vim.api.nvim_get_current_win()
  neotree("show", "git_status", root)
  if vim.api.nvim_win_is_valid(cur) then vim.api.nvim_set_current_win(cur) end
  start_timer()
end

function M.hide_git()
  M.auto = false
  local win = find("git_status")
  if win then pcall(vim.api.nvim_win_close, win, false) end
end

function M.toggle_git()
  if find("git_status") then
    M.hide_git()
  else
    M.auto = true
    M.show_git()
  end
end

-- Auto-show on wide screens, follow between repos.
local function maybe_show()
  if not M.auto or vim.o.columns < M.min_columns then return end
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" or name:match("^%w+://") then return end
  if vim.api.nvim_win_get_config(0).relative ~= "" then return end
  local root = vim.fs.root(name, ".git")
  if not root then return end
  -- The big git UI or the live diff already on screen: leave it alone.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    if ft:match("^Neogit") or ft == "livediff" then return end
  end
  if find("git_status") then
    local ok, state = pcall(function() return require("neo-tree.sources.manager").get_state("git_status") end)
    if ok and state and state.path and vim.fs.normalize(state.path) == vim.fs.normalize(root) then return end
  end
  M.show_git(root)
end

vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("dotfiles-sidebar", { clear = true }),
  callback = function()
    vim.defer_fn(function() pcall(maybe_show) end, 300)
  end,
})

return M
