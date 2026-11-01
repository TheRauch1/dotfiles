local au = vim.api.nvim_create_autocmd
local group = vim.api.nvim_create_augroup("dotfiles", { clear = true })

---------------------------------------------------------------------------
-- Files changed on disk reload by themselves (a coding agent edits files in
-- the background). Doom: global-auto-revert-mode.
---------------------------------------------------------------------------

local function checktime()
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) == "c" or vim.fn.getcmdwintype() ~= "" then return end
  pcall(vim.cmd, "silent! checktime")
end

au({ "FocusGained", "BufEnter", "CursorHold", "TermLeave", "TermClose" }, {
  group = group,
  callback = checktime,
})

-- Terminals don't always report focus (tmux, mosh), so also poll: one
-- stat() per open file per second is nothing.
local poll = vim.uv.new_timer()
poll:start(1000, 1000, vim.schedule_wrap(checktime))

-- Never show the blocking "file changed, load it?" prompt. Unmodified
-- buffers just reload; a buffer with unsaved edits keeps them and warns
-- (auto-save then leaves it alone until you decide: :e! or :w).
au("FileChangedShell", {
  group = group,
  callback = function(ev)
    local reason = vim.v.fcs_reason
    if reason == "deleted" then
      vim.v.fcs_choice = ""
      vim.b[ev.buf].disk_conflict = true
      vim.notify("File deleted on disk: " .. vim.fn.fnamemodify(ev.file, ":~:."), vim.log.levels.WARN)
    elseif vim.bo[ev.buf].modified then
      vim.v.fcs_choice = ""
      vim.b[ev.buf].disk_conflict = true
      vim.notify(("%s changed on disk and has unsaved edits here. :e! loads the disk version, :w keeps yours.")
        :format(vim.fn.fnamemodify(ev.file, ":~:.")), vim.log.levels.WARN)
    else
      vim.v.fcs_choice = "reload"
    end
  end,
})

au({ "BufReadPost", "BufWritePost" }, {
  group = group,
  callback = function(ev) vim.b[ev.buf].disk_conflict = nil end,
})

---------------------------------------------------------------------------
-- Auto-save after 5 s without changes, never in insert mode (formatting on
-- save would otherwise rewrite text under the cursor). Doom:
-- auto-save-visited-mode with an evil-insert-state predicate.
---------------------------------------------------------------------------

local autosave_delay = 5000
local save_timer = vim.uv.new_timer()

local function saveable(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local bo = vim.bo[buf]
  local name = vim.api.nvim_buf_get_name(buf)
  return bo.modified and bo.buftype == "" and bo.modifiable and not bo.readonly
    and name ~= "" and not vim.b[buf].disk_conflict
    and vim.b[buf].visual_multi == nil -- mid multi-cursor edit
    and vim.uv.fs_stat(vim.fs.dirname(name)) ~= nil
end

local function autosave()
  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "n" then -- busy (insert, visual, cmdline, operator pending): try later
    save_timer:start(autosave_delay, 0, vim.schedule_wrap(autosave))
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if saveable(buf) then
      vim.api.nvim_buf_call(buf, function()
        -- Pick up a disk change first, so the write can never hit the
        -- "file changed since reading it" prompt.
        pcall(vim.cmd, "silent! checktime " .. buf)
        if saveable(buf) then
          pcall(vim.cmd, "silent! lockmarks update")
        end
      end)
    end
  end
end

au({ "TextChanged", "InsertLeave", "BufLeave", "FocusLost" }, {
  group = group,
  callback = function()
    save_timer:stop()
    save_timer:start(autosave_delay, 0, vim.schedule_wrap(autosave))
  end,
})

---------------------------------------------------------------------------
-- Tree-sitter: only the parsers bundled with Neovim (c, lua, vim, vimdoc,
-- query, markdown). There's no C compiler here to build more, so no
-- nvim-treesitter. Everything else uses Vim's regex syntax highlighting.
-- Never prompts, never errors when a parser is missing.
---------------------------------------------------------------------------

au("FileType", {
  group = group,
  callback = function(ev)
    if vim.bo[ev.buf].buftype ~= "" then return end
    local lang = vim.treesitter.language.get_lang(ev.match)
    if lang and pcall(vim.treesitter.language.add, lang) then
      pcall(vim.treesitter.start, ev.buf, lang)
    end
  end,
})

---------------------------------------------------------------------------
-- Small comforts
---------------------------------------------------------------------------

-- Flash what was yanked (Doom's evil-goggles / ophints).
au("TextYankPost", {
  group = group,
  callback = function() vim.hl.on_yank({ timeout = 200 }) end,
})

-- Reopen files where you left them.
au("BufReadPost", {
  group = group,
  callback = function(ev)
    local mark = vim.api.nvim_buf_get_mark(ev.buf, '"')
    local lines = vim.api.nvim_buf_line_count(ev.buf)
    if mark[1] > 0 and mark[1] <= lines and vim.bo[ev.buf].filetype ~= "gitcommit" then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Keep splits even when the terminal is resized (iPad rotation).
au("VimResized", { group = group, command = "tabdo wincmd =" })

-- q closes help, quickfix and other throwaway windows.
au("FileType", {
  group = group,
  pattern = { "help", "qf", "man", "checkhealth", "lspinfo", "notify", "gitsigns-blame" },
  callback = function(ev)
    vim.bo[ev.buf].buflisted = false
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = ev.buf, silent = true })
  end,
})

-- Create missing parent directories when saving.
au("BufWritePre", {
  group = group,
  callback = function(ev)
    if ev.match:match("^%w%w+:[\\/][\\/]") then return end
    local dir = vim.fs.dirname(vim.uv.fs_realpath(ev.match) or ev.match)
    vim.fn.mkdir(dir, "p")
  end,
})
