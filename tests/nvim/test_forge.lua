-- Unit tests for config.forge, the toolkit shared by the gh, Bitbucket and
-- Jira UIs.
local forge = require("config.forge")

local function id(x) return x end

return {
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
}
