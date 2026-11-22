-- SPC /: search code and file names in one box, like `oauth.py get user`.
--
-- Every word has to show up either in the line or in the file's path, in
-- any order. So `oauth.py get user` finds lines with "get" and "user" in
-- files whose path contains "oauth.py", and `get user` finds lines with
-- both words anywhere in the project. Words are plain text (no regex);
-- lowercase words ignore case, a word with a capital letter matches it
-- exactly. Text after " -- " still goes to rg as is (`get -- -t py`).
-- Ctrl+g still switches to fuzzy filtering of the results.
local M = {}

---@param query string
---@return { words: string[], args?: string }
function M.parse(query)
  local text, args = query:match("^(.-)%s+%-%-%s*(.*)$")
  local out = { words = vim.split(vim.trim(text or query), "%s+", { trimempty = true }) }
  if args and args ~= "" then out.args = args end
  return out
end

-- rg pattern: lines containing at least one of the words. A line whose
-- words are all in the path alone isn't worth showing.
---@param words string[]
function M.pattern(words)
  local alts = {}
  for _, w in ipairs(words) do
    alts[#alts + 1] = (w:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?%{%}%|\\]", "\\%0"))
  end
  return table.concat(alts, "|")
end

-- Does every word appear in `hay` (the item's "path:line:col:text")?
---@param words string[]
---@param hay string
function M.matches(words, hay)
  local lower
  for _, w in ipairs(words) do
    if w:find("%u") then
      if not hay:find(w, 1, true) then return false end
    else
      lower = lower or hay:lower()
      if not lower:find(w, 1, true) then return false end
    end
  end
  return true
end

-- Snacks grep finder for the query. Snacks builds the rg command from
-- ctx.filter.search right away, so swap the pattern in for that call only
-- (the box keeps showing what was typed), then drop lines that miss a word.
---@type snacks.picker.finder
function M.finder(opts, ctx)
  local q = M.parse(ctx.filter.search)
  local o = setmetatable({ regex = true }, { __index = opts })

  local typed = ctx.filter.search
  ctx.filter.search = #q.words > 0 and (M.pattern(q.words) .. (q.args and (" -- " .. q.args) or "")) or ""
  local ok, inner = pcall(require("snacks.picker.source.grep").grep, o, ctx)
  ctx.filter.search = typed
  if not ok then error(inner, 0) end
  if #q.words < 2 then return inner end

  return function(cb)
    return inner(function(item)
      if M.matches(q.words, item.text) then cb(item) end
    end)
  end
end

---@param opts? snacks.picker.grep.Config|{}
function M.open(opts)
  return Snacks.picker.grep(vim.tbl_extend("force", { finder = M.finder }, opts or {}))
end

return M
