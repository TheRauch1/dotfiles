-- The agent drawer (Alt+a): one coding agent (pi) per project, living in a
-- terminal buffer inside Neovim. Instead of a split, it slides over the
-- code as a big float (fullscreen on narrow screens) and slides away again
-- with the same key, still running.
--
--   * The status line and tab line show what each agent is doing: working,
--     waiting for you, or idle. When one starts waiting while you're in the
--     code, you get a notification (vim.g.agent_autopeek opens it instead).
--   * SPC a s/f/e/h paste context into the agent (selection with path:lines,
--     @file, the errors, the git hunk) without pressing Enter, so you can add
--     a question first.
--   * ]a / [a walk the files the agent changed, SPC a r opens the live diff.
--
-- State comes from pi's cockpit extension (../../../pi/extensions/cockpit.ts),
-- which writes a small JSON file. Without it (another agent CLI) the state is
-- guessed from terminal output and the changed files come from git status.
local util = require("config.util")
local M = {}

M.cmd = { "pi" }          -- vim.g.agent_cmd overrides
M.resume_args = { "-c" }  -- added when starting: continue the project's last session
M.narrow = 120            -- below this many columns the drawer is fullscreen
M.quiet_ms = 1500         -- output-based guess: this long without output = waiting

M.agents = {}             -- root -> agent
local tick                -- state timer

local uv = vim.uv or vim.loop
local function now() return uv.now() end

local function short(root) return vim.fn.fnamemodify(root, ":t") end

local function state_dir()
  local d = vim.fn.stdpath("state") .. "/cockpit"
  vim.fn.mkdir(d, "p")
  return d
end

local function state_path(root)
  return ("%s/%s.json"):format(state_dir(), (root:gsub("[^%w%-_.]", "%%")))
end

-- Project of the current window: the agent's own root inside a drawer,
-- else the git root of the current file (or the tab's directory).
function M.root()
  local b = vim.b.agent_root
  if b then return b end
  return util.root()
end

function M.get(root) return M.agents[root or M.root()] end

local function alive(a)
  return a and a.job and vim.fn.jobwait({ a.job }, 0)[1] == -1
end

local function visible(a)
  return a and a.win and vim.api.nvim_win_is_valid(a.win)
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function read_state_file(a)
  local st = uv.fs_stat(a.state_file)
  if not st then return end
  local mtime = st.mtime.sec * 1e9 + st.mtime.nsec
  if mtime == a.state_mtime then return a.ext end
  a.state_mtime = mtime
  local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(a.state_file), "\n")) end)
  if ok and type(data) == "table" then a.ext = data end
  return a.ext
end

