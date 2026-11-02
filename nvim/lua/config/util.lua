local M = {}

--- File the user is "in": the current buffer's file, or, from a sidebar /
--- special buffer, the file in the biggest normal window.
local function current_file()
  local name = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype == "" and name ~= "" and not name:match("^%w+://") then return name end
  if vim.bo.filetype == "neo-tree" then
    local ok, state = pcall(function()
      return require("neo-tree.sources.manager").get_state(vim.b.neo_tree_source)
    end)
    if ok and state and state.path then return state.path end
  end
  local root = vim.b.livediff_root
  if root then return root end
  local best, area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local n = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == "" and n ~= "" and vim.api.nvim_win_get_config(win).relative == "" then
      local a = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if a > area then best, area = n, a end
    end
  end
  return best
end

--- Git root of the current file (or of the cwd), else the cwd.
function M.root(path)
  path = path or current_file() or vim.fn.getcwd()
  return vim.fs.root(path, ".git") or vim.fn.getcwd()
end

--- Directory of the current file (or the cwd).
function M.dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or name:match("^%w+://") then
    if vim.bo.filetype == "oil" then
      local ok, oil = pcall(require, "oil")
      if ok and oil.get_current_dir() then return oil.get_current_dir() end
    end
    return vim.fn.getcwd()
  end
  return vim.fs.dirname(name)
end

-- No cached file lists: agents create files behind our back, and fd is
-- fast enough to run on every SPC SPC (Doom: projectile-enable-caching nil).
function M.project_files()
  Snacks.picker.files({ cwd = M.root(), title = "Files in " .. vim.fn.fnamemodify(M.root(), ":~") })
end

function M.grep()
  Snacks.picker.grep({ cwd = M.root(), title = "Search " .. vim.fn.fnamemodify(M.root(), ":~") })
end

local function read_lines(path)
  return vim.fn.readfile(path)
end

local function tilde(path)
  local home = vim.env.HOME
  if home and home ~= "" and path:sub(1, #home + 1) == home .. "/" then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

-- Personal sheet plus every overlay's CHEATSHEET.md in one read-only buffer.
local function combined_cheatsheet(personal, sheets)
  local lines = read_lines(personal)
  -- sections[i] = { first = first buffer line (1-based), file, base }; buffer
  -- line n is line n - base of the file.
  local sections = { { first = 1, file = personal, base = 0 } }
  for _, f in ipairs(sheets) do
    local name = vim.fn.fnamemodify(f, ":h:t")
    vim.list_extend(lines, { "", "---", "", ("# %s overlay  (%s)"):format(name, tilde(f)) })
    local body = read_lines(f)
    local skip = (body[1] and body[1]:match("^# ")) and 1 or 0
    sections[#sections + 1] = { first = #lines, file = f, base = #lines - skip }
    for i = skip + 1, #body do lines[#lines + 1] = body[i] end
  end

  local name = "cheatsheet://all"
  local buf = vim.fn.bufnr(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.b[buf].cheatsheet_sections = sections
  vim.api.nvim_set_current_buf(buf)

  vim.keymap.set("n", "q", "<cmd>bwipeout<cr>", { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "e", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local sec = sections[1]
    for _, s in ipairs(sections) do
      if row >= s.first then sec = s end
    end
    local line = math.max(1, row - sec.base) -- heading line: top of the file
    vim.cmd("edit " .. vim.fn.fnameescape(sec.file))
    vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
  end, { buffer = buf, desc = "Edit this section's file" })
end

function M.cheatsheet()
  local file = vim.fn.stdpath("config") .. "/CHEATSHEET.md"
  local sheets = require("config.overlays").files("CHEATSHEET.md")
  if #sheets == 0 then
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.readonly = false
    return
  end
  combined_cheatsheet(file, sheets)
end

--- Copy text to the clipboard (OSC 52 reaches the iPad) and say so.
function M.copy(text)
  vim.fn.setreg("+", text)
  vim.notify("Copied " .. text)
end

return M
