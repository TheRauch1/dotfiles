-- Live diff (SPC g d, or :LiveDiff): the current window becomes every change
-- in the repo against HEAD, untracked files included, all expanded in one
-- buffer, refreshed every 2 s when something changed (watch a coding agent
-- work). Mirrors Doom's +live-diff (a fully expanded magit status). Never
-- creates splits, tabs or terminal panes; q goes back to the previous buffer.
local M = {}

local SEP = "@@LIVEDIFF-SEP@@"
local live = {} -- buf -> { root = ..., output = ... }
local timer

local script = [[
git -c core.quotepath=off status --porcelain=v1 -b 2>/dev/null
echo ']] .. SEP .. [['
if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
  git -c core.quotepath=off diff HEAD --no-color --no-ext-diff -M
else
  git -c core.quotepath=off diff --cached --no-color --no-ext-diff
  git -c core.quotepath=off diff --no-color --no-ext-diff
fi
git -c core.quotepath=off ls-files --others --exclude-standard | head -n 200 | while IFS= read -r f; do
  if [ -f "$f" ] && [ "$(wc -c < "$f")" -lt 262144 ]; then
    git diff --no-index --no-color -- /dev/null "$f"
  else
    printf 'diff --git a/%s b/%s\nnew file (too big to show)\n' "$f" "$f"
  fi
done
true
]]

local ns = vim.api.nvim_create_namespace("livediff")

