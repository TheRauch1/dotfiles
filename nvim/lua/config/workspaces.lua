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

--- Git repo containing `path` (a file or folder), or nil. Works through the
--- links of a workspace folder (~/ws/acme/api -> ~/dev/acme-api).
function M.repo_of(path)
  return vim.fs.root(path, ".git")
end

--- Repos linked in a workspace folder (subfolders with a .git), sorted.
function M.workspace_repos(dir)
  local out = {}
  for name in vim.fs.dir(dir) do
    local p = dir .. "/" .. name
    if vim.fn.isdirectory(p) == 1 and vim.uv.fs_stat(p .. "/.git") then out[#out + 1] = p end
  end
  table.sort(out)
  return out
end

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
--- A new workspace starts in the watch layout (agent beside the live diff;
--- vim.g.cockpit_layout = "code" opens the file picker instead).
--- opts.files = false skips the file picker, opts.layout overrides.
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
  local layout = opts.layout or vim.g.cockpit_layout or "watch"
  if layout == "watch" and vim.fs.root(dir, ".git") then
    require("config.agent").watch(dir)
  elseif opts.files ~= false then
    pcall(function() Snacks.picker.files({ cwd = dir, title = "Files in " .. vim.fn.fnamemodify(dir, ":~") }) end)
  end
  M.save()
  return true
end

--- SPC p p: pick a project under ~/dev, open it as a workspace.
function M.pick_project()
  if require("config.agent").ide then
    -- ide: projects are tmux tabs; the same picker as prefix p.
    vim.fn.jobstart({ "tmux", "display-popup", "-E", "-w", "70%", "-h", "60%",
      vim.fn.expand("~/.config/cockpit/ide/pick-project.sh") })
    return
  end
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
  vim.o.showtabline = 2 -- always: it's the project switcher
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
    local ag = agents[cwd]
    local layout = vim.t[tab].cockpit_watch and "watch" or nil
    tabs[#tabs + 1] = { cwd = cwd, file = f and f.file, cursor = f and f.cursor,
      agent = ag and true or nil, session = type(ag) == "string" and ag or nil, layout = layout }
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
  local watch = {}
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
      if t.agent then agent.mark_resume(t.cwd, t.session) end
      if t.layout == "watch" then
        watch[#watch + 1] = vim.api.nvim_get_current_tabpage()
        vim.t.cockpit_watch = t.cwd
      end
    end
  end
  local n = vim.fn.tabpagenr("$")
  vim.cmd("tabnext " .. math.min(math.max(tonumber(data.current) or 1, 1), n))
  restoring = false
  -- Watch tabs come back with their agent beside the live diff.
  local cur = vim.api.nvim_get_current_tabpage()
  for _, tab in ipairs(watch) do
    vim.api.nvim_set_current_tabpage(tab)
    agent.watch(vim.t.cockpit_watch, { insert = false })
  end
  vim.api.nvim_set_current_tabpage(cur)
  vim.cmd.stopinsert()
  return not first
end

function M.setup()
  if vim.env.COCKPIT_IDE then
    -- ide: tmux shows the projects; this Neovim is one project with the
    -- file tree and git panel open, like VS Code's side bar.
    local sidebar = require("config.sidebar")
    sidebar.min_columns = 0
    vim.api.nvim_create_autocmd("VimEnter", {
      group = vim.api.nvim_create_augroup("cockpit_ide", { clear = true }),
      once = true,
      callback = function()
        vim.defer_fn(function()
          pcall(sidebar.toggle_tree)
          pcall(function() vim.cmd("wincmd p") end)
          local git = M.repo_of(vim.fn.getcwd()) or M.workspace_repos(vim.fn.getcwd())[1]
          if git then pcall(sidebar.show_git, git) end
        end, 100)
      end,
    })
    -- Tell tmux which repo you're in, so prefix g opens lazygit there (in a
    -- workspace of several repos, the one of the current file).
    if vim.env.TMUX and vim.env.TMUX_PANE then
      vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
        group = vim.api.nvim_create_augroup("cockpit_ide_git", { clear = true }),
        callback = function(ev)
          local name = vim.api.nvim_buf_get_name(ev.buf)
          local root = (vim.bo[ev.buf].buftype == "" and name ~= "" and M.repo_of(name)) or M.repo_of(vim.fn.getcwd())
          if root == M._git_root then return end
          M._git_root = root
          vim.fn.jobstart({ "tmux", "set", "-p", "-t", vim.env.TMUX_PANE, root and "@git_root" or "-u",
            root and root or "@git_root" })
        end,
      })
    end
  else
    M.setup_tabline()
  end
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