local function git_changed(root)
  local out = vim.fn.systemlist({ "git", "-C", root, "-c", "core.quotepath=off", "status", "--porcelain", "-uall" })
  if vim.v.shell_error ~= 0 then return {} end
  local files = {}
  for _, l in ipairs(out) do
    local f = l:sub(4):gsub("^.* %-> ", "")
    files[#files + 1] = root .. "/" .. f
  end
  return files
end

--- "working" | "waiting" | "idle" | "exited" | "resume" (from a saved session)
function M.state(a)
  if not a then return nil end
  if not a.job then return a.resume and "resume" or nil end
  if not alive(a) then return "exited" end
  local ext = read_state_file(a)
  if ext and ext.state then return ext.state end
  if a.started and now() - a.started < 3000 then return "idle" end -- startup banner
  if a.last_output and now() - a.last_output < M.quiet_ms then return "working" end
  return a.had_output_burst and "waiting" or "idle"
end

--- Files the agent changed, as absolute paths.
function M.files(a)
  a = a or M.get()
  if not a then return {} end
  local ext = a.job and read_state_file(a)
  if ext and type(ext.files) == "table" then
    local out = {}
    for _, f in ipairs(ext.files) do
      out[#out + 1] = f:sub(1, 1) == "/" and f or (a.root .. "/" .. f)
    end
    return out
  end
  return git_changed(a.root)
end

local labels = { working = "working", waiting = "your turn", idle = "idle", exited = "exited", resume = "resume" }
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Status line text for the current project's agent (+ others waiting).
function M.statusline()
  local a = M.get()
  local parts = {}
  local s = M.state(a)
  if s then
    local mark = s == "working" and spinner[math.floor(now() / 100) % #spinner + 1] or "●"
    parts[#parts + 1] = ("π %s %s"):format(mark, labels[s])
  end
  local others = 0
  for root, o in pairs(M.agents) do
    if o ~= a and M.state(o) == "waiting" and root then others = others + 1 end
  end
  if others > 0 then parts[#parts + 1] = ("+%d waiting"):format(others) end
  return table.concat(parts, "  ")
end

function M.statusline_color()
  local s = M.state(M.get())
  if s == "waiting" then return { fg = "#e5c07b", gui = "bold" } end
  if s == "working" then return { fg = "#61afef" } end
  return { fg = "#7f848e" }
end

--- One-character mark for the tab line.
function M.mark(root)
  local s = M.state(M.agents[root])
  return ({ working = "◐", waiting = "●", idle = "○", exited = "✕", resume = "○" })[s] or ""
end

local function on_tick()
  for root, a in pairs(M.agents) do
    local s = M.state(a)
    if s ~= a.last_state then
      if s == "waiting" and a.last_state == "working" and not (visible(a) and vim.api.nvim_get_current_win() == a.win) then
        if vim.g.agent_autopeek then
          M.open(root)
        else
          vim.notify(("π %s is waiting for you (Alt+a)"):format(short(root)), vim.log.levels.WARN, { title = "agent" })
        end
      end
      a.last_state = s
    end
  end
  if next(M.agents) then
    vim.cmd("redrawstatus | redrawtabline")
  end
end

local function ensure_tick()
  if tick then return end
  tick = uv.new_timer()
  tick:start(250, 250, vim.schedule_wrap(on_tick))
end

---------------------------------------------------------------------------
-- The drawer
---------------------------------------------------------------------------

local function geometry(zoom)
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1 -- keep the status line
  if zoom or cols < M.narrow then
    return { row = 0, col = 0, width = cols, height = lines, border = "none" }
  end
  local w, h = math.floor(cols * 0.9), math.floor(lines * 0.9)
  return { row = math.floor((lines - h) / 2) - 1, col = math.floor((cols - w) / 2), width = w, height = h, border = "rounded" }
end

local function win_config(a)
  local g = geometry(a.zoom)
  local cfg = { relative = "editor", row = g.row, col = g.col, width = g.width, height = g.height,
    border = g.border, style = "minimal", zindex = 40 }
  if g.border ~= "none" then
    cfg.title = (" π %s · Alt+a hide · Alt+z zoom "):format(short(a.root))
    cfg.title_pos = "center"
  end
  return cfg
end

local function start(a, opts)
  opts = opts or {}
  local cmd = vim.deepcopy(vim.g.agent_cmd or M.cmd)
  if type(cmd) == "string" then cmd = { cmd } end
  local session = opts.session or (not opts.fresh and a.resume_session) or nil
  if session and vim.fn.filereadable(session) == 1 then
    vim.list_extend(cmd, { "--session", session })
  elseif not opts.fresh then
    vim.list_extend(cmd, vim.g.agent_resume_args or M.resume_args)
  end
  a.resume_session = nil
  a.buf = vim.api.nvim_create_buf(false, true)
  vim.b[a.buf].agent_root = a.root
  vim.bo[a.buf].bufhidden = "hide"
  os.remove(a.state_file)
  a.ext, a.state_mtime, a.last_output, a.had_output_burst = nil, nil, nil, false
  a.started = now()
  a.resume = nil
  local opts = {
    cwd = a.root,
    env = { COCKPIT_STATE = a.state_file },
    on_exit = function() vim.schedule(function() vim.cmd("redrawstatus") end) end,
  }
  vim.api.nvim_buf_call(a.buf, function()
    if vim.fn.has("nvim-0.11") == 1 then
      opts.term = true
      a.job = vim.fn.jobstart(cmd, opts)
    else
      a.job = vim.fn.termopen(cmd, opts)
    end
  end)
  vim.api.nvim_buf_attach(a.buf, false, {
    on_lines = function()
      local t = now()
      -- Output that isn't just the echo of your own typing counts as work.
      if not a.typed or t - a.typed > 400 then
        if a.last_output and t - a.last_output < M.quiet_ms then a.had_output_burst = true end
        a.last_output = t
      end
    end,
  })
  local function bmap(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = a.buf, desc = desc, silent = true })
  end
  bmap({ "t", "n" }, "<M-z>", function() M.zoom() end, "Agent: zoom / unzoom")
  bmap("n", "q", function() M.toggle() end, "Agent: hide / back to the code")
  vim.api.nvim_create_autocmd("TermEnter", { buffer = a.buf, callback = function() a.typed = now() end })
  -- typing in the drawer is not agent output
  vim.on_key(function(_, typed)
    if typed ~= "" and vim.api.nvim_get_current_buf() == a.buf and vim.api.nvim_get_mode().mode == "t" then
      a.typed = now()
    end
  end, vim.api.nvim_create_namespace("agent_typed_" .. a.buf))
  ensure_tick()
end

local function new(root)
  local a = M.agents[root] or { root = root }
  a.state_file = state_path(root)
  M.agents[root] = a
  return a
end

-- Start typing into the agent. Deferred too: when called from a picker's
-- confirm, the picker leaves insert mode after we return, which would drop
-- us back to normal mode, and the first keys of a prompt become commands.
local function type_here(win)
  vim.cmd.startinsert()
  vim.defer_fn(function()
    if vim.api.nvim_get_current_win() == win and vim.api.nvim_get_mode().mode ~= "t" then
      vim.cmd.startinsert()
    end
  end, 30)
end

local function term_window(win, float)
  local wo = vim.wo[win]
  if float then wo.winhighlight = "NormalFloat:Normal,FloatBorder:FloatBorder" end
  wo.sidescrolloff, wo.scrolloff = 0, 0
  wo.number, wo.relativenumber, wo.cursorline, wo.spell, wo.list = false, false, false, false, false
  wo.signcolumn, wo.foldcolumn, wo.statuscolumn = "no", "0", ""
  wo.winfixbuf = false
end

--- Show the drawer for `root` (default: this project), starting the agent if needed.
function M.open(root, opts)
  opts = opts or {}
  root = root or M.root()
  local a = new(root)
  if not alive(a) then start(a, opts) end
  if vim.t.cockpit_watch == root and not opts.float then
    return M.watch(root, { insert = opts.insert })
  end
  if visible(a) and not a.split then
    vim.api.nvim_set_current_win(a.win)
  else
    a.return_win = vim.api.nvim_get_current_win()
    a.win = vim.api.nvim_open_win(a.buf, true, win_config(a))
    a.split = false
    term_window(a.win, true)
  end
  if opts.insert ~= false then type_here(a.win) end
  return a
end

function M.hide(root)
  local a = root and M.agents[root] or M.get()
  if not visible(a) or a.split then
    -- Called from a drawer of another project: hide whatever drawer has focus.
    for _, o in pairs(M.agents) do
      if visible(o) and not o.split and vim.api.nvim_get_current_win() == o.win then a = o end
    end
  end
  if not visible(a) or a.split then return end
  vim.api.nvim_win_hide(a.win)
  a.win = nil
  if a.return_win and vim.api.nvim_win_is_valid(a.return_win) then
    vim.api.nvim_set_current_win(a.return_win)
  end
  vim.cmd.stopinsert()
end

function M.toggle()
  if vim.t.cockpit_watch then return M.watch_toggle() end
  for _, o in pairs(M.agents) do
    if visible(o) and not o.split and vim.api.nvim_get_current_win() == o.win then return M.hide(o.root) end
  end
  M.open()
end

function M.zoom()
  local a = M.get()
  if not visible(a) then return end
  if a.split then
    -- Watch layout: agent takes the whole width, or goes back to its share.
    if a.zoom_width then
      vim.api.nvim_win_set_width(a.win, a.zoom_width)
      a.zoom_width = nil
    elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
      a.zoom_width = vim.api.nvim_win_get_width(a.win)
      vim.api.nvim_win_set_width(a.win, vim.o.columns)
    end
    return
  end
  a.zoom = not a.zoom
  vim.api.nvim_win_set_config(a.win, win_config(a))
end

function M.restart(fresh, session)
  local a = M.get()
  local watching = vim.t.cockpit_watch
  if a and alive(a) then vim.fn.jobstop(a.job) end
  if a and visible(a) then
    if a.split then
      local old = a.buf
      a.job = nil
      start(a, { fresh = fresh, session = session })
      vim.api.nvim_win_set_buf(a.win, a.buf)
      term_window(a.win)
      pcall(vim.api.nvim_buf_delete, old, { force = true })
      vim.api.nvim_set_current_win(a.win)
      vim.cmd.startinsert()
      return
    end
    vim.api.nvim_win_close(a.win, true)
  end
  if a then a.win, a.job = nil, nil end
  if watching then
    local root = M.root()
    start(new(root), { fresh = fresh, session = session })
    return M.watch(root)
  end
  M.open(nil, { fresh = fresh, session = session })
end

---------------------------------------------------------------------------
-- Watch layout (SPC a w): agent on the left, live diff on the right, in
-- this project's tab. For prompting and watching rather than editing.
-- Under 120 columns there's room for one: Alt+a flips between them.
---------------------------------------------------------------------------

function M.watch(root, opts)
  opts = opts or {}
  root = root or M.root()
  local a = new(root)
  if not alive(a) then start(a, opts) end
  if visible(a) and not a.split then vim.api.nvim_win_hide(a.win); a.win = nil end
  vim.t.cockpit_watch = root
  -- Already laid out in this tab: just focus the agent.
  if visible(a) and a.split and vim.api.nvim_win_get_tabpage(a.win) == vim.api.nvim_get_current_tabpage() then
    vim.api.nvim_set_current_win(a.win)
    if opts.insert ~= false then type_here(a.win) end
    return a
  end
  pcall(vim.cmd, "silent! only")
  local diff = require("config.livediff").open(root)
  vim.t.cockpit_diff = diff
  if vim.o.columns >= M.narrow then
    vim.cmd("leftabove vsplit")
    vim.api.nvim_win_set_width(0, math.floor(vim.o.columns * (vim.g.agent_watch_width or 0.45)))
  end
  vim.api.nvim_win_set_buf(0, a.buf)
  a.win, a.split, a.zoom_width = vim.api.nvim_get_current_win(), true, nil
  term_window(a.win)
  if opts.insert ~= false then type_here(a.win) end
  return a
end

--- Alt+a in a watch tab: hop between agent and diff.
function M.watch_toggle()
  local root = vim.t.cockpit_watch
  local a = M.agents[root]
  local here = vim.api.nvim_get_current_win()
  if not (visible(a) and a.split and vim.api.nvim_win_get_tabpage(a.win) == vim.api.nvim_get_current_tabpage()) then
    return M.watch(root)
  end
  if here ~= a.win then
    vim.api.nvim_set_current_win(a.win)
    return vim.cmd.startinsert()
  end
  vim.cmd.stopinsert()
  local others = vim.tbl_filter(function(w)
    return w ~= a.win and vim.api.nvim_win_get_config(w).relative == ""
  end, vim.api.nvim_tabpage_list_wins(0))
  if #others > 0 then
    vim.api.nvim_set_current_win(others[1])
  else -- narrow: one window, swap what it shows
    local diff = vim.t.cockpit_diff
    if not (diff and vim.api.nvim_buf_is_valid(diff)) then diff = require("config.livediff").open(root) end
    vim.api.nvim_win_set_buf(a.win, diff)
    a.win = nil
  end
end

--- Leave the watch layout (back to code + drawer).
function M.unwatch()
  local root = vim.t.cockpit_watch
  if not root then return end
  vim.t.cockpit_watch = nil
  local a = M.agents[root]
  if visible(a) and a.split then
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.api.nvim_win_hide(a.win)
    else
      local diff = vim.t.cockpit_diff
      if diff and vim.api.nvim_buf_is_valid(diff) then vim.api.nvim_win_set_buf(a.win, diff) end
    end
    a.win, a.split = nil, false
  end
  vim.cmd.stopinsert()
end

function M.watch_toggle_layout()
  if vim.t.cockpit_watch then M.unwatch() else M.watch() end
end

-- Re-fit open drawers when the terminal is resized (laptop <-> monitor).
vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("agent_drawer", { clear = true }),
  callback = function()
    for _, a in pairs(M.agents) do
      if visible(a) and not a.split then vim.api.nvim_win_set_config(a.win, win_config(a)) end
    end
  end,
})

---------------------------------------------------------------------------
-- Sending context
---------------------------------------------------------------------------

-- Paste text into the agent's input (bracketed paste: no Enter is sent, and
-- multi-line text stays one message). Waits for a fresh agent to settle.
function M.send(text, root)
  local a = M.agents[root or M.root()]
  if not alive(a) then a = M.open(root, { insert = false }); M.hide(a.root) end
  -- Ready = the agent has drawn its UI and gone quiet. With pi's cockpit
  -- extension we also wait for its first state report (its TUI is up by
  -- then); text sent earlier would land in the bare tty and echo as junk.
  local function ready()
    if not a.last_output or now() - a.last_output < 300 then return false end
    if read_state_file(a) then return true end
    return now() - a.started > 2500
  end
  local function go()
    vim.fn.chansend(a.job, "\27[200~" .. text .. "\27[201~")
    M.open(a.root)
  end
  if ready() then return go() end
  local tries = 0
  local function wait()
    tries = tries + 1
    if ready() or tries > 100 then go() else vim.defer_fn(wait, 100) end
  end
  wait()
end

local function rel(path, root)
  root = root or M.root()
  if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
  return vim.fn.fnamemodify(path, ":~")
end

local function fence(lines, ft)
  local ticks = "```"
  for _, l in ipairs(lines) do
    while l:find(ticks, 1, true) do ticks = ticks .. "`" end
  end
  return ticks .. (ft or "") .. "\n" .. table.concat(lines, "\n") .. "\n" .. ticks .. "\n"
end

--- Text for a range of the current buffer: "path:12-20" + fenced code.
function M.format_range(buf, l1, l2)
  local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  local where = rel(vim.api.nvim_buf_get_name(buf)) .. ":" .. (l1 == l2 and l1 or (l1 .. "-" .. l2))
  return where .. "\n" .. fence(lines, vim.bo[buf].filetype) .. "\n"
end

function M.send_selection()
  local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
  if l1 > l2 then l1, l2 = l2, l1 end
  vim.cmd("normal! \27")
  M.send(M.format_range(0, l1, l2))
end

function M.send_file()
  M.send("@" .. rel(vim.api.nvim_buf_get_name(0)) .. " ")
end

function M.format_diagnostics(buf)
  local name = rel(vim.api.nvim_buf_get_name(buf))
  local sev = { "error", "warning", "info", "hint" }
  local out = {}
  local diags = vim.diagnostic.get(buf)
  table.sort(diags, function(x, y) return x.lnum < y.lnum end)
  for _, d in ipairs(diags) do
    out[#out + 1] = ("%s:%d: %s: %s"):format(name, d.lnum + 1, sev[d.severity] or "?", (d.message:gsub("\n", " ")))
  end
  return out
end

function M.send_diagnostics()
  local out = M.format_diagnostics(0)
  if #out == 0 then return vim.notify("No errors in this file") end
  M.send("Fix these:\n" .. table.concat(out, "\n") .. "\n")
end

function M.send_hunk()
  local buf = vim.api.nvim_get_current_buf()
  local ok, gs = pcall(require, "gitsigns")
  local hunks = ok and gs.get_hunks and gs.get_hunks(buf) or nil
  local lnum = vim.fn.line(".")
  for _, h in ipairs(hunks or {}) do
    local s = h.added.start
    local e = s + math.max(h.added.count, 1) - 1
    if lnum >= s and lnum <= e then
      local where = rel(vim.api.nvim_buf_get_name(buf)) .. ":" .. s .. (e > s and ("-" .. e) or "")
      return M.send(where .. "\n" .. fence(h.lines, "diff") .. "\n")
    end
  end
  vim.notify("No git change under the cursor")
end

---------------------------------------------------------------------------
-- Following the agent's changes
---------------------------------------------------------------------------

function M.jump(step)
  local a = M.get() or { root = M.root() }
  local files = a.job and M.files(a) or git_changed(a.root)
  files = vim.tbl_filter(function(f) return vim.fn.filereadable(f) == 1 end, files)
  if #files == 0 then return vim.notify("The agent hasn't changed any files") end
  local cur = vim.api.nvim_buf_get_name(0)
  local idx = 0
  for i, f in ipairs(files) do if f == cur then idx = i end end
  local nxt = ((idx - 1 + step) % #files) + 1
  if idx == 0 and step < 0 then nxt = #files end
  local sidebar = require("config.sidebar")
  sidebar.main_window_do("edit " .. vim.fn.fnameescape(files[nxt]))
  vim.notify(("%d/%d  %s"):format(nxt, #files, rel(files[nxt], a.root)))
end

function M.quickfix()
  local a = M.get() or { root = M.root() }
  local items = {}
  for _, f in ipairs(a.job and M.files(a) or git_changed(a.root)) do
    items[#items + 1] = { filename = f, lnum = 1, text = "changed by agent" }
  end
  vim.fn.setqflist({}, " ", { title = "Agent changes: " .. short(a.root), items = items })
  vim.cmd("copen")
end

---------------------------------------------------------------------------
-- Prompting without leaving the diff, and pi's saved sessions
---------------------------------------------------------------------------

--- SPC a i: type a prompt in a small box; Enter sends it (and submits).
function M.prompt()
  local root = M.root()
  vim.ui.input({ prompt = ("π %s: "):format(short(root)) }, function(text)
    if not text or text == "" then return end
    local a = M.agents[root]
    if not alive(a) then
      if vim.t.cockpit_watch then M.watch(root, { insert = false }) else M.open(root, { insert = false }); M.hide(root) end
      a = M.agents[root]
    end
    local tries = 0
    local function go()
      tries = tries + 1
      local ready = a.last_output and now() - a.last_output > 300 and (read_state_file(a) or now() - a.started > 2500)
      if not ready and tries < 100 then return vim.defer_fn(go, 100) end
      vim.fn.chansend(a.job, "\27[200~" .. text .. "\27[201~")
      vim.defer_fn(function() vim.fn.chansend(a.job, "\r") end, 50)
    end
    go()
  end)
end

local function pi_dir()
  return vim.env.PI_CODING_AGENT_DIR or vim.fn.expand("~/.pi/agent")
end

--- pi's saved conversations for a project, newest first:
--- { path, time, name, title, messages }.
function M.sessions(root)
  root = root or M.root()
  local dir = ("%s/sessions/--%s--"):format(pi_dir(), (root:gsub("^[/\\]", ""):gsub("[/\\:]", "-")))
  local out = {}
  for _, path in ipairs(vim.fn.glob(dir .. "/*.jsonl", false, true)) do
    local st = uv.fs_stat(path)
    local item = { path = path, time = st and st.mtime.sec or 0, messages = 0 }
    local n = 0
    for line in io.lines(path) do
      n = n + 1
      if n > 5000 then break end
      local ok, e = pcall(vim.json.decode, line)
      if ok and type(e) == "table" then
        if e.type == "session_info" and e.name then item.name = e.name end
        if e.type == "message" and type(e.message) == "table" then
          if e.message.role == "user" then
            item.messages = item.messages + 1
            if not item.title then
              local c = e.message.content
              local t = type(c) == "string" and c or (type(c) == "table" and c[1] and c[1].text) or ""
              -- Skip a leading "path:lines" + code fence: show the question.
              local lines = vim.split(t, "\n", { plain = true })
              local pick = lines[1]
              for i = #lines, 1, -1 do
                if lines[i]:match("%S") and not lines[i]:match("^```") then pick = lines[i]; break end
              end
              item.title = vim.trim(pick or "")
            end
          end
        end
      end
    end
    out[#out + 1] = item
  end
  table.sort(out, function(x, y) return x.time > y.time end)
  return out
end

--- SPC a p: reopen one of this project's earlier conversations.
function M.pick_session()
  local root = M.root()
  local items = M.sessions(root)
  if #items == 0 then return vim.notify("No saved conversations for " .. short(root)) end
  local a = M.agents[root]
  local current = a and a.ext and a.ext.session
  vim.ui.select(items, {
    prompt = "Conversations in " .. short(root),
    format_item = function(it)
      return ("%s %s  %-48s %d prompts"):format(it.path == current and "●" or " ",
        os.date("%b %d %H:%M", it.time), (it.name or it.title or "(empty)"):sub(1, 48), it.messages)
    end,
  }, function(it)
    if it then M.restart(false, it.path) end
  end)
end

--- All agents, for the picker and the workspace list.
function M.list()
  local out = {}
  for root, a in pairs(M.agents) do
    out[#out + 1] = { root = root, state = M.state(a) or "idle" }
  end
  table.sort(out, function(x, y) return x.root < y.root end)
  return out
end

function M.pick()
  local items = M.list()
  if #items == 0 then return vim.notify("No agents yet: Alt+a starts one for this project") end
  vim.ui.select(items, {
    prompt = "Agents",
    format_item = function(it) return ("%-24s %s"):format(short(it.root), labels[it.state] or it.state) end,
  }, function(it)
    if not it then return end
    require("config.workspaces").open(it.root, { files = false })
    M.open(it.root)
  end)
end

--- Saved sessions: mark which projects had an agent, to resume on Alt+a.
function M.mark_resume(root, session)
  local a = new(root)
  if not a.job then
    a.resume = true
    a.resume_session = type(session) == "string" and session or nil
  end
  ensure_tick()
end

--- root -> pi session file (or true) for every project with an agent.
function M.roots_with_agents()
  local out = {}
  for root, a in pairs(M.agents) do
    if a.job or a.resume then
      local ext = a.job and read_state_file(a)
      out[root] = (ext and ext.session) or a.resume_session or true
    end
  end
  return out
end

return M
