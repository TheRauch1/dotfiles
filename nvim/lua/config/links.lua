-- Clickable URLs: Neovim turns `url` extmarks into OSC 8 hyperlinks, which
-- terminals keep clickable even when the URL wraps across lines. A decoration
-- provider marks every URL on the visible lines; nothing is stored.
-- Markdown links `[text](url)` also mark `text` (the part between the
-- brackets) with the same url: a Markdown renderer conceals the url part, so
-- the visible text must be clickable. The url span keeps its own mark too;
-- the two spans never overlap. Autolinks `<url>` show the url itself, so the
-- url mark already covers what is visible.
local M = {}

M.ns = vim.api.nvim_create_namespace("links")

local MAX_LINE = 3000 -- skip minified/log lines: the scan runs on every redraw
local registered = false

--- URLs in a line as { s = 0-based byte col, e = exclusive end, url },
--- plus the text span of each Markdown link `[text](url)`, sorted by s.
function M.find(line)
  local out, init = {}, 1
  while true do
    local s, e = line:find("https?://[%w%-._~:/?#%[%]@!$&'()*+,;=%%]+", init)
    if not s then break end
    -- Trim what is prose, not URL: end punctuation and unbalanced closers.
    while e > s do
      local c = line:sub(e, e)
      local url = line:sub(s, e)
      local trim = c:find("^[.,;:!?'\"]$")
        or (c == ")" and select(2, url:gsub("%(", "")) < select(2, url:gsub("%)", "")))
        or (c == "]" and select(2, url:gsub("%[", "")) < select(2, url:gsub("%]", "")))
      if not trim then break end
      e = e - 1
    end
    out[#out + 1] = { s = s - 1, e = e, url = line:sub(s, e) }
    init = e + 1
  end
  -- Link text: `[text]` immediately followed by `(` and one of the urls above.
  local by_start = {}
  for _, m in ipairs(out) do by_start[m.s] = m end
  init = 1
  while #out > 0 do
    local s, e = line:find("%[[^%[%]]+%]%(", init)
    if not s then break end
    local m = by_start[e] -- 0-based start of the char after "("
    if m then out[#out + 1] = { s = s, e = e - 2, url = m.url } end
    init = e + 1
  end
  table.sort(out, function(a, b) return a.s < b.s end)
  return out
end

local function linkable(buf)
  if vim.g.osc8_links == false then return false end
  local bt = vim.bo[buf].buftype
  return bt == "" or bt == "help"
end

function M.on_win(_, _, buf) return linkable(buf) end

function M.on_line(_, _, buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line or #line > MAX_LINE or not line:find("http", 1, true) then return end
  for _, m in ipairs(M.find(line)) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, m.s, { end_col = m.e, url = m.url, ephemeral = true })
  end
end

function M.setup()
  if registered then return end
  registered = true
  vim.api.nvim_set_decoration_provider(M.ns, { on_win = M.on_win, on_line = M.on_line })
end

return M