local function file_at(buf, lnum)
  -- Nearest "diff --git" header at or above lnum (1-based); returns path, header lnum.
  local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
  for i = #lines, 1, -1 do
    local l = lines[i]
    local b = l:match("^diff %-%-git a/.- b/(.+)$")
    if b then
      -- prefer the +++ line (handles spaces / renames)
      for j = i + 1, math.min(i + 6, #lines) do
        local p = lines[j]:match("^%+%+%+ b/(.+)$")
        if p then return p, i end
      end
      return b, i
    end
  end
end

local function status_path(line)
  -- " M path", "?? path", "R  old -> new"
  local rest = line:match("^[ MADRCU?!][ MADRCU?!] (.+)$")
  if not rest then return nil end
  return rest:match("-> (.+)$") or rest
end

local function render(buf, output, root)
  local status, diff = output:match("^(.-)" .. vim.pesc(SEP) .. "\n?(.*)$")
  status, diff = status or "", diff or output
  local slines = vim.split(vim.trim(status), "\n", { trimempty = true })
  local branch = "?"
  if slines[1] and slines[1]:match("^## ") then
    branch = table.remove(slines, 1):sub(4):gsub("%.%.%..*", "")
  end
  local dlines = vim.split(diff, "\n", { plain = true })
  if dlines[#dlines] == "" then table.remove(dlines) end
  local add, del, files = 0, 0, 0
  for _, l in ipairs(dlines) do
    if l:match("^diff %-%-git") then files = files + 1
    elseif l:match("^%+") and not l:match("^%+%+%+ ") then add = add + 1
    elseif l:match("^%-") and not l:match("^%-%-%- ") then del = del + 1 end
  end

  local out = {
    ("Live diff  %s  [%s]   %d file%s  +%d -%d   updated %s"):format(
      vim.fn.fnamemodify(root, ":~"), branch, files, files == 1 and "" or "s", add, del, os.date("%H:%M:%S")),
    "RET open  s/u stage/unstage  x discard  ]f [f file  C-j C-k hunk  TAB fold  cc commit  gr refresh  q close",
    "",
  }
  local nstatus = #slines
  if nstatus == 0 then
    table.insert(out, "Nothing changed since the last commit. Waiting for changes...")
  else
    vim.list_extend(out, slines)
  end
  table.insert(out, "")
  vim.list_extend(out, dlines)

  -- Keep the cursor on the same file + offset across refreshes.
  local wins = vim.fn.win_findbuf(buf)
  local anchors = {}
  for _, win in ipairs(wins) do
    local cur = vim.api.nvim_win_get_cursor(win)
    local path, hdr = file_at(buf, cur[1])
    anchors[win] = { path = path, off = hdr and (cur[1] - hdr) or nil, line = cur[1], view = vim.api.nvim_win_call(win, vim.fn.winsaveview) }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local hl = function(l, group) vim.api.nvim_buf_set_extmark(buf, ns, l, 0, { line_hl_group = group }) end
  hl(0, "Title")
  hl(1, "Comment")
  for i = 1, nstatus do
    local s = out[3 + i]
    local x, y = s:sub(1, 1), s:sub(2, 2)
    vim.api.nvim_buf_set_extmark(buf, ns, 2 + i, 0, { end_col = 2,
      hl_group = (x == "?" and "DiagnosticWarn") or (x ~= " " and y == " " and "DiagnosticOk") or "DiagnosticInfo" })
  end

  local n = #out
  for win, a in pairs(anchors) do
    if vim.api.nvim_win_is_valid(win) then
      local target = a.line
      if a.path then
        for i = 1, n do
          if out[i]:match("^diff %-%-git ") and out[i]:sub(-#a.path) == a.path then
            target = i + (a.off or 0)
            break
          end
        end
      end
      a.view.lnum = math.max(1, math.min(target, n))
      a.view.topline = math.max(1, a.view.topline + (a.view.lnum - a.line))
      vim.api.nvim_win_call(win, function() vim.fn.winrestview(a.view) end)
    end
  end
end

local function fetch(buf, force)
  local st = live[buf]
  if not st or st.busy then return end
  st.busy = true
  vim.system({ "sh", "-c", script }, { cwd = st.root, text = true }, function(res)
    vim.schedule(function()
      st.busy = false
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local output = res.stdout or ""
      if force or output ~= st.output then
        st.output = output
        render(buf, output, st.root)
      end
    end)
  end)
end

local function tick()
  local alive = false
  for buf in pairs(live) do
    if vim.api.nvim_buf_is_valid(buf) then
      alive = true
      if #vim.fn.win_findbuf(buf) > 0 then fetch(buf) end
    else
      live[buf] = nil
    end
  end
  if not alive and timer then
    timer:stop(); timer:close(); timer = nil
  end
end

local function git(root, args, done)
  vim.system(vim.list_extend({ "git" }, args), { cwd = root, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        vim.notify("git " .. args[1] .. ": " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
      elseif done then done() end
    end)
  end)
end

local function path_at_cursor(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local nstatus_end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = 4, #lines do
    if lines[i] == "" then nstatus_end = i break end
  end
  if lnum >= 4 and nstatus_end and lnum < nstatus_end then
    return status_path(line), nil
  end
  local path, hdr = file_at(buf, lnum)
  if not path then return nil end
  -- Line number in the new file: from the @@ header above the cursor.
  local newline
  for i = lnum, hdr + 1, -1 do
    local start = lines[i]:match("^@@ %-%d+,?%d* %+(%d+)")
    if start then
      local count = 0
      for j = i + 1, lnum do
        if not lines[j]:match("^%-") then count = count + 1 end
      end
      newline = tonumber(start) + math.max(count - 1, 0)
      break
    end
  end
  return path, newline
end

local function open_file(buf)
  local st = live[buf]
  local path, line = path_at_cursor(buf)
  if not path then return end
  local file = vim.fs.joinpath(st.root, path)
  -- Another normal window in this tab if there is one.
  local target
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if win ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_get_config(win).relative == ""
      and vim.bo[b].buftype == "" then
      target = win
      break
    end
  end
  if target then vim.api.nvim_set_current_win(target) end -- else: this window (SPC g d brings the diff back)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  if line then pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 }) end
end

local function jump(buf, pattern, dir)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local i = lnum + dir
  while i >= 1 and i <= #lines do
    if lines[i]:match(pattern) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal! zt")
      return
    end
    i = i + dir
  end
end

-- Window looks while the diff is shown; the window gets its old options
-- back when it shows something else.
local view_opts = { foldmethod = "expr", foldexpr = "getline(v:lnum)=~'^diff --git'?'>1':'='",
  foldlevel = 99, number = false, relativenumber = false, signcolumn = "no", wrap = false }

local function apply_view(win)
  if vim.w[win].livediff_saved then return end
  local saved = {}
  for k, v in pairs(view_opts) do
    saved[k] = vim.wo[win][k]
    vim.wo[win][k] = v
  end
  vim.w[win].livediff_saved = saved
end

local function restore_view(win, buf)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) == buf then return end
  local saved = vim.w[win].livediff_saved
  if not saved then return end
  for k, v in pairs(saved) do vim.wo[win][k] = v end
  vim.w[win].livediff_saved = nil
end

local function setup_buffer(buf, root)
  vim.api.nvim_create_autocmd("BufWinEnter", { buffer = buf, callback = function() apply_view(vim.api.nvim_get_current_win()) end })
  vim.api.nvim_create_autocmd("BufWinLeave", { buffer = buf, callback = function()
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.schedule(function() restore_view(win, buf) end)
    end
  end })
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "livediff"
  vim.bo[buf].syntax = "diff"
  vim.bo[buf].modifiable = false
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true, silent = true })
  end
  map("<cr>", function() open_file(buf) end, "Open file at this line")
  map("]f", function() jump(buf, "^diff %-%-git ", 1) end, "Next file")
  map("[f", function() jump(buf, "^diff %-%-git ", -1) end, "Previous file")
  map("]]", function() jump(buf, "^diff %-%-git ", 1) end, "Next file")
  map("[[", function() jump(buf, "^diff %-%-git ", -1) end, "Previous file")
  map("<C-j>", function() jump(buf, "^[@d][@i][ f]", 1) end, "Next hunk / file")
  map("<C-k>", function() jump(buf, "^[@d][@i][ f]", -1) end, "Previous hunk / file")
  map("<tab>", "za", "Fold / unfold file")
  map("gr", function() fetch(buf, true) end, "Refresh now")
  map("s", function()
    local path = path_at_cursor(buf)
    if path then git(root, { "add", "--", path }, function() fetch(buf, true) end) end
  end, "Stage file")
  map("u", function()
    local path = path_at_cursor(buf)
    if path then git(root, { "restore", "--staged", "--", path }, function() fetch(buf, true) end) end
  end, "Unstage file")
  map("x", function()
    local path = path_at_cursor(buf)
    if not path then return end
    vim.ui.select({ "No", "Yes, discard" }, { prompt = "Discard all changes to " .. path .. "?" }, function(choice)
      if choice ~= "Yes, discard" then return end
      vim.system({ "git", "ls-files", "--error-unmatch", "--", path }, { cwd = root }, function(res)
        vim.schedule(function()
          if res.code == 0 then
            git(root, { "restore", "--source=HEAD", "--staged", "--worktree", "--", path }, function() fetch(buf, true) end)
          else
            vim.fn.delete(vim.fs.joinpath(root, path))
            fetch(buf, true)
          end
        end)
      end)
    end)
  end, "Discard changes to file")
  map("cc", function() require("neogit").open({ "commit", cwd = root }) end, "Commit (Neogit)")
  map("q", function()
    local alt = vim.fn.bufnr("#")
    if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
      vim.api.nvim_win_set_buf(0, alt)
    else
      local listed = vim.tbl_filter(function(b) return b ~= buf and vim.bo[b].buflisted end, vim.api.nvim_list_bufs())
      if #listed > 0 then vim.api.nvim_win_set_buf(0, listed[1]) else vim.cmd("enew") end
    end
  end, "Back to the previous buffer")
end

function M.open(dir)
  dir = dir and dir ~= "" and vim.fn.fnamemodify(dir, ":p") or require("config.util").root()
  local root = vim.fs.root(dir, ".git")
  if not root then
    vim.notify("Live diff: not inside a git repo", vim.log.levels.WARN)
    return
  end
  local buf
  for b, st in pairs(live) do
    if st.root == root and vim.api.nvim_buf_is_valid(b) then buf = b end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "livediff://" .. root)
    live[buf] = { root = root }
    vim.b[buf].livediff_root = root
    setup_buffer(buf, root)
  end
  -- The current window becomes the diff (not inside the sidebar, though).
  if vim.bo.filetype == "neo-tree" then
    local main = require("config.sidebar").main_window()
    if main then vim.api.nvim_set_current_win(main) end
  end
  vim.api.nvim_win_set_buf(0, buf)
  fetch(buf, true)
  if not timer then
    timer = vim.uv.new_timer()
    timer:start(2000, 2000, vim.schedule_wrap(tick))
  end
  return buf
end

return M
