-- Unit tests for config.links (OSC 8 hyperlinks via url extmarks).
local links = require("config.links")

-- Runs the provider's callbacks over buf and returns the marks it placed
-- (ephemeral marks can't be read back, so nvim_buf_set_extmark is captured).
local function provide(buf)
  local marks, orig = {}, vim.api.nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(b, ns, row, col, o)
    if ns == links.ns then marks[#marks + 1] = { row = row, s = col, e = o.end_col, url = o.url } end
    if ns ~= links.ns then return orig(b, ns, row, col, o) end -- ephemeral marks only work in a real redraw
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  local ok, err = pcall(function()
    if links.on_win(nil, win, buf, 0, vim.api.nvim_buf_line_count(buf) - 1) ~= false then
      for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do links.on_line(nil, win, buf, row) end
    end
  end)
  vim.api.nvim_buf_set_extmark = orig
  if not ok then error(err, 0) end
  return marks
end

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

return {
  find_basic = function()
    T.eq(links.find("see https://example.com/a?b=1."), { { s = 4, e = 29, url = "https://example.com/a?b=1" } })
    T.eq(links.find("(https://x.test/p)")[1].url, "https://x.test/p")
    T.eq(links.find("https://x.test/wiki/Foo_(bar)")[1].url, "https://x.test/wiki/Foo_(bar)")
    T.eq(links.find("<https://x.test/p> and \"https://y.test/q\"")[2].url, "https://y.test/q")
    T.eq(#links.find("https://a.test/1 then https://b.test/2"), 2)
    T.eq(links.find("no links here"), {})
    T.eq(links.find("http://a.b")[1].url, "http://a.b")
  end,

  provider_marks_visible_lines = function()
    vim.g.osc8_links = nil
    links.setup()
    local marks = provide(scratch({ "go to https://example.com/x now", "plain" }))
    T.eq(marks, { { row = 0, s = 6, e = 27, url = "https://example.com/x" } })
  end,

  provider_skips_long_lines_and_special_buffers = function()
    links.setup()
    vim.g.osc8_links = nil
    T.eq(provide(scratch({ "https://e.test/" .. ("a"):rep(3000) })), {})
    local buf = scratch({ "https://e.test/x" })
    vim.bo[buf].buftype = "nofile"
    T.eq(provide(buf), {}, "only normal and help buffers get links")
    vim.bo[buf].buftype = "help"
    T.eq(#provide(buf), 1)
  end,

  opt_out = function()
    links.setup()
    vim.g.osc8_links = false
    local marks = provide(scratch({ "https://example.com/x" }))
    vim.g.osc8_links = nil
    T.eq(marks, {})
  end,

  setup_idempotent = function()
    links.setup()
    local ns = links.ns
    links.setup()
    T.eq(links.ns, ns)
  end,
}
