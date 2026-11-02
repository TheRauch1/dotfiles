-- Unit tests for config.forge, the toolkit shared by the gh, Bitbucket and
-- Jira UIs.
local forge = require("config.forge")

local function id(x) return x end

-- Runs fn inside dir with an empty registry and stubbed modules; restores all.
local function sandbox(dir, stubs, fn)
  local cwd, reg, saved = vim.fn.getcwd(), vim.deepcopy(forge.registry), {}
  for k, v in pairs(stubs) do saved[k] = package.loaded[k]; package.loaded[k] = v end
  for i = #forge.registry, 1, -1 do forge.registry[i] = nil end
  vim.cmd.cd(dir)
  local ok, err = pcall(fn)
  vim.cmd.cd(cwd)
  for k in pairs(stubs) do package.loaded[k] = saved[k] end
  for i = #forge.registry, 1, -1 do forge.registry[i] = nil end
  for i, r in ipairs(reg) do forge.registry[i] = r end
  if not ok then error(err, 0) end
end

local function repo(origin)
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  vim.fn.system({ "git", "-C", d, "init", "-q" })
  if origin then vim.fn.system({ "git", "-C", d, "remote", "add", "origin", origin }) end
  return d
end

return {
  draw_sets_url = function()
    local ui = forge.new({ name = "forge_url_test", filetype = "text", refresh = function() end })
    local buf = vim.api.nvim_create_buf(false, true)
    ui.S[buf] = {}
    local b = ui.builder()
    b:add({ { "#7", "Special", url = "https://e.test/7" }, { " name", url = "https://e.test/n" } })
    ui.draw(buf, b)
    local ns = vim.api.nvim_get_namespaces()["forge_url_test"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    T.eq(#marks, 2)
    T.eq(marks[1][4].hl_group, "Special")
    T.eq(marks[1][4].url, "https://e.test/7")
    T.eq(marks[2][4].url, "https://e.test/n")
    T.eq(marks[2][3], 2)
  end,

  epoch_offsets = function()
    local z = forge.epoch("2026-10-29T10:51:08Z")
    T.eq(z, 1793271068)
    T.eq(forge.epoch("2026-10-29T11:51:08.000+0100"), z)
    T.eq(forge.epoch("2026-10-29T11:51:08.000+01:00"), z)
    T.eq(forge.epoch("2026-10-29T09:51:08-0100"), z)
    T.eq(forge.epoch("2026-10-29T10:51:08"), z, "no zone means UTC")
    T.eq(forge.epoch(1793611230000), 1793611230)
    T.eq(forge.epoch(1793611230), 1793611230)
    T.eq(forge.epoch("0001-01-01T00:00:00Z"), nil)
    T.eq(forge.epoch(nil), nil)
  end,

  ago_units = function()
    local now = 1793620800 -- 2026-11-02T12:00:00Z
    T.freeze_time(now)
    local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
    T.eq(forge.ago(iso(now - 30)), "now")
    T.eq(forge.ago(iso(now - 5 * 60)), "5m")
    T.eq(forge.ago(iso(now - 3 * 3600)), "3h")
    T.eq(forge.ago(iso(now - 2 * 86400)), "2d")
    T.eq(forge.ago((now - 2 * 86400) * 1000), "2d", "milliseconds")
    T.eq(forge.ago(nil), "")
  end,

  runner_missing_binary_calls_cb = function()
    local run = forge.runner({ bin = "forge-test-no-such-binary", missing_hint = "no such binary: install it" })
    local got
    run({ "x" }, {}, function(ok, out, err) got = { ok, out, err } end)
    T.ok(T.wait(function() return got ~= nil end), "cb was never called")
    T.eq(got, { false, "", "no such binary: install it" })
  end,

  rollup_priority = function()
    T.eq(forge.rollup({ "pass", "pending", "fail" }, id), "fail")
    T.eq(forge.rollup({ "pass", "pending" }, id), "pending")
    T.eq(forge.rollup({}, id), nil)
  end,

  pad_unicode = function()
    T.eq(forge.pad("Müller Hans", 6), "Mülle…")
    T.eq(vim.fn.strdisplaywidth(forge.pad("Müller Hans", 6)), 6)
    T.eq(forge.pad("ü", 3), "ü  ")
  end,

  watch_reads_interval_at_start = function()
    local ms = 1000
    local ui = forge.new({ name = "t", filetype = "t", refresh = function() end, interval = function() return ms end })
    local buf = ui.open_buffer("t://w", "list", {})
    ms = 4321 -- set after new{}, like require("config.gh").refresh_interval = N
    ui.watch(buf, true)
    T.eq(ui.S[buf].timer:get_repeat(), 4321)
    ui.watch(buf, false)
    T.eq(ui.S[buf].timer, nil)
  end,

  act_refreshes_visible = function()
    local refreshed = {}
    local ui = forge.new({ name = "t", filetype = "t", refresh = function(b) table.insert(refreshed, b) end })
    local a = ui.open_buffer("t://a", "list", {})
    vim.cmd("split")
    local hidden = ui.open_buffer("t://hidden", "list", {})
    local b = ui.open_buffer("t://b", "view", {})
    T.ok(hidden ~= a and hidden ~= b)
    local notes = T.notifications()
    ui.act(function(cb) cb(true, "", "") end, "x", "done")
    table.sort(refreshed)
    T.eq(refreshed, { a, b })
    T.eq(vim.tbl_map(function(n) return n.msg end, notes), { "x…", "done" })
  end,

  dispatch_matches_remote = function()
    local got
    local ex = { name = "ex", module = "fake_ex", detect = function(u) return u:find("example.test", 1, true) ~= nil end }
    sandbox(repo("https://example.test/x.git"), { fake_ex = { pr_list = function(f) got = f end } }, function()
      forge.register(ex)
      T.eq(forge.registry, { ex })
      forge.dispatch("pr_list", "mine")
    end)
    T.eq(got, "mine")
  end,

  dispatch_falls_back_to_gh = function()
    local dirs = { repo(nil), repo("git@github.com:a/b.git"), vim.fn.tempname() }
    vim.fn.mkdir(dirs[3], "p")
    for _, d in ipairs(dirs) do
      local got
      sandbox(d, { ["config.gh"] = { pr_list = function(f) got = f end } }, function()
        forge.register({ name = "ex", module = "fake_ex", detect = function(u) return u:find("example.test", 1, true) ~= nil end })
        forge.dispatch("pr_list", "open")
      end)
      T.eq(got, "open")
    end
  end,

  dispatch_missing_fn = function()
    local notes = T.notifications()
    sandbox(repo("https://example.test/x.git"), { fake_ex = {} }, function()
      forge.register({ name = "ex", module = "fake_ex", detect = function(u) return u:find("example.test", 1, true) ~= nil end })
      forge.dispatch("run_list")
    end)
    T.eq(notes[#notes].msg, "Not available for ex")
    T.eq(notes[#notes].level, vim.log.levels.WARN)
  end,
}
