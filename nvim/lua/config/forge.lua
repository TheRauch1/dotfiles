-- The toolkit behind the PR/CI buffers, cut out of gh.lua so other forges
-- (and trackers) look and behave the same: async CLI runner, formatting,
-- status icons, buffers with highlights and items, common keys, auto-refresh
-- while something runs, actions, the compose split and diff buffers.
--
-- forge.new{ name, filetype, refresh } gives each UI its own buffers, state
-- and highlight namespace; the rest are plain functions.
local M = {}
local api = vim.api
local util = require("config.util")

---------------------------------------------------------------------------
-- Running a CLI
---------------------------------------------------------------------------

--- A function(args, opts, cb) that runs `bin args` asynchronously (no shell);
--- opts.input goes to stdin; cb(ok, stdout, stderr) on the main loop.
function M.runner(o)
  return function(args, opts, cb)
    if vim.fn.executable(o.bin) ~= 1 then
      vim.notify(o.missing_hint, vim.log.levels.ERROR)
      return
    end
    opts = opts or {}
    local cmd = vim.list_extend({ o.bin }, args)
    vim.system(cmd, { cwd = opts.cwd, text = true, env = o.env, stdin = opts.input }, function(res)
      vim.schedule(function() cb(res.code == 0, res.stdout or "", vim.trim(res.stderr or "")) end)
    end)
  end
end

function M.decode(s)
  local ok, v = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and v or nil
end

function M.err_line(stderr)
  local lines = vim.split(stderr, "\n", { trimempty = true })
  return lines[#lines] or "failed"
end

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------

-- Days since 1970-01-01 of a proleptic Gregorian date; no os.time, so the
-- result doesn't depend on the local timezone or its DST rules.
local function days(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m > 2 and m - 3 or m + 9) + 2) / 5) + d - 1
  return era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
end

