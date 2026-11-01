-- GitHub pull requests, reviews and CI checks, driven by the gh CLI (uses
-- gh's login, nothing else to set up). A port of doom/gh.el: same buffers,
-- same keys. SPC g p opens the menu; ? in any gh buffer lists its keys.
--
-- Every gh call is asynchronous, so a slow connection never freezes Neovim.
-- Buffers with running CI checks refresh themselves until the checks finish.
local M = {}
local api = vim.api
local util = require("config.util")

M.refresh_interval = 15000
M.pr_list_limit = 50
M.run_list_limit = 30

local ns = api.nvim_create_namespace("gh")
local S = {} -- buf -> state { kind, repo, cwd, data, items, ... }

---------------------------------------------------------------------------
-- Running gh
---------------------------------------------------------------------------

local env = { GH_PROMPT_DISABLED = "1", GH_NO_UPDATE_NOTIFIER = "1", GH_PAGER = "cat",
  NO_COLOR = "1", CLICOLOR = "0", GH_FORCE_TTY = "" }

--- Run gh asynchronously; cb(ok, stdout, stderr) on the main loop.
function M.call(args, opts, cb)
  if vim.fn.executable("gh") ~= 1 then
    vim.notify("gh not found: install the GitHub CLI and run `gh auth login`", vim.log.levels.ERROR)
    return
  end
  opts = opts or {}
  local cmd = vim.list_extend({ "gh" }, args)
  if opts.repo then vim.list_extend(cmd, { "-R", opts.repo }) end
  vim.system(cmd, { cwd = opts.cwd, text = true, env = env, stdin = opts.input }, function(res)
    vim.schedule(function() cb(res.code == 0, res.stdout or "", vim.trim(res.stderr or "")) end)
  end)
end

local function decode(s)
  local ok, v = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and v or nil
end

local function err_line(stderr)
  local lines = vim.split(stderr, "\n", { trimempty = true })
  return lines[#lines] or "failed"
end

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------

local function iso_epoch(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, se = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  if y == "0001" then return nil end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se, isdst = false })
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date("!*t", now)))
  return t + offset
end

local function ago(s)
  local t = iso_epoch(s)
  if not t then return "" end
  local d = os.time() - t
  if d < 60 then return "now" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  if d < 86400 then return math.floor(d / 3600) .. "h" end
  if d < 86400 * 30 then return math.floor(d / 86400) .. "d" end
  if d < 86400 * 365 then return math.floor(d / 86400 / 30) .. "mo" end
  return math.floor(d / 86400 / 365) .. "y"
end

local function duration(from, to)
  local a, b = iso_epoch(from), iso_epoch(to)
  if not a then return "" end
  local d = (b or os.time()) - a
  if d < 0 then return "" end
  if d < 60 then return d .. "s" end
  if d < 3600 then return ("%dm%02ds"):format(math.floor(d / 60), d % 60) end
  return ("%dh%02dm"):format(math.floor(d / 3600), math.floor((d % 3600) / 60))
end

local function pad(s, n)
  s = s or ""
  local w = vim.fn.strdisplaywidth(s)
  if w > n then return vim.fn.strcharpart(s, 0, n - 1) .. "…" end
  return s .. string.rep(" ", n - w)
end

local function bucket(c)
  local status = (c.status or ""):upper()
  local result = (c.conclusion or c.state or ""):upper()
  if vim.tbl_contains({ "QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED" }, status) then return "pending" end
  if result == "SUCCESS" then return "pass" end
  if vim.tbl_contains({ "FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED" }, result) then return "fail" end
  if result == "CANCELLED" then return "cancel" end
  if vim.tbl_contains({ "SKIPPED", "NEUTRAL", "STALE" }, result) then return "skip" end
  return "pending"
end

local icons = {
  pass = { "✓", "DiagnosticOk" }, fail = { "✗", "DiagnosticError" }, pending = { "●", "DiagnosticWarn" },
  cancel = { "⊘", "Comment" }, skip = { "-", "Comment" },
}
local function icon(b) return icons[b] or icons.skip end

local function rollup(checks)
  if not checks or #checks == 0 then return nil end
  local seen = {}
  for _, c in ipairs(checks) do seen[bucket(c)] = true end
  for _, b in ipairs({ "fail", "pending", "cancel", "pass" }) do
    if seen[b] then return b end
  end
  return "skip"
end

local function counts(checks, chunks)
  local n = {}
  for _, c in ipairs(checks or {}) do local b = bucket(c); n[b] = (n[b] or 0) + 1 end
  for _, b in ipairs({ "pass", "fail", "pending", "cancel", "skip" }) do
    if n[b] then
      table.insert(chunks, { icon(b)[1] .. " " .. n[b] .. "  ", icon(b)[2] })
    end
  end
  return chunks
end

local function check_name(c)
  if c.context then return c.context end
  if c.workflowName and c.workflowName ~= "" then return c.workflowName .. " / " .. (c.name or "") end
  return c.name or "?"
end

local rank = { fail = 0, pending = 1, cancel = 2, pass = 3, skip = 4 }
local function sort_checks(checks)
  local out = vim.deepcopy(checks or {})
  table.sort(out, function(a, b)
    local ra, rb = rank[bucket(a)], rank[bucket(b)]
    if ra ~= rb then return ra < rb end
    return check_name(a) < check_name(b)
  end)
  return out
end

local function pending(checks)
  for _, c in ipairs(checks or {}) do
    if bucket(c) == "pending" then return true end
  end
  return false
end

--- (repo, run, job) from a GitHub Actions job URL.
local function job_url_parts(url)
  if not url then return nil end
  local repo, run = url:match("github%.com/([^/]+/[^/]+)/actions/runs/(%d+)")
  if not repo then return nil end
  return repo, run, url:match("/job/(%d+)")
end

local function repo_from_url(url)
  return url and url:match("github%.com/([^/]+/[^/]+)/") or nil
end

---------------------------------------------------------------------------
-- Buffers
---------------------------------------------------------------------------

