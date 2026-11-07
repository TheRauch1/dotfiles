-- Agent drawer (config/agent.lua) and project workspaces (config/workspaces.lua),
-- with a fake agent: a shell script that records what it's sent.

local agent = require("config.agent")
local orig_cwd = vim.fn.getcwd()
local ws = require("config.workspaces")

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- A git repo with one file, and a fake agent that prints a prompt and then
-- copies every byte it gets to $root/.received.
local function project(name)
  local root = vim.fn.tempname() .. "/" .. (name or "proj")
  vim.fn.mkdir(root, "p")
  root = vim.fn.resolve(root)
  write(root .. "/main.py", "def add(a, b):\n    return a + b\n\nprint(add(1, 2))\n")
  write(root .. "/util.py", "X = 1\n")
  vim.fn.system({ "git", "-C", root, "init", "-q" })
  write(root .. "/fake-agent.sh", "#!/bin/sh\necho \"$@\" > \"$PWD/.args\"\nprintf 'fake agent ready> '\nstty raw -echo\nexec cat > \"$PWD/.received\"\n")
  vim.fn.setfperm(root .. "/fake-agent.sh", "rwxr-xr-x")
  vim.g.agent_cmd = { root .. "/fake-agent.sh" }
  vim.g.agent_resume_args = {}
  return root
end

local function reset()
  for _, a in pairs(agent.agents) do
    if a.job then pcall(vim.fn.jobstop, a.job) end
    if a.win and vim.api.nvim_win_is_valid(a.win) then pcall(vim.api.nvim_win_close, a.win, true) end
    if a.state_file then os.remove(a.state_file) end
  end
  agent.agents = {}
  vim.g.agent_autopeek = nil
  vim.g.cockpit_layout = "code"
  vim.t.cockpit_watch = nil
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  vim.o.columns = 200
  vim.o.lines = 50
  vim.cmd("tcd " .. vim.fn.fnameescape(orig_cwd))
  vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
end

local function edit(root, file)
  vim.cmd("tcd " .. vim.fn.fnameescape(root))
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. file))
end