--- Seconds since the epoch from ISO-8601 (Z, ±hhmm, ±hh:mm or no zone = UTC)
--- or a number (milliseconds if it's too big to be seconds).
function M.epoch(v)
  if type(v) == "number" then return math.floor(v > 1e11 and v / 1000 or v) end
  if type(v) ~= "string" then return nil end
  local y, mo, d, h, mi, se, rest = v:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)(.*)")
  if not y then return nil end
  if y == "0001" then return nil end -- Go's zero time: "not yet"
  local t = days(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + h * 3600 + mi * 60 + se
  local sign, oh, om = rest:match("([+-])(%d%d):?(%d%d)$")
  if sign then t = t - (sign == "+" and 1 or -1) * (oh * 3600 + om * 60) end
  return t
end

function M.ago(v)
  local t = M.epoch(v)
  if not t then return "" end
  local d = os.time() - t
  if d < 60 then return "now" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  if d < 86400 then return math.floor(d / 3600) .. "h" end
  if d < 86400 * 30 then return math.floor(d / 86400) .. "d" end
  if d < 86400 * 365 then return math.floor(d / 86400 / 30) .. "mo" end
  return math.floor(d / 86400 / 365) .. "y"
end

function M.duration(from, to)
  local a, b = M.epoch(from), M.epoch(to)
  if not a then return "" end
  local d = (b or os.time()) - a
  if d < 0 then return "" end
  if d < 60 then return d .. "s" end
  if d < 3600 then return ("%dm%02ds"):format(math.floor(d / 60), d % 60) end
  return ("%dh%02dm"):format(math.floor(d / 3600), math.floor((d % 3600) / 60))
end

function M.pad(s, n)
  s = s or ""
  local w = vim.fn.strdisplaywidth(s)
  if w > n then return vim.fn.strcharpart(s, 0, n - 1) .. "…" end
  return s .. string.rep(" ", n - w)
end

-- Status buckets: pass fail pending cancel skip. Each forge maps its own
-- states onto them with a bucket_fn(item).
local icons = {
  pass = { "✓", "DiagnosticOk" }, fail = { "✗", "DiagnosticError" }, pending = { "●", "DiagnosticWarn" },
  cancel = { "⊘", "Comment" }, skip = { "-", "Comment" },
}
function M.icon(b) return icons[b] or icons.skip end

--- The bucket that sums up all items (any failure wins), nil for none.
function M.rollup(items, bucket_fn)
  if not items or #items == 0 then return nil end
  local seen = {}
  for _, c in ipairs(items) do seen[bucket_fn(c)] = true end
  for _, b in ipairs({ "fail", "pending", "cancel", "pass" }) do
    if seen[b] then return b end
  end
  return "skip"
end

--- Appends "✓ 3  ✗ 1  " style chunks to chunks.
function M.counts(items, bucket_fn, chunks)
  local n = {}
  for _, c in ipairs(items or {}) do local b = bucket_fn(c); n[b] = (n[b] or 0) + 1 end
  for _, b in ipairs({ "pass", "fail", "pending", "cancel", "skip" }) do
    if n[b] then
      table.insert(chunks, { M.icon(b)[1] .. " " .. n[b] .. "  ", M.icon(b)[2] })
    end
  end
  return chunks
end

local rank = { fail = 0, pending = 1, cancel = 2, pass = 3, skip = 4 }
--- A sorted copy: failures first, then by name.
function M.sort_by_bucket(items, bucket_fn, name_fn)
  local out = vim.deepcopy(items or {})
  table.sort(out, function(a, b)
    local ra, rb = rank[bucket_fn(a)], rank[bucket_fn(b)]
    if ra ~= rb then return ra < rb end
    return name_fn(a) < name_fn(b)
  end)
  return out
end

---------------------------------------------------------------------------
-- Buffers
---------------------------------------------------------------------------

local function builder()
  local b = { lines = {}, hls = {}, items = {} }
  function b:add(chunks, item)
    if type(chunks) == "string" then chunks = { { chunks } } end
    local line = ""
    for _, c in ipairs(chunks) do
      local text = (c[1] or ""):gsub("\n", " ")
      if c[2] and #text > 0 then table.insert(self.hls, { #self.lines, #line, #line + #text, c[2] }) end
      line = line .. text
    end
    table.insert(self.lines, line)
    if item then self.items[#self.lines] = item end
  end
  function b:text(text, indent, hl)
    text = (text or ""):gsub("\r", "")
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      self:add({ { (indent or "") .. l, hl } })
    end
  end
  return b
end

local function stop_timer(st)
  if st and st.timer then st.timer:stop(); st.timer:close(); st.timer = nil end
end

local function keys(buf, list)
  for _, k in ipairs(list) do
    vim.keymap.set("n", k[1], k[2], { buffer = buf, desc = k[3], nowait = true, silent = true })
  end
end

--- A UI: its buffers (ui.S: buf -> state { kind, items, ... }), highlights
--- and keys. o = { name, filetype, refresh = fun(buf), interval? }; interval
--- (ms, default 15000) may be a function, read each time a timer starts.
function M.new(o)
  local ui = { name = o.name, S = {}, builder = builder, keys = keys }
  local S = ui.S
  local ns = api.nvim_create_namespace(o.name)
  local function interval()
    local v = o.interval or 15000
    if type(v) == "function" then return v() end
    return v
  end

  function ui.draw(buf, b)
    if not api.nvim_buf_is_valid(buf) then return end
    local views = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
    end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, b.lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(b.hls) do
      pcall(api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
    S[buf].items = b.items
    for win, view in pairs(views) do
      if api.nvim_win_is_valid(win) then api.nvim_win_call(win, function() vim.fn.winrestview(view) end) end
    end
  end

  function ui.loading(buf, what)
    local b = builder()
    b:add({ { "Loading " .. what .. "…", "Comment" } })
    ui.draw(buf, b)
  end

  function ui.show_error(buf, stderr, hint)
    local b = builder()
    b:add({ { o.name .. ": " .. M.err_line(stderr), "DiagnosticError" } })
    b:add("")
    b:text(stderr, "  ", "Comment")
    if hint then b:add(""); b:add({ { hint, "Comment" } }) end
    b:add({ { "gr tries again, q goes back.", "Comment" } })
    ui.draw(buf, b)
  end

  --- Find or create a buffer of this UI and show it in the main window.
  function ui.open_buffer(name, kind, st)
    local buf = vim.fn.bufnr("^" .. vim.pesc(name) .. "$")
    if buf == -1 or not S[buf] then
      buf = api.nvim_create_buf(true, true)
      api.nvim_buf_set_name(buf, name)
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].swapfile = false
      vim.bo[buf].filetype = o.filetype
      vim.bo[buf].modifiable = false
      api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function() stop_timer(S[buf]); S[buf] = nil end })
    end
    stop_timer(S[buf])
    S[buf] = vim.tbl_extend("force", { kind = kind, items = {} }, st)
    -- Don't open inside the sidebar.
    local win = api.nvim_get_current_win()
    if vim.bo[api.nvim_win_get_buf(win)].filetype == "neo-tree" then
      win = require("config.sidebar").main_window() or win
      api.nvim_set_current_win(win)
    end
    api.nvim_win_set_buf(win, buf)
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = true
    return buf
  end

  function ui.item_at(buf)
    local st = S[buf]
    if not st then return nil end
    return st.items[api.nvim_win_get_cursor(0)[1]]
  end

  -- Re-fetch every few seconds while CI runs; say when it finishes.
  function ui.watch(buf, is_pending, done_msg)
    local st = S[buf]
    if not st then return end
    if is_pending then
      st.watching = true
      if not st.timer then
        local ms = interval()
        st.timer = vim.uv.new_timer()
        st.timer:start(ms, ms, vim.schedule_wrap(function()
          if not api.nvim_buf_is_valid(buf) then return stop_timer(st) end
          if #vim.fn.win_findbuf(buf) > 0 then o.refresh(buf) end
        end))
      end
    else
      if st.watching and done_msg then vim.notify(done_msg) end
      st.watching = false
      stop_timer(st)
    end
  end

  function ui.common_keys(buf)
    keys(buf, {
      { "gr", function() o.refresh(buf) end, "Refresh" },
      { "q", function() Snacks.bufdelete({ buf = buf, wipe = true }) end, "Back" },
      { "?", function() require("which-key").show({ global = false }) end, "Keys in this buffer" },
    })
  end

  --- Run a write (run(cb) calls cb(ok, out, err)), then refresh what's on screen.
  function ui.act(run, label, done)
    vim.notify(label .. "…")
    run(function(ok, _, err)
      if not ok then return vim.notify(o.name .. ": " .. M.err_line(err), vim.log.levels.ERROR) end
      vim.notify(done)
      for buf in pairs(S) do
        if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then o.refresh(buf) end
      end
    end)
  end

  --- A diff in a plain buffer (filetype diff); ]f [f jump between files.
  --- fetch(cb) calls cb(ok, text, err); file puts that file's diff on top.
  --- what is shown while loading ("diff" unless given).
  function ui.diff_buffer(name, fetch, file, what)
    local buf = vim.fn.bufnr("^" .. vim.pesc(name) .. "$")
    if buf == -1 then
      buf = api.nvim_create_buf(true, true)
      api.nvim_buf_set_name(buf, name)
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].swapfile = false
      vim.bo[buf].filetype = "diff"
      local function jump(dir)
        local l = vim.fn.search("^diff --git ", dir > 0 and "W" or "bW")
        if l > 0 then vim.cmd("normal! zt") end
      end
      keys(buf, {
        { "q", function() Snacks.bufdelete({ buf = buf, wipe = true }) end, "Back" },
        { "]f", function() jump(1) end, "Next file" },
        { "[f", function() jump(-1) end, "Previous file" },
        { "]]", function() jump(1) end, "Next file" },
        { "[[", function() jump(-1) end, "Previous file" },
      })
    end
    api.nvim_win_set_buf(0, buf)
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading " .. (what or "diff") .. "…" })
    fetch(function(ok, out, err)
      if not api.nvim_buf_is_valid(buf) then return end
      vim.bo[buf].modifiable = true
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(ok and out or (o.name .. ": " .. err), "\n", { plain = true }))
      vim.bo[buf].modifiable = false
      vim.bo[buf].modified = false
      if file then
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          api.nvim_win_call(win, function()
            vim.fn.cursor(1, 1)
            if vim.fn.search("^diff --git a/.* b/" .. vim.fn.escape(file, "\\/.*$^~[]") .. "$", "W") > 0 then
              vim.cmd("normal! zt")
            end
          end)
        end
      end
    end)
    return buf
  end

  return ui
