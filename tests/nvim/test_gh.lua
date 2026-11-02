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

return {
  pr_list_snapshot = function()
    local gh = setup({ ["pr list"] = ok("gh/pr_list.json") })
    local buf = gh.pr_list("open", REPO)
    T.snapshot("gh_pr_list", T.lines(buf))
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
    T.snapshot("gh_pr_list_expanded", T.lines(buf))
  end,

  pr_view_snapshot = function()
    local gh = setup({ ["pr view"] = ok("gh/pr_view.json") })
    local buf = gh.pr_view(7, REPO)
    T.snapshot("gh_pr_view", T.lines(buf))
  end,

  run_list_snapshot = function()
    local gh = setup({ ["run list"] = ok("gh/run_list.json") })
    local buf = gh.run_list(REPO)
    T.snapshot("gh_run_list", T.lines(buf))
  end,

  run_view_snapshot = function()
    local gh = setup({ ["run view"] = ok("gh/run_view.json") })
    local buf = gh.run_view(4242, REPO)
    T.snapshot("gh_run_view", T.lines(buf))
  end,

  diff_snapshot = function()
    local gh = setup({ ["pr diff"] = ok("gh/pr.diff") })
    gh.pr_diff(7, { repo = REPO })
    T.snapshot("gh_diff", T.lines(vim.api.nvim_get_current_buf()))
  end,

  error_screen = function()
    local gh = setup({ ["pr list"] = { false, "", "HTTP 401: Bad credentials" } })
    local buf = gh.pr_list("open", REPO)
    T.eq(T.lines(buf)[1], "gh: HTTP 401: Bad credentials")
  end,
}
