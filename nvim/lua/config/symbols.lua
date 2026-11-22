-- SPC c S: project symbols with the same fuzzy matching as SPC c s.
--
-- Snacks' workspace-symbol picker sends every keystroke to the language
-- server and shows its answer as is. ty matches loosely, doesn't rank, and
-- finds nothing for two words ("user role") or an empty query. So ask the
-- server for the longest word only, then score the results with Snacks'
-- own fuzzy matcher on the whole query (words in any order; the symbol's
-- file counts too, so `oauth role` finds get_user_role in oauth.py) and
-- show the best first.
local M = {}

---@param query string
function M.server_query(query)
  local best = ""
  for w in query:gmatch("%S+") do
    if #w > #best then best = w end
  end
  return best
end

---@type snacks.picker.finder
function M.finder(opts, ctx)
  local typed = ctx.filter.search
  local query = M.server_query(typed)
  if query == "" then return function() end end

  ctx.filter.search = query
  local ok, inner = pcall(require("snacks.picker.source.lsp").symbols, opts, ctx)
  ctx.filter.search = typed
  if not ok then error(inner, 0) end

  return function(cb)
    local items = {}
    inner(function(item) items[#items + 1] = item end)

    local matcher = require("snacks.picker.core.matcher").new(opts.matcher or {})
    matcher:init(typed)
    local hits = {}
    for i, item in ipairs(items) do
      local score = matcher:match(item)
      if score > 0 then hits[#hits + 1] = { item = item, score = score, i = i } end
    end
    table.sort(hits, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      if #a.item.text ~= #b.item.text then return #a.item.text < #b.item.text end
      return a.i < b.i
    end)
    for _, h in ipairs(hits) do cb(h.item) end
  end
end

---@param opts? snacks.picker.lsp.symbols.Config|{}
function M.open(opts)
  return Snacks.picker.lsp_workspace_symbols(vim.tbl_extend("force", { finder = M.finder }, opts or {}))
end

return M