end

---------------------------------------------------------------------------
-- Prompts
---------------------------------------------------------------------------

function M.copy_url(url)
  if url then util.copy(url) else vim.notify("No URL here") end
end

function M.confirm(prompt, yes, fn)
  vim.ui.select({ yes, "Cancel" }, { prompt = prompt }, function(choice)
    if choice == yes then fn() end
  end)
end

--- A split to write a comment / review in markdown. C-c C-c sends, C-c C-k
--- cancels. The buffer is named <scheme>://compose/… (scheme: "forge").
function M.compose(title, send, initial, scheme)
  vim.cmd("botright new")
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  api.nvim_buf_set_name(buf, (scheme or "forge") .. "://compose/" .. title:gsub("[^%w#]+", "-") .. "-" .. buf)
  vim.wo.winbar = " " .. title .. "   C-c C-c send · C-c C-k cancel"
  vim.wo.wrap = true
  api.nvim_win_set_height(0, math.max(8, math.floor(vim.o.lines / 3)))
  if initial then api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n")) end
  local function do_send()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.cmd("stopinsert")
    api.nvim_buf_delete(buf, { force = true })
    send(text)
  end
  local function cancel()
    vim.cmd("stopinsert")
    api.nvim_buf_delete(buf, { force = true })
    vim.notify("Cancelled")
  end
  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<C-c><C-c>", do_send, { buffer = buf, desc = "Send" })
    vim.keymap.set(mode, "<C-c><C-k>", cancel, { buffer = buf, desc = "Cancel" })
  end
  vim.cmd("startinsert")
  return buf
end

return M