local function builder()
  local b = { lines = {}, hls = {}, items = {} }
  function b:add(chunks, item)
    if type(chunks) == "string" then chunks = { { chunks } } end
    local line = ""
    for _, c in ipairs(chunks) do
      local text = (c[1] or ""):gsub("\n", " ")
      if c[2] and #text > 0 then table.insert(self.hls, { #self.lines, #line, #line + #text, c[2] }) end
      line = line .. text
    end
    table.insert(self.lines, line)
    if item then self.items[#self.lines] = item end
  end
  function b:text(text, indent, hl)
    text = (text or ""):gsub("\r", "")
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      self:add({ { (indent or "") .. l, hl } })
    end
  end
  return b
end

local function draw(buf, b)
  if not api.nvim_buf_is_valid(buf) then return end
  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, b.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(b.hls) do
    pcall(api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  S[buf].items = b.items
  for win, view in pairs(views) do
    if api.nvim_win_is_valid(win) then api.nvim_win_call(win, function() vim.fn.winrestview(view) end) end
  end
end

local function loading(buf, what)
  local b = builder()
  b:add({ { "Loading " .. what .. "…", "Comment" } })
  draw(buf, b)
end

local function show_error(buf, stderr, hint)
  local b = builder()
  b:add({ { "gh: " .. err_line(stderr), "DiagnosticError" } })
  b:add("")
  b:text(stderr, "  ", "Comment")
  if hint then b:add(""); b:add({ { hint, "Comment" } }) end
  b:add({ { "gr tries again, q goes back.", "Comment" } })
  draw(buf, b)
end

local function stop_timer(st)
  if st and st.timer then st.timer:stop(); st.timer:close(); st.timer = nil end
end

--- Find or create a gh buffer and show it in the main window.
local function open_buffer(name, kind, st)
  local buf = vim.fn.bufnr("^" .. vim.pesc(name) .. "$")
  if buf == -1 or not S[buf] then
    buf = api.nvim_create_buf(true, true)
    api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "gh"
    vim.bo[buf].modifiable = false
    api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function() stop_timer(S[buf]); S[buf] = nil end })
  end
  stop_timer(S[buf])
  S[buf] = vim.tbl_extend("force", { kind = kind, items = {} }, st)
  -- Don't open inside the sidebar.
  local win = api.nvim_get_current_win()
  if vim.bo[api.nvim_win_get_buf(win)].filetype == "neo-tree" then
    win = require("config.sidebar").main_window() or win
    api.nvim_set_current_win(win)
  end
  api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
  return buf
end

local function item_at(buf)
  local st = S[buf]
  if not st then return nil end
  return st.items[api.nvim_win_get_cursor(0)[1]]
end

--- Where gh runs: the repo of the current file, or anywhere if OWNER/REPO is given.
local function context(repo)
  local root = vim.fs.root(util.dir(), ".git")
  if repo and repo ~= "" then return { repo = repo, cwd = root or vim.fn.getcwd() } end
  local cur = S[api.nvim_get_current_buf()]
  if cur then return { repo = cur.repo, cwd = cur.cwd } end
  if not root then
    vim.notify("Not in a git repo (SPC g p R picks another repo)", vim.log.levels.WARN)
    return nil
  end
  return { cwd = root }
end

local function repo_name(st)
  return st.repo or vim.fs.basename(st.cwd or vim.fn.getcwd())
end

local function copy_url(url)
  if url then util.copy(url) else vim.notify("No URL here") end
end

local refresh -- forward declaration

-- Re-fetch every few seconds while CI runs; say when it finishes.
local function watch(buf, is_pending, done_msg)
  local st = S[buf]
  if not st then return end
  if is_pending then
    st.watching = true
    if not st.timer then
      st.timer = vim.uv.new_timer()
      st.timer:start(M.refresh_interval, M.refresh_interval, vim.schedule_wrap(function()
        if not api.nvim_buf_is_valid(buf) then return stop_timer(st) end
        if #vim.fn.win_findbuf(buf) > 0 then refresh(buf) end
      end))
    end
  else
    if st.watching and done_msg then vim.notify(done_msg) end
    st.watching = false
    stop_timer(st)
  end
end

---------------------------------------------------------------------------
-- Common keys
---------------------------------------------------------------------------

local function keys(buf, list)
  for _, k in ipairs(list) do
    vim.keymap.set("n", k[1], k[2], { buffer = buf, desc = k[3], nowait = true, silent = true })
  end
end

local function common_keys(buf)
  keys(buf, {
    { "gr", function() refresh(buf) end, "Refresh" },
    { "q", function() Snacks.bufdelete({ buf = buf, wipe = true }) end, "Back" },
    { "?", function() require("which-key").show({ global = false }) end, "Keys in this buffer" },
  })
end

---------------------------------------------------------------------------
-- Pull request list
---------------------------------------------------------------------------

local pr_list_fields = "number,title,author,headRefName,isDraft,reviewDecision,statusCheckRollup,updatedAt,state,url"
local filters = {
  open = { label = "open", args = {} },
  mine = { label = "mine", args = { "--author", "@me" } },
  review = { label = "waiting for my review", args = { "--search", "review-requested:@me" } },
}

local function review_chunk(pr)
  if pr.isDraft then return { "draft    ", "Comment" } end
  local d = pr.reviewDecision
  if d == "APPROVED" then return { "approved ", "DiagnosticOk" } end
  if d == "CHANGES_REQUESTED" then return { "changes  ", "DiagnosticError" } end
  if d == "REVIEW_REQUIRED" then return { "review   ", "DiagnosticWarn" } end
  return { "         " }
end

local function insert_checks(b, checks, indent, pr)
  indent = indent or "  "
  local skipped = 0
  local width = 10
  for _, c in ipairs(checks) do width = math.max(width, math.min(60, vim.fn.strdisplaywidth(check_name(c)))) end
  for _, c in ipairs(sort_checks(checks)) do
    local bk = bucket(c)
    if bk == "skip" then
      skipped = skipped + 1
    else
      b:add({ { indent }, { icon(bk)[1] .. " ", icon(bk)[2] }, { pad(check_name(c), width) .. "  " },
        { duration(c.startedAt, c.completedAt), "Comment" } }, { type = "check", check = c, pr = pr })
    end
  end
  if skipped > 0 then b:add({ { indent .. ("- %d skipped"):format(skipped), "Comment" } }) end
end