local function floating(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

local function wait_output(a)
  T.ok(T.wait(function() return a.last_output ~= nil end, 3000), "agent printed nothing")
end

return {
  toggle_shows_and_hides_keeping_agent = function()
    reset()
    local root = project()
    edit(root, "main.py")
    local code = vim.api.nvim_get_current_win()
    agent.toggle()
    local a = agent.agents[root]
    T.ok(a and a.job, "agent started")
    T.ok(floating(vim.api.nvim_get_current_win()), "drawer is a float")
    T.eq(vim.api.nvim_get_current_buf(), a.buf)
    wait_output(a)
    agent.toggle()
    T.eq(vim.api.nvim_get_current_win(), code)
    T.eq(vim.fn.jobwait({ a.job }, 0)[1], -1, "still running after hiding")
    local buf = a.buf
    agent.toggle()
    T.eq(vim.api.nvim_get_current_buf(), buf, "same terminal comes back")
    agent.hide()
    reset()
  end,

  narrow_screen_is_fullscreen = function()
    reset()
    local root = project()
    edit(root, "main.py")
    vim.o.columns = 100
    local a = agent.open()
    local cfg = vim.api.nvim_win_get_config(a.win)
    T.eq(cfg.width, 100)
    T.eq(cfg.row, 0)
    agent.hide()
    vim.o.columns = 200
    a = agent.open()
    T.ok(vim.api.nvim_win_get_config(a.win).width < 200, "wide screen: float with a margin")
    agent.zoom()
    T.eq(vim.api.nvim_win_get_config(a.win).width, 200, "Alt+z zooms")
    agent.hide()
    reset()
  end,

  one_agent_per_project = function()
    reset()
    local r1, r2 = project("one"), project("two")
    vim.g.agent_cmd = { r1 .. "/fake-agent.sh" }
    edit(r1, "main.py")
    agent.open(); agent.hide()
    vim.cmd("tabnew")
    edit(r2, "main.py")
    agent.open(); agent.hide()
    T.ok(agent.agents[r1] and agent.agents[r2], "two agents")
    T.ok(agent.agents[r1].buf ~= agent.agents[r2].buf, "separate terminals")
    T.eq(#agent.list(), 2)
    reset()
  end,

  state_from_extension_file = function()
    reset()
    local root = project()
    edit(root, "main.py")
    local a = agent.open()
    agent.hide()
    write(a.state_file, vim.json.encode({ state = "working", files = { "main.py" } }))
    T.eq(agent.state(a), "working")
    T.ok(agent.statusline():find("working", 1, true), agent.statusline())
    write(a.state_file, vim.json.encode({ state = "waiting", files = { "main.py", root .. "/util.py" } }))
    -- mtime has 1 ns resolution on most filesystems, but make sure it moved
    vim.uv.fs_utime(a.state_file, os.time() + 5, os.time() + 5)
    T.eq(agent.state(a), "waiting")
    T.ok(agent.statusline():find("your turn", 1, true), agent.statusline())
    T.eq(agent.files(a), { root .. "/main.py", root .. "/util.py" })
    T.eq(agent.mark(root), "●")
    reset()
  end,

  notifies_when_agent_starts_waiting = function()
    reset()
    local root = project()
    edit(root, "main.py")
    local a = agent.open()
    agent.hide()
    local n = T.notifications()
    write(a.state_file, vim.json.encode({ state = "working", files = {} }))
    T.ok(T.wait(function() return a.last_state == "working" end), "saw working")
    write(a.state_file, vim.json.encode({ state = "waiting", files = {} }))
    vim.uv.fs_utime(a.state_file, os.time() + 5, os.time() + 5)
    T.ok(T.wait(function() return #n > 0 end), "notified")
    T.ok(n[1].msg:find("waiting for you", 1, true), n[1].msg)
    reset()
  end,

  send_selection_pastes_with_location = function()
    reset()
    local root = project()
    edit(root, "main.py")
    vim.bo.filetype = "python"
    local text = agent.format_range(0, 1, 2)
    T.eq(text, "main.py:1-2\n```python\ndef add(a, b):\n    return a + b\n```\n\n")
    agent.send(text)
    local a = agent.agents[root]
    local want = "\27[200~" .. text .. "\27[201~"
    T.ok(T.wait(function() return read(root .. "/.received") == want end, 4000),
      vim.inspect(read(root .. "/.received")))
    T.eq(vim.api.nvim_get_current_win(), a.win, "drawer opens to add a question")
    agent.hide()
    reset()
  end,

  send_file_and_diagnostics = function()
    reset()
    local root = project()
    edit(root, "main.py")
    local ns = vim.api.nvim_create_namespace("test_agent")
    vim.diagnostic.set(ns, 0, {
      { lnum = 3, col = 0, severity = vim.diagnostic.severity.WARN, message = "unused\nresult" },
      { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "bad def" },
    })
    T.eq(agent.format_diagnostics(0), { "main.py:1: error: bad def", "main.py:4: warning: unused result" })
    agent.send_file()
    T.ok(T.wait(function() return read(root .. "/.received") == "\27[200~@main.py \27[201~" end, 4000),
      vim.inspect(read(root .. "/.received")))
    agent.hide()
    reset()
  end,

  jump_walks_changed_files = function()
    reset()
    local root = project()
    edit(root, "main.py")
    local a = agent.open()
    agent.hide()
    write(a.state_file, vim.json.encode({ state = "waiting", files = { "util.py", "main.py" } }))
    agent.jump(1) -- from main.py (2nd) wraps to the 1st
    T.eq(vim.api.nvim_buf_get_name(0), root .. "/util.py")
    vim.cmd("edit " .. root .. "/util.py")
    agent.jump(1)
    T.eq(vim.api.nvim_buf_get_name(0), root .. "/main.py")
    agent.jump(-1)
    T.eq(vim.api.nvim_buf_get_name(0), root .. "/util.py")
    reset()
  end,

  jump_without_agent_uses_git = function()
    reset()
    local root = project()
    edit(root, "main.py")
    agent.jump(1)
    -- untracked files count as changed: fake-agent.sh, main.py, util.py
    T.ok(vim.api.nvim_buf_get_name(0):match("^" .. vim.pesc(root)), vim.api.nvim_buf_get_name(0))
    reset()
  end,

  watch_layout_puts_agent_beside_diff = function()
    reset()
    local root = project()
    edit(root, "main.py")
    local a = agent.watch()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    T.eq(#wins, 2, "agent + diff")
    T.eq(a.split, true)
    T.eq(vim.api.nvim_get_current_buf(), a.buf)
    T.ok(not floating(a.win), "a real split, not a float")
    local other = wins[1] == a.win and wins[2] or wins[1]
    T.ok(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(other)):match("^livediff://"), "diff on the other side")
    -- Alt+a hops between them
    agent.toggle()
    T.eq(vim.api.nvim_get_current_win(), other)
    agent.toggle()
    T.eq(vim.api.nvim_get_current_win(), a.win)
    -- leaving the layout keeps the agent running
    agent.unwatch()
    T.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
    T.eq(vim.fn.jobwait({ a.job }, 0)[1], -1)
    reset()
  end,

  watch_layout_narrow_flips_one_window = function()
    reset()
    local root = project()
    edit(root, "main.py")
    vim.o.columns = 100
    local a = agent.watch()
    T.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
    T.eq(vim.api.nvim_get_current_buf(), a.buf)
    agent.toggle()
    T.ok(vim.api.nvim_buf_get_name(0):match("^livediff://"), vim.api.nvim_buf_get_name(0))
    agent.toggle()
    T.eq(vim.api.nvim_get_current_buf(), a.buf)
    reset()
  end,

  new_project_opens_in_watch_layout = function()
    reset()
    local root = project("vibes")
    vim.g.cockpit_layout = nil
    vim.cmd("enew")
    ws.open(root)
    T.eq(vim.t.cockpit_watch, root)
    T.ok(agent.agents[root] and agent.agents[root].split, "agent beside the diff")
    T.eq(vim.o.showtabline, 2)
    reset()
  end,

  prompt_sends_and_submits = function()
    reset()
    local root = project()
    edit(root, "main.py")
    local input = vim.ui.input
    vim.ui.input = function(_, cb) cb("add a CLI flag") end
    agent.prompt()
    vim.ui.input = input
    T.ok(T.wait(function() return read(root .. "/.received") == "\27[200~add a CLI flag\27[201~\r" end, 5000),
      vim.inspect(read(root .. "/.received")))
    reset()
  end,

  sessions_lists_pi_conversations = function()
    reset()
    local root = project()
    local dir = vim.fn.tempname()
    vim.env.PI_CODING_AGENT_DIR = dir
    local sdir = ("%s/sessions/--%s--"):format(dir, (root:gsub("^/", ""):gsub("/", "-")))
    local function msg(text) return vim.json.encode({ type = "message", message = { role = "user", content = { { type = "text", text = text } } } }) end
    write(sdir .. "/old.jsonl", table.concat({ vim.json.encode({ type = "session" }), msg("first idea") }, "\n") .. "\n")
    write(sdir .. "/new.jsonl", table.concat({ vim.json.encode({ type = "session" }),
      msg("main.py:1-2\n```python\nx\n```\nwhy is this slow?"), msg("thanks"),
      vim.json.encode({ type = "session_info", name = "Speed up add" }) }, "\n") .. "\n")
    vim.uv.fs_utime(sdir .. "/old.jsonl", 1000, 1000)
    local list = agent.sessions(root)
    vim.env.PI_CODING_AGENT_DIR = nil
    T.eq(#list, 2)
    T.eq(list[1].path, sdir .. "/new.jsonl")
    T.eq(list[1].title, "why is this slow?")
    T.eq(list[1].name, "Speed up add")
    T.eq(list[1].messages, 2)
    T.eq(list[2].title, "first idea")
    reset()
  end,

  restore_brings_back_watch_layout_and_session = function()
    reset()
    local root = project("api")
    local session = root .. "/s.jsonl"
    write(session, "")
    ws.restore({ current = 1, tabs = { { cwd = root, agent = true, session = session, layout = "watch" } } })
    local a = agent.agents[root]
    T.ok(a and a.job, "agent started for the watch tab")
    T.eq(vim.t.cockpit_watch, root)
    T.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    T.ok(T.wait(function() return read(root .. "/.args") ~= nil end), "agent started")
    T.eq(read(root .. "/.args"), "--session " .. session .. "\n")
    local snap = ws.snapshot()
    T.eq(snap.tabs[1].layout, "watch")
    reset()
  end,

  ide_state_path_matches_shell_scripts = function()
    -- cockpit/ide/lib.sh and agent.lua must name a project's state file alike.
    local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
    local root = "/home/me/dev/my app+x"
    local sh = vim.fn.system({ "bash", "-c", ". '" .. repo .. "/cockpit/ide/lib.sh'; state_file \"$1\"", "_", root })
    local want = (vim.env.XDG_STATE_HOME or vim.fn.expand("~/.local/state")) .. "/cockpit-ide/"
      .. root:gsub("[^%w%-_.]", "%%") .. ".json"
    T.eq(sh, want)
  end,

  workspaces_open_reuses_tabs = function()
    reset()
    local r1, r2 = project("api"), project("web")
    vim.cmd("enew")
    ws.open(r1, { files = false })
    T.eq(vim.fn.tabpagenr("$"), 1, "empty tab reused")
    vim.cmd("edit " .. r1 .. "/main.py")
    ws.open(r2, { files = false })
    T.eq(vim.fn.tabpagenr("$"), 2)
    T.eq(vim.fn.getcwd(), r2)
    ws.open(r1, { files = false })
    T.eq(vim.fn.tabpagenr(), 1, "existing workspace selected")
    local line = ws.tabline()
    T.ok(line:find("api", 1, true) and line:find("web", 1, true), line)
    reset()
  end,

  session_roundtrip_restores_projects_and_agents = function()
    reset()
    local r1, r2 = project("api"), project("web")
    edit(r1, "main.py")
    vim.api.nvim_win_set_cursor(0, { 4, 2 })
    agent.open(); agent.hide()
    vim.cmd("tabnew")
    edit(r2, "util.py")
    local snap = ws.snapshot()
    T.eq(#snap.tabs, 2)
    T.eq(snap.current, 2)
    T.eq(snap.tabs[1], { cwd = r1, file = r1 .. "/main.py", cursor = { 4, 2 }, agent = true })
    T.eq(snap.tabs[2].agent, nil)
    -- "Reboot": everything gone, then restore from the snapshot.
    reset()
    vim.cmd("silent! %bwipeout!")
    T.ok(ws.restore(vim.json.decode(vim.json.encode(snap))))
    T.eq(vim.fn.tabpagenr("$"), 2)
    T.eq(vim.fn.tabpagenr(), 2)
    T.eq(vim.fn.getcwd(-1, 1), r1)
    T.eq(vim.fn.getcwd(-1, 2), r2)
    vim.cmd("tabnext 1")
    T.eq(vim.api.nvim_buf_get_name(0), r1 .. "/main.py")
    T.eq(vim.api.nvim_win_get_cursor(0), { 4, 2 })
    T.eq(agent.state(agent.agents[r1]), "resume", "agent waits to be resumed")
    T.ok(agent.statusline():find("resume", 1, true), agent.statusline())
    reset()
  end,

  save_writes_session_file = function()
    reset()
    local root = project()
    local old = vim.g.cockpit_restore
    vim.g.cockpit_restore = 1
    ws.name = "test-" .. vim.fn.getpid()
    edit(root, "main.py")
    ws.save()
    local data = vim.json.decode(read(ws.session_file()))
    T.eq(data.tabs[1].file, root .. "/main.py")
    os.remove(ws.session_file())
    vim.g.cockpit_restore = old
    ws.name = "default"
    reset()
  end,

  ide_workspace_links_repos = function()
    -- A .cockpit file becomes a folder of links, one per repo, plus a note
    -- for the agent; repo_of finds each repo through its link.
    local a, b = project("api"), project("web")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    write(tmp .. "/acme.cockpit", ("# test\napi %s\n%s   # name from folder\nagent claude\n"):format(a, b))
    local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
    local out = vim.system({ repo .. "/cockpit/ide/workspace.sh", tmp .. "/acme.cockpit" },
      { env = { IDE_WORKSPACES = tmp .. "/ws" }, text = true }):wait()
    T.eq(out.code, 0, out.stderr)
    local ws_dir = vim.trim(out.stdout)
    T.eq(ws_dir, tmp .. "/ws/acme")
    T.eq(vim.uv.fs_realpath(ws_dir .. "/api"), vim.uv.fs_realpath(a))
    T.eq(vim.uv.fs_realpath(ws_dir .. "/" .. vim.fs.basename(b)), vim.uv.fs_realpath(b))
    T.eq(vim.trim(read(ws_dir .. "/.cockpit-agent")), "claude")
    T.ok(read(ws_dir .. "/AGENTS.md"):find("separate git", 1, true))
    T.eq(#ws.workspace_repos(ws_dir), 2)
    T.eq(ws.repo_of(ws_dir .. "/api/main.py"), ws_dir .. "/api")
    T.eq(ws.repo_of(ws_dir), nil)
    -- SPC SPC / SPC / search every repo of the workspace, through the links.
    local util = require("config.util")
    local old = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(ws_dir))
    T.eq(util.workspace(), ws_dir)
    T.eq(util.search_scope(), { cwd = ws_dir, follow = true, name = "workspace acme" })
    vim.cmd("cd " .. vim.fn.fnameescape(a))
    T.eq(util.workspace(), nil)
    T.eq(util.search_scope().cwd, a)
    vim.cmd("cd " .. vim.fn.fnameescape(old))
    vim.fn.delete(tmp, "rf")
  end,
}
