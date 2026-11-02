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

  find_markdown_link_text = function()
    local found = links.find("see [the docs](https://example.com/a) now")
    local text, url
    for _, m in ipairs(found) do
      if m.s == 5 and m.e == 13 then text = m end
      if m.url == "https://example.com/a" and m.s == 15 then url = m end
    end
    T.ok(text and text.url == "https://example.com/a", "no entry for link text: " .. vim.inspect(found))
    T.ok(url, "url entry kept")
    T.eq(links.find("<https://example.com/b>")[1].url, "https://example.com/b")
  end,

  provider_marks_visible_lines = function()
    vim.g.osc8_links = nil
    links.setup()
    local marks = provide(scratch({ "go to https://example.com/x now", "plain" }))
    T.eq(marks, { { row = 0, s = 6, e = 27, url = "https://example.com/x" } })
  end,

  provider_marks_markdown_link_text = function()
    vim.g.osc8_links = nil
    links.setup()
    local marks = provide(scratch({ "[docs](https://example.com/x)" }))
    T.eq(marks, {
      { row = 0, s = 1, e = 5, url = "https://example.com/x" },
      { row = 0, s = 7, e = 28, url = "https://example.com/x" },
    })
  end,

  find_markdown_link_with_url_text = function()
    local u = "https://a.test/x"
    T.eq(links.find("[" .. u .. "](" .. u .. ")"), {
      { s = 1, e = 17, url = u },
      { s = 19, e = 35, url = u },
    })
  end,

  provider_marks_nofile_markdown = function()
    vim.g.osc8_links = nil
    links.setup()
    local buf = scratch({ "[docs](https://example.com/x)" })
    vim.bo[buf].buftype = "nofile"
    T.eq(provide(buf), {}, "plain nofile stays unmarked")
    vim.bo[buf].filetype = "markdown"
    T.eq(#provide(buf), 2)
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
