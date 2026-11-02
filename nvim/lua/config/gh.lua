-- GitHub pull requests, reviews and CI checks, driven by the gh CLI (uses
-- gh's login, nothing else to set up). A port of doom/gh.el: same buffers,
-- same keys. SPC g p opens the menu; ? in any gh buffer lists its keys.
--
-- Every gh call is asynchronous, so a slow connection never freezes Neovim.
-- Buffers with running CI checks refresh themselves until the checks finish.
local M = {}
local api = vim.api
local util = require("config.util")
local forge = require("config.forge")

M.refresh_interval = 15000
M.pr_list_limit = 50
M.run_list_limit = 30

local refresh -- forward declaration
local S -- buf -> state { kind, repo, cwd, data, items, ... }
local ui = forge.new({ name = "gh", filetype = "gh",
  interval = function() return M.refresh_interval end, -- read when a timer starts
  refresh = function(buf)
    -- Logs reload on their own gr only: an action elsewhere shouldn't refetch them.
    if S[buf] and S[buf].kind ~= "log" then refresh(buf) end
  end,
})
S = ui.S

local decode, err_line, pad, ago, duration, icon = forge.decode, forge.err_line, forge.pad, forge.ago, forge.duration, forge.icon
local builder, draw, loading, show_error = ui.builder, ui.draw, ui.loading, ui.show_error
local open_buffer, item_at, keys, common_keys, watch = ui.open_buffer, ui.item_at, ui.keys, ui.common_keys, ui.watch

---------------------------------------------------------------------------
-- Running gh
---------------------------------------------------------------------------

local env = { GH_PROMPT_DISABLED = "1", GH_NO_UPDATE_NOTIFIER = "1", GH_PAGER = "cat",
  NO_COLOR = "1", CLICOLOR = "0", GH_FORCE_TTY = "" }

local run_gh = forge.runner({ bin = "gh", env = env,
  missing_hint = "gh not found: install the GitHub CLI and run `gh auth login`" })

--- Run gh asynchronously; cb(ok, stdout, stderr) on the main loop.
--- opts = { repo?, cwd?, input? }; repo adds -R OWNER/REPO.
function M.call(args, opts, cb)
  opts = opts or {}
  if opts.repo then args = vim.list_extend(vim.list_slice(args), { "-R", opts.repo }) end
  run_gh(args, opts, cb)
end

---------------------------------------------------------------------------
-- Check states and URLs
---------------------------------------------------------------------------

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

local function rollup(checks) return forge.rollup(checks, bucket) end
local function counts(checks, chunks) return forge.counts(checks, bucket, chunks) end

local function check_name(c)
  if c.context then return c.context end
  if c.workflowName and c.workflowName ~= "" then return c.workflowName .. " / " .. (c.name or "") end
  return c.name or "?"
end

local function sort_checks(checks) return forge.sort_by_bucket(checks, bucket, check_name) end

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
-- Context
---------------------------------------------------------------------------

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
      b:add({ { indent }, { icon(bk)[1] .. " ", icon(bk)[2] }, { pad(check_name(c), width) .. "  ", url = c.detailsUrl or c.targetUrl },
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
      { ("#%-6d"):format(pr.number), "Special", url = pr.url },
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
    { "o", function() local p = pr(); forge.copy_url(p and p.url) end, "Copy URL" },
    { "Y", function() local p = pr(); forge.copy_url(p and p.url) end, "Copy URL" },
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
  b:add({ { ("#%d "):format(pr.number), "Special", url = pr.url }, { pr.title or "", "Title" } })
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
    { "o", function() forge.copy_url(st().data and st().data.url) end, "Copy URL" },
    { "Y", function() forge.copy_url(st().data and st().data.url) end, "Copy URL" },
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
  return ui.diff_buffer(name, function(cb)
    M.call({ "pr", "diff", tostring(number), "--color", "never" }, { repo = st.repo, cwd = st.cwd }, cb)
  end, file, "diff of #" .. number)
end

local function act(args, st, done, input)
  ui.act(function(cb) M.call(args, { repo = st.repo, cwd = st.cwd, input = input }, cb) end,
    "gh " .. table.concat(vim.list_slice(args, 1, 3), " "), done)
end
M.compose = forge.compose

function M.pr_approve(st)
  local n = tostring(st.number)
  forge.confirm("Approve #" .. n .. "?", "Approve", function()
    act({ "pr", "review", n, "--approve" }, st, "Approved #" .. n)
  end)
end

function M.pr_request_changes(st)
  local n = tostring(st.number)
  forge.compose("Request changes on #" .. n, function(text)
    if text == "" then return vim.notify("Empty review: not sent", vim.log.levels.WARN) end
    act({ "pr", "review", n, "--request-changes", "--body-file", "-" }, st, "Requested changes on #" .. n, text)
  end, nil, "gh")
end

function M.pr_comment(st)
  local n = tostring(st.number)
  forge.compose("Comment on #" .. n, function(text)
    if text == "" then return vim.notify("Empty comment: not sent", vim.log.levels.WARN) end
    act({ "pr", "comment", n, "--body-file", "-" }, st, "Commented on #" .. n, text)
  end, nil, "gh")
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
    forge.confirm(c[1] .. " #" .. n .. "?", "Yes, merge", function()
      act(vim.list_extend({ "pr", "merge", n }, c[2]), st,
        vim.tbl_contains(c[2], "--auto") and ("#" .. n .. " will merge when its checks pass") or ("Merged #" .. n))
    end)
  end)
end

function M.rerun_check(check, st)
  local repo, _, job = job_url_parts(check.detailsUrl or check.targetUrl)
  if not job then return vim.notify("Not a GitHub Actions check", vim.log.levels.WARN) end
  forge.confirm("Rerun " .. check_name(check) .. "?", "Rerun", function()
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
  forge.confirm(("Rerun failed jobs of %d run%s?"):format(#runs, #runs > 1 and "s" or ""), "Rerun", function()
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
    if url then forge.copy_url(url); vim.notify("Not a GitHub Actions job: copied its URL instead") end
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
    { "o", function() forge.copy_url(S[buf].url) end, "Copy URL" },
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
      forge.confirm("Rerun failed jobs of " .. (r.workflowName or "run") .. "?", "Rerun", function()
        act({ "run", "rerun", tostring(r.databaseId), "--failed" }, S[buf], "Rerunning the failed jobs")
      end)
    end, "Rerun failed jobs" },
    { "X", function()
      local r = run()
      if not r then return end
      forge.confirm("Cancel run of " .. (r.workflowName or "?") .. "?", "Cancel the run", function()
        act({ "run", "cancel", tostring(r.databaseId) }, S[buf], "Cancelled")
      end)
    end, "Cancel run" },
    { "o", function() local r = run(); forge.copy_url(r and r.url) end, "Copy URL" },
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
        forge.confirm("Rerun job " .. (j.name or "") .. "?", "Rerun", function()
          act({ "run", "rerun", "--job", tostring(j.databaseId) }, st, "Rerunning " .. (j.name or "job"))
        end)
      else
        forge.confirm("Rerun the failed jobs of this run?", "Rerun", function()
          act({ "run", "rerun", tostring(st.id), "--failed" }, st, "Rerunning the failed jobs")
        end)
      end
    end, "Rerun failed jobs" },
    { "X", function()
      forge.confirm("Cancel this run?", "Cancel the run", function()
        act({ "run", "cancel", tostring(S[buf].id) }, S[buf], "Cancelled")
      end)
    end, "Cancel run" },
    { "o", function() forge.copy_url(S[buf].data and S[buf].data.url) end, "Copy URL" },
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
  forge.compose("New PR from " .. branch .. " (first line = title)", function(text)
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
  end, table.concat(initial, "\n"), "gh")
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
