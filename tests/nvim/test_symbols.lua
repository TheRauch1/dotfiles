-- Unit tests for config.symbols (SPC c S: project symbols, fuzzy-ranked).
local sym = require("config.symbols")

-- Runs sym.finder with Snacks' LSP symbol finder replaced by a fake that
-- records the query it was given and yields `names` as items.
local function run(search, names)
  local lsp = require("snacks.picker.source.lsp")
  local orig, seen = lsp.symbols, {}
  lsp.symbols = function(_, ctx)
    seen.query = ctx.filter.search
    return function(cb)
      for _, n in ipairs(names or {}) do cb({ text = n }) end
    end
  end
  local ctx = { filter = { search = search } }
  local ok, res = pcall(function()
    local got = {}
    sym.finder({}, ctx)(function(item) got[#got + 1] = item.text end)
    return got
  end)
  lsp.symbols = orig
  if not ok then error(res, 0) end
  seen.items, seen.restored = res, ctx.filter.search
  return seen
end

local NAMES = {
  "get_user_profile_image_by_id utils/users.py",
  "get_user_role utils/oauth.py",
  "average_user_message_content_length utils/stats.py",
  "OAuthManager utils/oauth.py",
}

return {
  server_gets_longest_word = function()
    T.eq(sym.server_query("user role"), "user")
    T.eq(sym.server_query("  oauth   get_user "), "get_user")
    T.eq(sym.server_query(""), "")
  end,

  best_match_first = function()
    local seen = run("get_user_role", NAMES)
    T.eq(seen.items[1], "get_user_role utils/oauth.py")
    T.eq(seen.query, "get_user_role")
    T.eq(seen.restored, "get_user_role")
  end,

  several_words_any_order = function()
    -- loose fuzzy hits (r-o-l-e in "profile") may follow, like in SPC c s
    local items = run("role user", NAMES).items
    T.eq(items[1], "get_user_role utils/oauth.py")
    T.eq(vim.tbl_contains(items, "OAuthManager utils/oauth.py"), false)
  end,

  file_counts_too = function()
    -- item text includes the file, so "oauth" narrows to oauth.py symbols
    T.eq(run("oauth role", NAMES).items, { "get_user_role utils/oauth.py" })
  end,

  fuzzy = function()
    T.eq(run("gurole", NAMES).items[1], "get_user_role utils/oauth.py")
  end,

  empty_asks_nothing = function()
    local seen = run("", NAMES)
    T.eq(seen.items, {})
    T.eq(seen.query, nil)
  end,
}
