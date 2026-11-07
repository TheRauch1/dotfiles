-- Projects as workspaces (tab pages), remembered across restarts.
--
-- One Neovim holds all your projects: each tab page is one project (its
-- own :tcd), with its own agent drawer (config/agent.lua). The tab line
-- lists them with the agent's state, so you see at a glance which project
-- is waiting for you.
--
-- The layout is saved to stdpath("state")/cockpit/<name>.json whenever it
-- changes and on exit: per project its directory, the file you were in,
-- the cursor, and whether it had an agent. `dev` (doom/shell.zsh) starts
-- Neovim with vim.g.cockpit_restore, so after a reboot every project comes
-- back, and Alt+a resumes each agent's last conversation (pi -c).
local M = {}

M.name = vim.env.COCKPIT_NAME or "default"

local function session_file()
  local d = vim.fn.stdpath("state") .. "/cockpit"
  vim.fn.mkdir(d, "p")
  return ("%s/%s.json"):format(d, M.name)
end
M.session_file = session_file

local function tab_cwd(tabnr) return vim.fn.getcwd(-1, tabnr) end

local function empty_tab(tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.bo[buf].filetype
    if vim.api.nvim_buf_get_name(buf) ~= "" and ft ~= "snacks_dashboard" then return false end
    if vim.bo[buf].modified then return false end
  end
  return true
end

--- Go to the workspace of `dir`, creating it (a new tab, :tcd dir) if needed.
--- opts.files = false skips the file picker in a new workspace.
function M.open(dir, opts)
  opts = opts or {}
  dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "")
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab_cwd(i) == dir then
      vim.api.nvim_set_current_tabpage(tab)
      return false
    end
  end
  if not empty_tab(0) then vim.cmd("tabnew") end
  vim.cmd("tcd " .. vim.fn.fnameescape(dir))
  if opts.files ~= false then
    pcall(function() Snacks.picker.files({ cwd = dir, title = "Files in " .. vim.fn.fnamemodify(dir, ":~") }) end)
  end
  M.save()
  return true
end

--- SPC p p: pick a project under ~/dev, open it as a workspace.
function M.pick_project()
  Snacks.picker.projects({
    confirm = function(picker, item)
      picker:close()
      if item then M.open(item.file) end
    end,
  })
end

---------------------------------------------------------------------------
-- Tab line: " 1 api ● │ 2 web ◐ "
---------------------------------------------------------------------------

function M.tabline()
  local agent = require("config.agent")
  local cur = vim.fn.tabpagenr()
  local s = {}
  for i = 1, vim.fn.tabpagenr("$") do
    local root = tab_cwd(i)
    local mark = agent.mark(root)
    s[#s + 1] = (i == cur and "%#TabLineSel#" or "%#TabLine#")
      .. ("%%%dT %d %s%s "):format(i, i, vim.fn.fnamemodify(root, ":t"), mark ~= "" and (" " .. mark) or "")
  end
  return table.concat(s, "%#TabLineFill#│") .. "%#TabLineFill#%T"
end

function M.setup_tabline()
  vim.o.tabline = "%!v:lua.require'config.workspaces'.tabline()"
  vim.o.showtabline = 1 -- only with 2+ projects open
end

---------------------------------------------------------------------------
-- Save / restore
---------------------------------------------------------------------------

local function main_file(tab)
  local best, area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == "" and name ~= "" and vim.api.nvim_win_get_config(win).relative == "" then
      local a = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if a > area then best, area = { file = name, cursor = vim.api.nvim_win_get_cursor(win) }, a end
    end
  end
  return best
end

function M.snapshot()
  local agents = require("config.agent").roots_with_agents()
  local tabs = {}
  local current = 1
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local cwd = tab_cwd(i)
    local f = main_file(tab)
    tabs[#tabs + 1] = { cwd = cwd, file = f and f.file, cursor = f and f.cursor, agent = agents[cwd] or nil }
    if tab == vim.api.nvim_get_current_tabpage() then current = i end
  end
  return { version = 1, current = current, tabs = tabs }
end

local restoring = false

function M.save()
  if restoring or vim.g.cockpit_restore == nil then return end
  local data = M.snapshot()
  -- Never overwrite a saved multi-project session with an empty start.
  if #data.tabs == 1 and not data.tabs[1].file and not data.tabs[1].agent then return end
  local path = session_file()
  local tmp = path .. ".tmp"
  vim.fn.writefile({ vim.json.encode(data) }, tmp)
  local uv = vim.uv or vim.loop
  uv.fs_rename(tmp, path)
end

function M.restore(data)
  if not data then
    local path = session_file()
    if vim.fn.filereadable(path) == 0 then return false end
    local ok, d = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if not ok or type(d) ~= "table" or type(d.tabs) ~= "table" then return false end
    data = d
  end
  restoring = true
  local agent = require("config.agent")
  local first = true
  for _, t in ipairs(data.tabs) do
    if type(t.cwd) == "string" and vim.fn.isdirectory(t.cwd) == 1 then
      if not first then vim.cmd("tabnew") end
      first = false
      vim.cmd("tcd " .. vim.fn.fnameescape(t.cwd))
      if t.file and vim.fn.filereadable(t.file) == 1 then
        vim.cmd("edit " .. vim.fn.fnameescape(t.file))
        if type(t.cursor) == "table" then
          pcall(vim.api.nvim_win_set_cursor, 0, { t.cursor[1], t.cursor[2] })
          vim.cmd("normal! zz")
        end
      end
      if t.agent then agent.mark_resume(t.cwd) end
    end
  end
  local n = vim.fn.tabpagenr("$")
  vim.cmd("tabnext " .. math.min(math.max(tonumber(data.current) or 1, 1), n))
  restoring = false
  return not first
end

function M.setup()
  M.setup_tabline()
  local group = vim.api.nvim_create_augroup("cockpit_workspaces", { clear = true })
  vim.api.nvim_create_autocmd({ "TabNewEntered", "TabClosed", "TabEnter", "DirChanged", "BufEnter", "VimLeavePre" }, {
    group = group,
    callback = function()
      -- During startup and on quick buffer hops, save a moment later, once.
      if M._pending then return end
      M._pending = true
      vim.defer_fn(function() M._pending = false; pcall(M.save) end, 200)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() pcall(M.save) end })
  vim.api.nvim_create_user_command("Cockpit", function()
    vim.g.cockpit_restore = vim.g.cockpit_restore or 1
    if not M.restore() then vim.notify("No saved projects yet (" .. session_file() .. ")") end
  end, { desc = "Restore saved projects and agents" })
  if vim.g.cockpit_restore and vim.fn.argc() == 0 then
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      nested = true,
      callback = function() M.restore() end,
    })
  end
end

return M