local function pr_list_render(buf)
  local st = S[buf]
  local prs = st.data or {}
  local b = builder()
  b:add({ { "Pull requests", "Title" }, { "  " .. repo_name(st) }, { "  [" .. (st.search or filters[st.filter].label) .. "]", "Keyword" },
    { ("  %d"):format(#prs), "Comment" } })
  b:add({ { "RET open  TAB checks  f filter  / search  d diff  c checkout  o copy URL  gr refresh  q back  ? keys", "Comment" } })
  b:add("")
  if #prs == 0 then b:add({ { "  No pull requests.", "Comment" } }) end
  local aw, bw = 6, 6
  for _, pr in ipairs(prs) do
    aw = math.min(16, math.max(aw, #(pr.author and pr.author.login or "")))
    bw = math.min(24, math.max(bw, #(pr.headRefName or "")))
  end
  for _, pr in ipairs(prs) do
    local r = rollup(pr.statusCheckRollup)
    b:add({
      { ("#%-6d"):format(pr.number), "Special" },
      { (r and icon(r)[1] or " ") .. " ", r and icon(r)[2] or nil },
      review_chunk(pr),
      { pad(pr.author and pr.author.login or "", aw) .. " ", "Identifier" },
      { pad(pr.headRefName, bw) .. " ", "Constant" },
      { pad(ago(pr.updatedAt), 4) .. " ", "Comment" },
      { pr.title or "" },
    }, { type = "pr", pr = pr })
    if st.expanded and st.expanded[pr.number] then
      if pr.statusCheckRollup and #pr.statusCheckRollup > 0 then
        insert_checks(b, pr.statusCheckRollup, "         ", pr)
      else
        b:add({ { "         no checks", "Comment" } })
      end
    end
  end
  draw(buf, b)
end

local function pr_list_fetch(buf)
  local st = S[buf]
  local args = { "pr", "list", "-L", tostring(M.pr_list_limit), "--json", pr_list_fields }
  if st.search then
    vim.list_extend(args, { "--search", st.search })
  else
    vim.list_extend(args, filters[st.filter].args)
  end
  M.call(args, { repo = st.repo, cwd = st.cwd }, function(ok, out, err)
    if not S[buf] then return end
    if not ok then return show_error(buf, err) end
    st.data = decode(out) or {}
    pr_list_render(buf)
    watch(buf, (function()
      for _, pr in ipairs(st.data) do if pending(pr.statusCheckRollup) then return true end end
    end)() or false)
  end)
end

function M.pr_list(filter, repo)
  local ctx = context(repo)
  if not ctx then return end
  filter = filters[filter] and filter or "open"
  local name = ("gh://%s/pulls"):format(ctx.repo or vim.fs.basename(ctx.cwd))
  local buf = open_buffer(name, "pr_list", { repo = ctx.repo, cwd = ctx.cwd, filter = filter, expanded = {} })
  common_keys(buf)
  local function pr() local it = item_at(buf); return it and it.pr end
  keys(buf, {
    { "<cr>", function()
      local it = item_at(buf)
      if not it then return end
      if it.type == "check" then return M.log(it.check, S[buf]) end
      M.pr_view(it.pr.number, S[buf].repo, S[buf].cwd)
    end, "Open PR / log of check" },
    { "<tab>", function()
      local p = pr()
      if not p then return end
      S[buf].expanded[p.number] = not S[buf].expanded[p.number] or nil
      pr_list_render(buf)
    end, "Show / hide the PR's checks" },
    { "f", function()
      vim.ui.select({ "open", "mine", "review" }, { prompt = "Filter",
        format_item = function(f) return filters[f].label end }, function(f)
        if f then S[buf].filter = f; S[buf].search = nil; refresh(buf) end
      end)
    end, "Filter: open / mine / review requested" },
    { "/", function()
      vim.ui.input({ prompt = "Search PRs (e.g. label:bug author:me): ", default = S[buf].search or "" }, function(q)
        if q then S[buf].search = q ~= "" and q or nil; refresh(buf) end
      end)
    end, "Search" },
    { "d", function() local p = pr(); if p then M.pr_diff(p.number, S[buf]) end end, "Diff" },
    { "c", function() local p = pr(); if p then M.pr_checkout(p.number, S[buf]) end end, "Check out branch" },
    { "o", function() local p = pr(); copy_url(p and p.url) end, "Copy URL" },
    { "Y", function() local p = pr(); copy_url(p and p.url) end, "Copy URL" },
    { "L", function() local it = item_at(buf); if it and it.check then M.log(it.check, S[buf]) end end, "Log of check" },
  })
  loading(buf, "pull requests")
  pr_list_fetch(buf)
  return buf
end

---------------------------------------------------------------------------
-- One pull request
---------------------------------------------------------------------------

local pr_fields = table.concat({ "number", "title", "state", "author", "body", "headRefName", "baseRefName",
  "isDraft", "reviewDecision", "latestReviews", "reviewRequests", "statusCheckRollup", "mergeable",
  "mergeStateStatus", "additions", "deletions", "changedFiles", "files", "url", "comments", "createdAt",
  "labels" }, ",")

local function field(b, label, chunks)
  table.insert(chunks, 1, { pad(label, 10), "Comment" })
  b:add(chunks)
end

local review_states = {
  APPROVED = { "✓ approved", "DiagnosticOk" },
  CHANGES_REQUESTED = { "✗ changes requested", "DiagnosticError" },
  COMMENTED = { "● commented", "Comment" },
  DISMISSED = { "- dismissed", "Comment" },
  PENDING = { "● pending", "DiagnosticWarn" },
}

local function pr_render(buf)
  local st = S[buf]
  local pr = st.data
  local b = builder()
  b:add({ { ("#%d "):format(pr.number), "Special" }, { pr.title or "", "Title" } })
  local state = (pr.state or ""):lower()
  field(b, "State", {
    { state .. (pr.isDraft and " (draft)" or ""), state == "open" and "DiagnosticOk" or (state == "merged" and "Keyword" or "DiagnosticError") },
    { "  by " }, { pr.author and pr.author.login or "?", "Identifier" },
    { "  " .. (pr.baseRefName or "") .. " ← ", "Comment" }, { pr.headRefName or "", "Constant" },
    { "  " .. ago(pr.createdAt), "Comment" },
  })
  local decision = pr.reviewDecision or ""
  field(b, "Review", { decision == "APPROVED" and { "✓ approved", "DiagnosticOk" }
    or decision == "CHANGES_REQUESTED" and { "✗ changes requested", "DiagnosticError" }
    or decision == "REVIEW_REQUIRED" and { "● review required", "DiagnosticWarn" }
    or { "no review required", "Comment" } })
  if state == "open" then
    local ms = (pr.mergeStateStatus or ""):lower()
    local good = ms == "clean" or ms == "has_hooks" or ms == "unstable"
    field(b, "Merge", { { (pr.mergeable == "CONFLICTING" and "conflicts" or ms), good and "DiagnosticOk" or "DiagnosticWarn" } })
  end
  field(b, "Checks", counts(pr.statusCheckRollup, {}))
  if pr.labels and #pr.labels > 0 then
    field(b, "Labels", { { table.concat(vim.tbl_map(function(l) return l.name end, pr.labels), ", "), "Keyword" } })
  end
  field(b, "URL", { { pr.url or "" } })
  b:add({ { "d diff  c checkout  a approve  r request changes  C comment  m merge  L log  R rerun failed  O octo  o copy URL  ? keys", "Comment" } })
  b:add("")

  -- Reviews
  b:add({ { "Reviews", "Title" } })
  local any = false
  for _, r in ipairs(pr.latestReviews or {}) do
    any = true
    local s = review_states[r.state] or { r.state or "?", "Comment" }
    b:add({ { "  " }, { pad(r.author and r.author.login or "?", 20) .. " ", "Identifier" }, { s[1], s[2] },
      { "  " .. ago(r.submittedAt), "Comment" } })
  end
  for _, rr in ipairs(pr.reviewRequests or {}) do
    any = true
    b:add({ { "  " }, { pad(rr.login or rr.name or rr.slug or "?", 20) .. " ", "Identifier" }, { "● requested", "DiagnosticWarn" } })
  end
  if not any then b:add({ { "  none yet", "Comment" } }) end
  b:add("")

  -- Checks
  local chunks = { { "Checks  ", "Title" } }
  b:add(counts(pr.statusCheckRollup, chunks))
  if pr.statusCheckRollup and #pr.statusCheckRollup > 0 then
    insert_checks(b, pr.statusCheckRollup, "  ", pr)
  else
    b:add({ { "  no checks", "Comment" } })
  end
  b:add("")

  -- Files
  b:add({ { ("Files (%d)  "):format(pr.changedFiles or #(pr.files or {})), "Title" },
    { "+" .. (pr.additions or 0), "DiagnosticOk" }, { " " }, { "-" .. (pr.deletions or 0), "DiagnosticError" } })
  for _, f in ipairs(pr.files or {}) do
    b:add({ { "  " }, { pad("+" .. (f.additions or 0), 6), "DiagnosticOk" }, { pad("-" .. (f.deletions or 0), 6), "DiagnosticError" },
      { f.path } }, { type = "file", path = f.path })
  end
  b:add("")

  -- Description and comments
  b:add({ { "Description", "Title" } })
  local body = vim.trim(pr.body or "")
  b:text(body ~= "" and body or "(none)", "  ")
  if pr.comments and #pr.comments > 0 then
    b:add("")
    b:add({ { ("Comments (%d)"):format(#pr.comments), "Title" } })
    for _, c in ipairs(pr.comments) do
      b:add({ { "  " }, { c.author and c.author.login or "?", "Identifier" }, { "  " .. ago(c.createdAt), "Comment" } })
      b:text(vim.trim(c.body or ""), "    ")
    end
  end
  draw(buf, b)
end

local function pr_fetch(buf)
  local st = S[buf]
  local args = { "pr", "view" }
  if st.selector then table.insert(args, tostring(st.selector)) end
  vim.list_extend(args, { "--json", pr_fields })
  M.call(args, { repo = st.repo, cwd = st.cwd }, function(ok, out, err)
    if not S[buf] then return end
    if not ok then
      return show_error(buf, err, not st.selector and "No PR for this branch? SPC g p n creates one." or nil)
    end
    st.data = decode(out)
    if not st.data then return show_error(buf, "could not parse gh output") end
    st.number = st.data.number
    st.repo = st.repo or nil
    pr_render(buf)
    local r = rollup(st.data.statusCheckRollup)
    watch(buf, pending(st.data.statusCheckRollup),
      ("#%d checks finished: %s"):format(st.data.number, r == "pass" and "all passed" or (r or "done")))
  end)
end

function M.pr_view(selector, repo, cwd)
  if type(selector) == "string" and selector:match("^https?://") then
    repo = repo or repo_from_url(selector)
  end
  local ctx = cwd and { repo = repo, cwd = cwd } or context(repo)
  if not ctx then return end
  local name = ("gh://%s/pull/%s"):format(ctx.repo or vim.fs.basename(ctx.cwd),
    selector and tostring(selector):match("(%d+)/?$") or "current")
  local buf = open_buffer(name, "pr", { repo = ctx.repo, cwd = ctx.cwd, selector = selector })
  common_keys(buf)
  local function st() return S[buf] end
  keys(buf, {
    { "<cr>", function()
      local it = item_at(buf)
      if not it then return end
      if it.type == "check" then M.log(it.check, st())
      elseif it.type == "file" then M.pr_diff(st().number, st(), it.path) end
    end, "Log of check / diff of file" },
    { "d", function() M.pr_diff(st().number, st()) end, "Diff" },
    { "c", function() M.pr_checkout(st().number, st()) end, "Check out branch" },
    { "a", function() M.pr_approve(st()) end, "Approve" },
    { "r", function() M.pr_request_changes(st()) end, "Request changes" },
    { "C", function() M.pr_comment(st()) end, "Comment" },
    { "m", function() M.pr_merge(st()) end, "Merge" },
    { "L", function()
      local it = item_at(buf)
      if it and it.check then M.log(it.check, st()) else vim.notify("Move to a check first") end
    end, "Log of the check at the cursor" },
    { "R", function()
      local it = item_at(buf)
      if it and it.check then M.rerun_check(it.check, st()) else M.rerun_pr(st()) end
    end, "Rerun failed checks" },
    { "O", function()
      local url = st().data and st().data.url
      if url then vim.cmd("Octo " .. url) end
    end, "Open in octo.nvim (line comments)" },
    { "o", function() copy_url(st().data and st().data.url) end, "Copy URL" },
    { "Y", function() copy_url(st().data and st().data.url) end, "Copy URL" },
  })
  loading(buf, selector and ("#" .. tostring(selector)) or "this branch's pull request")
  pr_fetch(buf)
  return buf
end

function M.pr_view_current() return M.pr_view(nil) end

function M.pr_view_prompt()
  vim.ui.input({ prompt = "Pull request (number or URL): " }, function(s)
    if s and s ~= "" then M.pr_view(s) end
  end)
end

---------------------------------------------------------------------------
-- Diff, checkout, reviews, merge
---------------------------------------------------------------------------

function M.pr_diff(number, st, file)
  if not number then return end
  local name = ("gh://%s/pull/%s/diff"):format(repo_name(st), number)
  local buf = vim.fn.bufnr("^" .. vim.pesc(name) .. "$")
  if buf == -1 then
    buf = api.nvim_create_buf(true, true)
    api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "diff"
    local function jump(dir)
      local l = vim.fn.search("^diff --git ", dir > 0 and "W" or "bW")
      if l > 0 then vim.cmd("normal! zt") end
    end
    keys(buf, {
      { "q", function() Snacks.bufdelete({ buf = buf, wipe = true }) end, "Back" },
      { "]f", function() jump(1) end, "Next file" },
      { "[f", function() jump(-1) end, "Previous file" },
      { "]]", function() jump(1) end, "Next file" },
      { "[[", function() jump(-1) end, "Previous file" },
    })
  end
  api.nvim_win_set_buf(0, buf)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading diff of #" .. number .. "…" })
  M.call({ "pr", "diff", tostring(number), "--color", "never" }, { repo = st.repo, cwd = st.cwd }, function(ok, out, err)
    if not api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(ok and out or ("gh: " .. err), "\n", { plain = true }))
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    if file then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        api.nvim_win_call(win, function()
          vim.fn.cursor(1, 1)
          if vim.fn.search("^diff --git a/.* b/" .. vim.fn.escape(file, "\\/.*$^~[]") .. "$", "W") > 0 then
            vim.cmd("normal! zt")
          end
        end)
      end
    end
  end)
end

local function act(args, st, done, input)
  vim.notify("gh " .. table.concat(vim.list_slice(args, 1, 3), " ") .. "…")
  M.call(args, { repo = st.repo, cwd = st.cwd, input = input }, function(ok, _, err)
    if not ok then return vim.notify("gh: " .. err_line(err), vim.log.levels.ERROR) end
    vim.notify(done)
    for buf, s in pairs(S) do
      if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 and (s.kind == "pr" or s.kind == "pr_list" or s.kind:match("^run")) then
        refresh(buf)
      end
    end
  end)
end

local function confirm(prompt, yes, fn)
  vim.ui.select({ yes, "Cancel" }, { prompt = prompt }, function(choice)
    if choice == yes then fn() end
  end)
end

--- A split to write a comment / review in markdown. C-c C-c sends, C-c C-k cancels.
local function compose(title, send, initial)
  vim.cmd("botright new")
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  api.nvim_buf_set_name(buf, "gh://compose/" .. title:gsub("[^%w#]+", "-") .. "-" .. buf)
  vim.wo.winbar = " " .. title .. "   C-c C-c send · C-c C-k cancel"
  vim.wo.wrap = true
  api.nvim_win_set_height(0, math.max(8, math.floor(vim.o.lines / 3)))
  if initial then api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n")) end
  local function do_send()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.cmd("stopinsert")
    api.nvim_buf_delete(buf, { force = true })
    send(text)
  end
  local function cancel()
    vim.cmd("stopinsert")
    api.nvim_buf_delete(buf, { force = true })
    vim.notify("Cancelled")
  end
  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<C-c><C-c>", do_send, { buffer = buf, desc = "Send" })
    vim.keymap.set(mode, "<C-c><C-k>", cancel, { buffer = buf, desc = "Cancel" })
  end
  vim.cmd("startinsert")
  return buf
end
M.compose = compose

function M.pr_approve(st)
  local n = tostring(st.number)
  confirm("Approve #" .. n .. "?", "Approve", function()
    act({ "pr", "review", n, "--approve" }, st, "Approved #" .. n)
  end)
end

function M.pr_request_changes(st)
  local n = tostring(st.number)
  compose("Request changes on #" .. n, function(text)
    if text == "" then return vim.notify("Empty review: not sent", vim.log.levels.WARN) end
    act({ "pr", "review", n, "--request-changes", "--body-file", "-" }, st, "Requested changes on #" .. n, text)
  end)
end

function M.pr_comment(st)
  local n = tostring(st.number)
  compose("Comment on #" .. n, function(text)
    if text == "" then return vim.notify("Empty comment: not sent", vim.log.levels.WARN) end
    act({ "pr", "comment", n, "--body-file", "-" }, st, "Commented on #" .. n, text)
  end)
end

function M.pr_checkout(number, st)
  if st.repo then
    local ok, out = pcall(vim.fn.system, { "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" })
    if not ok or vim.trim(out or ""):lower() ~= st.repo:lower() then
      return vim.notify("Checkout only works for PRs of the repo you're in", vim.log.levels.WARN)
    end
  end
  act({ "pr", "checkout", tostring(number) }, { cwd = st.cwd }, "Checked out #" .. number)
end

function M.pr_merge(st)
  local n = tostring(st.number)
  local choices = {
    { "Squash and merge", { "--squash" } },
    { "Squash, merge and delete the branch", { "--squash", "--delete-branch" } },
    { "Merge commit", { "--merge" } },
    { "Rebase and merge", { "--rebase" } },
    { "Auto-merge (squash) when checks pass", { "--squash", "--auto" } },
  }
  vim.ui.select(choices, { prompt = "Merge #" .. n, format_item = function(c) return c[1] end }, function(c)
    if not c then return end
    confirm(c[1] .. " #" .. n .. "?", "Yes, merge", function()
      act(vim.list_extend({ "pr", "merge", n }, c[2]), st,
        vim.tbl_contains(c[2], "--auto") and ("#" .. n .. " will merge when its checks pass") or ("Merged #" .. n))
    end)
  end)
end

function M.rerun_check(check, st)
  local repo, _, job = job_url_parts(check.detailsUrl or check.targetUrl)
  if not job then return vim.notify("Not a GitHub Actions check", vim.log.levels.WARN) end
  confirm("Rerun " .. check_name(check) .. "?", "Rerun", function()
    act({ "run", "rerun", "--job", job }, { repo = repo, cwd = st.cwd }, "Rerunning " .. check_name(check))
  end)
end

function M.rerun_pr(st)
  local runs, seen = {}, {}
  for _, c in ipairs(st.data and st.data.statusCheckRollup or {}) do
    local b = bucket(c)
    if b == "fail" or b == "cancel" then
      local repo, run = job_url_parts(c.detailsUrl)
      if run and not seen[run] then seen[run] = true; table.insert(runs, { repo, run }) end
    end
  end
  if #runs == 0 then return vim.notify("No failed GitHub Actions checks to rerun") end
  confirm(("Rerun failed jobs of %d run%s?"):format(#runs, #runs > 1 and "s" or ""), "Rerun", function()
    for _, r in ipairs(runs) do
      act({ "run", "rerun", r[2], "--failed" }, { repo = r[1], cwd = st.cwd }, "Rerunning failed jobs of run " .. r[2])
    end
  end)
end

---------------------------------------------------------------------------
-- Check / job logs
---------------------------------------------------------------------------

local error_words = { "error", "Error", "ERROR", "FAIL", "FAILED", "panicked", "Traceback" }
local function is_error(line)
  for _, w in ipairs(error_words) do
    if line:find("%f[%w_%-]" .. w .. "%f[^%w_%-]") then return true end
  end
  return false
end

--- gh's `JOB<TAB>STEP<TAB>TIME text` lines -> text with step headings.
local function clean_log(raw)
  raw = raw:gsub("^\239\187\191", ""):gsub("\27%[[%d;]*[A-Za-z]", "")
  local b = builder()
  local step
  for line in (raw .. "\n"):gmatch("(.-)\r?\n") do
    local s, rest = line:match("^[^\t]*\t([^\t]*)\t(.*)$")
    if s then
      rest = rest:gsub("^\239\187\191", ""):gsub("^%d%d%d%d%-%d%d%-%d%dT[%d:%.]+Z ?", "")
      if s ~= step then
        step = s
        if s ~= "UNKNOWN STEP" and s ~= "" then b:add({ { "━━ " .. s .. " ━━", "Title" } }) end
      end
      line = rest
    end
    if line:match("^##%[endgroup%]") then
      -- drop
    elseif line:match("^##%[group%]") then
      b:add({ { "▸ " .. line:gsub("^##%[group%]", ""), "Statement" } })
    elseif line:match("^##%[error%]") then
      b:add({ { "Error: ", "DiagnosticError" }, { (line:gsub("^##%[error%]", "")) } })
    elseif line:match("^##%[warning%]") then
      b:add({ { "Warning: ", "DiagnosticWarn" }, { (line:gsub("^##%[warning%]", "")) } })
    elseif line:match("^##%[notice%]") or line:match("^##%[debug%]") then
      b:add({ { (line:gsub("^##%[%a+%]", "")), "Comment" } })
    elseif is_error(line) then
      b:add({ { line, "DiagnosticError" } })
    else
      b:add(line)
    end
  end
  while #b.lines > 0 and b.lines[#b.lines] == "" do table.remove(b.lines) end
  return b
end

local function log_jump(buf, dir)
  local lnum = api.nvim_win_get_cursor(0)[1]
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local i = lnum + dir
  while i >= 1 and i <= #lines do
    if lines[i]:match("^Error: ") or is_error(lines[i]) then
      api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal! zz")
      return true
    end
    i = i + dir
  end
  vim.notify(dir > 0 and "No more errors" or "No earlier errors")
  return false
end

local function log_fetch(buf)
  local st = S[buf]
  loading(buf, "log of " .. st.name)
  local function fetch(failed_only)
    M.call({ "run", "view", "--job", st.job, failed_only and "--log-failed" or "--log" },
      { repo = st.repo, cwd = st.cwd }, function(ok, out, err)
        if not S[buf] then return end
        if not ok then
          return show_error(buf, err, "Logs of running jobs only arrive when the job finishes. o copies the job's URL.")
        end
        if failed_only and vim.trim(out) == "" then return fetch(false) end
        local b = clean_log(out)
        table.insert(b.lines, 1, "")
        for _, h in ipairs(b.hls) do h[1] = h[1] + 2 end
        table.insert(b.lines, 1, "")
        b.lines[1] = ("Log of %s%s   ]e [e errors  o copy URL  gr reload  q back"):format(st.name,
          failed_only and " (failed steps)" or "")
        table.insert(b.hls, 1, { 0, 0, #b.lines[1], "Comment" })
        draw(buf, b)
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          api.nvim_win_call(win, function()
            api.nvim_win_set_cursor(win, { 1, 0 })
            if not log_jump(buf, 1) then api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 }) end
          end)
        end
      end)
  end
  fetch(st.failed)
end

--- Log of a check (from a PR) or a job (from a run): only the failed steps if it failed.
function M.log(check, parent, run_id)
  local url = check.detailsUrl or check.targetUrl or check.url
  local repo, run, job = job_url_parts(url)
  if not job and check.databaseId and run_id then
    repo, run, job = parent.repo or repo_from_url(url), tostring(run_id), tostring(check.databaseId)
  end
  if not job then
    if url then copy_url(url); vim.notify("Not a GitHub Actions job: copied its URL instead") end
    return
  end
  local name = check_name(check)
  local buf = open_buffer(("gh://log/%s"):format(job), "log", {
    repo = repo or (parent and parent.repo), cwd = parent and parent.cwd or vim.fn.getcwd(),
    run = run, job = job, name = name, url = url, failed = bucket(check) == "fail" })
  keys(buf, {
    { "gr", function() log_fetch(buf) end, "Reload" },
    { "q", function() Snacks.bufdelete({ buf = buf, wipe = true }) end, "Back" },
    { "]e", function() log_jump(buf, 1) end, "Next error" },
    { "[e", function() log_jump(buf, -1) end, "Previous error" },
    { "o", function() copy_url(S[buf].url) end, "Copy URL" },
    { "?", function() require("which-key").show({ global = false }) end, "Keys in this buffer" },
  })
  log_fetch(buf)
  return buf
end

---------------------------------------------------------------------------
-- GitHub Actions runs
---------------------------------------------------------------------------

local function run_list_render(buf)
  local st = S[buf]
  local runs = st.data or {}
  local b = builder()
  b:add({ { "Workflow runs", "Title" }, { "  " .. repo_name(st) }, st.branch and { "  [" .. st.branch .. "]", "Keyword" } or { "" } })
  b:add({ { "RET open  b this branch / all  R rerun failed  X cancel  o copy URL  gr refresh  q back  ? keys", "Comment" } })
  b:add("")
  if #runs == 0 then b:add({ { "  No runs.", "Comment" } }) end
  local ww, bw = 8, 6
  for _, r in ipairs(runs) do
    ww = math.min(24, math.max(ww, vim.fn.strdisplaywidth(r.workflowName or "")))
    bw = math.min(20, math.max(bw, vim.fn.strdisplaywidth(r.headBranch or "")))
  end
  for _, r in ipairs(runs) do
    local bk = bucket(r)
    b:add({ { icon(bk)[1] .. " ", icon(bk)[2] }, { pad(r.workflowName, ww) .. " ", "Keyword" },
      { pad(r.headBranch, bw) .. " ", "Constant" }, { pad(ago(r.createdAt), 4) .. " ", "Comment" },
      { r.displayTitle or "" }, { "  " .. (r.event or ""), "Comment" } }, { type = "run", run = r })
  end
  draw(buf, b)
end

local function run_list_fetch(buf)
  local st = S[buf]
  local args = { "run", "list", "-L", tostring(M.run_list_limit), "--json",
    "databaseId,displayTitle,workflowName,headBranch,status,conclusion,event,createdAt,updatedAt,url" }
  if st.branch then vim.list_extend(args, { "--branch", st.branch }) end
  M.call(args, { repo = st.repo, cwd = st.cwd }, function(ok, out, err)
    if not S[buf] then return end
    if not ok then return show_error(buf, err) end
    st.data = decode(out) or {}
    run_list_render(buf)
    watch(buf, pending(st.data))
  end)
end

local function current_branch(cwd)
  local out = vim.fn.systemlist({ "git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD" })
  return vim.v.shell_error == 0 and out[1] or nil
end

function M.run_list(repo, branch)
  local ctx = context(repo)
  if not ctx then return end
  local buf = open_buffer(("gh://%s/runs"):format(ctx.repo or vim.fs.basename(ctx.cwd)), "run_list",
    { repo = ctx.repo, cwd = ctx.cwd, branch = branch })
  common_keys(buf)
  local function run() local it = item_at(buf); return it and it.run end
  keys(buf, {
    { "<cr>", function() local r = run(); if r then M.run_view(r.databaseId, S[buf].repo, S[buf].cwd) end end, "Open run" },
    { "b", function()
      local st = S[buf]
      if st.branch then st.branch = nil
      else
        st.branch = current_branch(st.cwd)
        if not st.branch then return vim.notify("Detached HEAD") end
      end
      refresh(buf)
    end, "This branch / all branches" },
    { "R", function()
      local r = run()
      if not r then return end
      confirm("Rerun failed jobs of " .. (r.workflowName or "run") .. "?", "Rerun", function()
        act({ "run", "rerun", tostring(r.databaseId), "--failed" }, S[buf], "Rerunning the failed jobs")
      end)
    end, "Rerun failed jobs" },
    { "X", function()
      local r = run()
      if not r then return end
      confirm("Cancel run of " .. (r.workflowName or "?") .. "?", "Cancel the run", function()
        act({ "run", "cancel", tostring(r.databaseId) }, S[buf], "Cancelled")
      end)
    end, "Cancel run" },
    { "o", function() local r = run(); copy_url(r and r.url) end, "Copy URL" },
  })
  loading(buf, "workflow runs")
  run_list_fetch(buf)
  return buf
end

function M.run_list_branch()
  local ctx = context()
  if not ctx then return end
  local branch = current_branch(ctx.cwd)
  if not branch then return vim.notify("Detached HEAD") end
  return M.run_list(nil, branch)
end

local function run_render(buf)
  local st = S[buf]
  local r = st.data
  local b = builder()
  b:add({ { ("%s #%s "):format(r.workflowName or "", r.number or ""), "Comment" }, { r.displayTitle or "", "Title" } })
  local bk = bucket(r)
  field(b, "Status", { { icon(bk)[1] .. " ", icon(bk)[2] },
    { ((r.status == "completed") and (r.conclusion or "") or (r.status or "")):lower() },
    { "  " .. (r.headBranch or ""), "Constant" }, { "  " .. (r.event or "") .. "  " .. ago(r.createdAt), "Comment" },
    { (r.attempt and r.attempt > 1) and ("  attempt " .. r.attempt) or "" } })
  field(b, "URL", { { r.url or "" } })
  b:add({ { "RET log  TAB steps  R rerun failed  X cancel  o copy URL  gr refresh  q back  ? keys", "Comment" } })
  b:add("")
  b:add(counts(r.jobs, { { "Jobs  ", "Title" } }))
  if not r.jobs or #r.jobs == 0 then
    b:add({ { "  No jobs: the run failed before starting any (o copies its URL).", "Comment" } })
  end
  for _, job in ipairs(sort_checks(r.jobs or {})) do
    local jb = bucket(job)
    b:add({ { "  " }, { icon(jb)[1] .. " ", icon(jb)[2] }, { job.name or "" },
      { "  " .. duration(job.startedAt, job.completedAt), "Comment" } }, { type = "job", job = job })
    local open = st.open_jobs[job.databaseId]
    if open == nil then open = jb == "fail" end
    if open then
      for _, step in ipairs(job.steps or {}) do
        local sb = bucket(step)
        b:add({ { "      " }, { icon(sb)[1] .. " ", icon(sb)[2] }, { step.name or "", sb == "skip" and "Comment" or nil } },
          { type = "job", job = job })
      end
    end
  end
  draw(buf, b)
end

local function run_fetch(buf)
  local st = S[buf]
  M.call({ "run", "view", tostring(st.id), "--json",
    "databaseId,displayTitle,workflowName,headBranch,status,conclusion,event,createdAt,url,jobs,attempt,number" },
    { repo = st.repo, cwd = st.cwd }, function(ok, out, err)
      if not S[buf] then return end
      if not ok then return show_error(buf, err) end
      st.data = decode(out)
      if not st.data then return show_error(buf, "could not parse gh output") end
      run_render(buf)
      watch(buf, bucket(st.data) == "pending",
        ("%s #%s: %s"):format(st.data.workflowName or "run", st.data.number or "", (st.data.conclusion or "done"):lower()))
    end)
end

function M.run_view(id, repo, cwd)
  if type(id) == "string" and id:match("^https?://") then
    repo = repo or repo_from_url(id)
    id = id:match("/runs/(%d+)")
  end
  local ctx = cwd and { repo = repo, cwd = cwd } or context(repo)
  if not ctx or not id then return end
  local buf = open_buffer(("gh://%s/run/%s"):format(ctx.repo or vim.fs.basename(ctx.cwd), id), "run",
    { repo = ctx.repo, cwd = ctx.cwd, id = id, open_jobs = {} })
  common_keys(buf)
  local function job() local it = item_at(buf); return it and it.job end
  keys(buf, {
    { "<cr>", function() local j = job(); if j then M.log(j, S[buf], S[buf].id) end end, "Log of job" },
    { "L", function() local j = job(); if j then M.log(j, S[buf], S[buf].id) end end, "Log of job" },
    { "<tab>", function()
      local j = job()
      if not j then return end
      local st = S[buf]
      local open = st.open_jobs[j.databaseId]
      if open == nil then open = bucket(j) == "fail" end
      st.open_jobs[j.databaseId] = not open
      run_render(buf)
    end, "Show / hide steps" },
    { "R", function()
      local j = job()
      local st = S[buf]
      if j and bucket(j) == "fail" then
        confirm("Rerun job " .. (j.name or "") .. "?", "Rerun", function()
          act({ "run", "rerun", "--job", tostring(j.databaseId) }, st, "Rerunning " .. (j.name or "job"))
        end)
      else
        confirm("Rerun the failed jobs of this run?", "Rerun", function()
          act({ "run", "rerun", tostring(st.id), "--failed" }, st, "Rerunning the failed jobs")
        end)
      end
    end, "Rerun failed jobs" },
    { "X", function()
      confirm("Cancel this run?", "Cancel the run", function()
        act({ "run", "cancel", tostring(S[buf].id) }, S[buf], "Cancelled")
      end)
    end, "Cancel run" },
    { "o", function() copy_url(S[buf].data and S[buf].data.url) end, "Copy URL" },
  })
  loading(buf, "run " .. id)
  run_fetch(buf)
  return buf
end

---------------------------------------------------------------------------
-- New pull request
---------------------------------------------------------------------------

function M.pr_create()
  local ctx = context()
  if not ctx then return end
  local root = ctx.cwd
  local branch = current_branch(root)
  if not branch then return vim.notify("Detached HEAD: check out a branch first") end
  local initial = vim.fn.systemlist({ "git", "-C", root, "log", "-1", "--format=%s%n%n%b" })
  for _, t in ipairs({ ".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md", "docs/pull_request_template.md" }) do
    local f = vim.fs.joinpath(root, t)
    if vim.uv.fs_stat(f) then
      vim.list_extend(initial, { "" })
      vim.list_extend(initial, vim.fn.readfile(f))
      break
    end
  end
  compose("New PR from " .. branch .. " (first line = title)", function(text)
    local title, body = text:match("^([^\n]*)\n?(.*)$")
    if not title or vim.trim(title) == "" then return vim.notify("No title: not created", vim.log.levels.WARN) end
    vim.notify("Pushing " .. branch .. "…")
    vim.system({ "git", "push", "-u", "origin", "HEAD" }, { cwd = root, text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then return vim.notify("git push: " .. err_line(res.stderr or ""), vim.log.levels.ERROR) end
        M.call({ "pr", "create", "--title", title, "--body-file", "-" }, { cwd = root, input = vim.trim(body) },
          function(ok, out, err)
            if not ok then return vim.notify("gh pr create: " .. err_line(err), vim.log.levels.ERROR) end
            local url = vim.trim(out):match("https://%S+")
            vim.notify("Created " .. (url or "the pull request"))
            if url then M.pr_view(url, nil, root) end
          end)
      end)
    end)
  end, table.concat(initial, "\n"))
end

---------------------------------------------------------------------------
-- Another repo (Doom's -R)
---------------------------------------------------------------------------

function M.pick_repo()
  vim.ui.input({ prompt = "Repo (OWNER/REPO): ", default = M.last_repo }, function(repo)
    if not repo or not repo:match("^[%w%._-]+/[%w%._-]+$") then return end
    M.last_repo = repo
    local actions = {
      { "Open pull requests", function() M.pr_list("open", repo) end },
      { "My pull requests", function() M.pr_list("mine", repo) end },
      { "Waiting for my review", function() M.pr_list("review", repo) end },
      { "Actions runs", function() M.run_list(repo) end },
    }
    vim.ui.select(actions, { prompt = repo, format_item = function(a) return a[1] end }, function(a)
      if a then a[2]() end
    end)
  end)
end

---------------------------------------------------------------------------

refresh = function(buf)
  local st = S[buf]
  if not st then return end
  if st.kind == "pr_list" then pr_list_fetch(buf)
  elseif st.kind == "pr" then pr_fetch(buf)
  elseif st.kind == "run_list" then run_list_fetch(buf)
  elseif st.kind == "run" then run_fetch(buf)
  elseif st.kind == "log" then log_fetch(buf) end
end
M.refresh = refresh
M._state = S

return M
