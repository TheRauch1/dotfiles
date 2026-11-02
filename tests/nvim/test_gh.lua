-- Snapshot tests for config.gh: every gh call is stubbed with a fixture,
-- rendered buffers are compared with tests/nvim/snapshots/gh_*.txt.
local REPO = "acme/widgets"

local function setup(responses)
  -- ago()/duration() read os.time(); pin the timezone so the frozen "now" is
  -- the same instant everywhere.
  vim.uv.os_setenv("TZ", "UTC")
  T.freeze_time(os.time({ year = 2026, month = 11, day = 2, hour = 12 }))
  local gh = require("config.gh")
  gh.call = function(args, _, cb)
    local r = responses[args[1] .. " " .. args[2]]
    if not r then error("unstubbed gh call: " .. table.concat(args, " ")) end
    cb(r[1], r[2], r[3] or "")
  end
  return gh
end

local function ok(rel) return { true, T.fixture(rel) } end

-- Text and highlights: every extmark in the "gh" namespace as
-- "<row>:<start_col>-<end_col> <hl_group>", sorted.
local function snapshot(name, buf)
  T.snapshot(name, T.lines(buf))
  local ns = vim.api.nvim_get_namespaces()["gh"]
  local hls = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    hls[#hls + 1] = ("%d:%d-%d %s"):format(m[2], m[3], m[4].end_col, m[4].hl_group)
  end
  table.sort(hls)
  T.snapshot(name .. "_hl", hls)
end

return {
  pr_list_snapshot = function()
    local gh = setup({ ["pr list"] = ok("gh/pr_list.json") })
    local buf = gh.pr_list("open", REPO)
    snapshot("gh_pr_list", buf)
  end,

  pr_list_tab_expands_checks = function()
    local gh = setup({ ["pr list"] = ok("gh/pr_list.json") })
    local buf = gh.pr_list("open", REPO)
    local row
    for i, l in ipairs(T.lines(buf)) do
      if l:find("#7", 1, true) == 1 then row = i end
    end
    T.ok(row, "failing PR row not found")
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<tab>"), "x", false)
    snapshot("gh_pr_list_expanded", buf)
  end,

  pr_view_snapshot = function()
    local gh = setup({ ["pr view"] = ok("gh/pr_view.json") })
    local buf = gh.pr_view(7, REPO)
    snapshot("gh_pr_view", buf)
  end,

  run_list_snapshot = function()
    local gh = setup({ ["run list"] = ok("gh/run_list.json") })
    local buf = gh.run_list(REPO)
    snapshot("gh_run_list", buf)
  end,

  run_view_snapshot = function()
    local gh = setup({ ["run view"] = ok("gh/run_view.json") })
    local buf = gh.run_view(4242, REPO)
    snapshot("gh_run_view", buf)
  end,

  diff_snapshot = function()
    local gh = setup({ ["pr diff"] = ok("gh/pr.diff") })
    gh.pr_diff(7, { repo = REPO })
    snapshot("gh_diff", vim.api.nvim_get_current_buf())
  end,

  error_screen = function()
    local gh = setup({ ["pr list"] = { false, "", "HTTP 401: Bad credentials" } })
    local buf = gh.pr_list("open", REPO)
    T.eq(T.lines(buf)[1], "gh: HTTP 401: Bad credentials")
    snapshot("gh_error", buf)
  end,
}
