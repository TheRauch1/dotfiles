-- Unit tests for config.smartgrep (SPC /: "oauth.py get user" style search).
local sg = require("config.smartgrep")

-- Runs sg.finder with Snacks' grep replaced by a fake that records what it
-- was asked for and yields `lines` as items.
local function run(search, lines)
  local grep = require("snacks.picker.source.grep")
  local orig, seen = grep.grep, {}
  grep.grep = function(opts, ctx)
    seen.search, seen.regex = ctx.filter.search, opts.regex
    return function(cb)
      for _, l in ipairs(lines or {}) do cb({ text = l }) end
    end
  end
  local ctx = { filter = { search = search } }
  local ok, res = pcall(function()
    local got = {}
    sg.finder({ regex = false }, ctx)(function(item) got[#got + 1] = item.text end)
    return got
  end)
  grep.grep = orig
  if not ok then error(res, 0) end
  seen.items, seen.restored = res, ctx.filter.search
  return seen
end

return {
  parse_words = function()
    T.eq(sg.parse("  oauth.py   get user "), { words = { "oauth.py", "get", "user" } })
    T.eq(sg.parse(""), { words = {} })
    T.eq(sg.parse("get user -- -t py"), { words = { "get", "user" }, args = "-t py" })
  end,

  pattern_is_any_word_literal = function()
    T.eq(sg.pattern({ "get" }), "get")
    T.eq(sg.pattern({ "oauth.py", "get", "user" }), "oauth\\.py|get|user")
    T.eq(sg.pattern({ "foo(", "a|b" }), "foo\\(|a\\|b")
  end,

  every_word_in_path_or_line = function()
    local w = { "oauth.py", "get", "user" }
    T.eq(sg.matches(w, "backend/utils/oauth.py:12:5:    def get_user(self):"), true)
    T.eq(sg.matches(w, "backend/utils/oauth.py:40:1:    user = None"), false) -- no "get"
    T.eq(sg.matches(w, "backend/models/users.py:9:1:def get_user():"), false) -- other file
    T.eq(sg.matches({ "user", "get" }, "a.py:1:1:get_user"), true) -- any order
  end,

  smart_case = function()
    T.eq(sg.matches({ "user" }, "a.py:1:1:getUser()"), true)
    T.eq(sg.matches({ "User" }, "a.py:1:1:get_user()"), false)
    T.eq(sg.matches({ "User" }, "a.py:1:1:getUser()"), true)
  end,

  finder_filters_lines = function()
    local seen = run("oauth.py get user", {
      "backend/utils/oauth.py:12:5:def get_user(self):",
      "backend/utils/oauth.py:40:1:user = None",
      "backend/models/users.py:9:1:def get_user():",
    })
    T.eq(seen.search, "oauth\\.py|get|user")
    T.eq(seen.regex, true) -- the alternation needs regex mode
    T.eq(seen.items, { "backend/utils/oauth.py:12:5:def get_user(self):" })
    T.eq(seen.restored, "oauth.py get user")
  end,

  finder_single_word_plain = function()
    local seen = run("get_user", { "a.py:1:1:get_user" })
    T.eq(seen.search, "get_user")
    T.eq(seen.items, { "a.py:1:1:get_user" })
  end,

  finder_keeps_rg_args = function()
    T.eq(run("get user -- -t py").search, "get|user -- -t py")
  end,

  finder_empty = function()
    T.eq(run("").search, "")
  end,
}
