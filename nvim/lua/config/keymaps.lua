-- Keys, laid out like Doom's. Plugins load on first use.
local util = require("config.util")

local function map(mode, lhs, rhs, desc, opts)
  opts = vim.tbl_extend("force", { desc = desc, silent = true }, opts or {})
  vim.keymap.set(mode, lhs, rhs, opts)
end
local function leader(lhs, rhs, desc, mode) map(mode or "n", "<leader>" .. lhs, rhs, desc) end
local function pick(src, opts) return function() Snacks.picker[src](opts) end end

-- Basics ------------------------------------------------------------------
map({ "n", "i", "x" }, "<C-s>", "<cmd>silent! update<cr><esc>", "Save")
map("n", "<esc>", "<cmd>nohlsearch<cr><esc>", "Clear search highlight")
map("t", "<C-x>", "<C-\\><C-n>", "Leave terminal mode")
map("n", "]b", "<cmd>bnext<cr>", "Next buffer")
map("n", "[b", "<cmd>bprevious<cr>", "Previous buffer")
map("n", "]e", function() vim.diagnostic.jump({ count = 1, float = true }) end, "Next error")
map("n", "[e", function() vim.diagnostic.jump({ count = -1, float = true }) end, "Previous error")
map("x", "<", "<gv", "Indent left")
map("x", ">", ">gv", "Indent right")

leader("?", util.cheatsheet, "Cheat sheet")
leader(":", pick("commands"), "Run a command (M-x)")
leader(";", pick("command_history"), "Command history")
leader("x", function() Snacks.scratch() end, "Scratch buffer")
leader("`", "<cmd>e #<cr>", "Previous file")

-- Files & projects --------------------------------------------------------
leader("<space>", util.project_files, "Find file in project")
leader(".", function() require("oil").open_float(util.dir()) end, "Browse files here")
leader(",", pick("buffers"), "Switch buffer")
leader("/", util.grep, "Search in project")
leader("*", util.grep_word, "Search word in project", { "n", "x" })

leader("ff", function() Snacks.picker.files({ cwd = util.dir() }) end, "Find file here")
leader("fr", pick("recent"), "Recent files")
leader("fs", "<cmd>write<cr>", "Save file")
leader("fS", "<cmd>wall<cr>", "Save all files")
leader("fy", function() util.copy(vim.fn.expand("%:p")) end, "Copy file path")
leader("fY", function() util.copy(vim.fn.expand("%:.")) end, "Copy relative file path")
leader("fp", function() Snacks.picker.files({ cwd = vim.fn.stdpath("config") }) end, "Neovim config files")

leader("pp", function() require("config.workspaces").pick_project() end, "Open project (~/dev) as a workspace")
leader("pf", util.project_files, "Find file in project")
leader("ps", util.grep, "Search in project")

leader("ss", pick("lines"), "Search in this file")
leader("sp", util.grep, "Search in project")
leader("sd", function() Snacks.picker.grep({ cwd = util.dir() }) end, "Search in this folder")
leader("sr", pick("resume"), "Resume last search")
leader("si", pick("lsp_symbols"), "Jump to symbol")
leader("st", function() Snacks.picker.todo_comments() end, "TODO / FIXME list")

-- Buffers -----------------------------------------------------------------
leader("bb", pick("buffers"), "Switch buffer")
leader("bd", function() Snacks.bufdelete() end, "Kill buffer")
leader("bk", function() Snacks.bufdelete() end, "Kill buffer")
leader("bO", function() Snacks.bufdelete.other() end, "Kill other buffers")
leader("bn", "<cmd>bnext<cr>", "Next buffer")
leader("bp", "<cmd>bprevious<cr>", "Previous buffer")
leader("br", "<cmd>e!<cr>", "Revert buffer from disk")

-- Agent drawer (config/agent.lua): one pi per project, Alt+a slides it in/out
local function agent(fn, ...)
  local args = { ... }
  return function() require("config.agent")[fn](unpack(args)) end
end
map({ "n", "i", "x", "t" }, "<M-a>", agent("toggle"), "Agent drawer (show / hide)")
leader("aa", agent("pick"), "All agents (jump to one)")
leader("aw", agent("watch_toggle_layout"), "Watch layout: agent beside the live diff")
leader("ai", agent("prompt"), "Prompt the agent (without leaving here)")
leader("ap", agent("pick_session"), "Reopen an earlier conversation")
leader("as", agent("send_selection"), "Send selection to agent", "x")
leader("af", agent("send_file"), "Send this file (@path) to agent")
leader("ae", agent("send_diagnostics"), "Send this file's errors to agent")
leader("ah", agent("send_hunk"), "Send git change under cursor to agent")
leader("ar", function() require("config.livediff").open(util.root()) end, "Review: live diff of all changes")
leader("al", agent("quickfix"), "Files the agent changed (quickfix)")
leader("ak", agent("restart"), "Restart agent (continue last session)")
leader("an", agent("restart", true), "Restart agent with a fresh session")
map("n", "]a", agent("jump", 1), "Next file the agent changed")
map("n", "[a", agent("jump", -1), "Previous file the agent changed")

-- Code --------------------------------------------------------------------
leader("cf", function() require("conform").format({ lsp_format = "fallback" }) end, "Format buffer", { "n", "x" })
leader("cx", pick("diagnostics_buffer"), "List errors (file)")
leader("cX", pick("diagnostics"), "List errors (project)")
leader("cd", function() vim.diagnostic.open_float() end, "Error at cursor")

-- Open --------------------------------------------------------------------
leader("op", function() require("config.sidebar").toggle_tree() end, "File tree (right sidebar)")
leader("oP", function() require("config.sidebar").reveal() end, "Show this file in the tree")
leader("og", function() require("config.sidebar").toggle_git() end, "Git panel (right sidebar)")
leader("o-", function() require("oil").open(util.dir()) end, "Folder browser here")
leader("oe", function() Snacks.terminal.toggle(nil, { cwd = util.root() }) end, "Terminal popup")
leader("ot", function() Snacks.terminal.toggle(nil, { cwd = util.root() }) end, "Terminal popup")
leader("oE", function() vim.cmd("tabnew | terminal"); vim.cmd.startinsert() end, "Terminal (new tab)")

-- Git ---------------------------------------------------------------------
leader("gg", function() require("neogit").open({ cwd = util.root() }) end, "Git status (Neogit)")
leader("gG", function() Snacks.lazygit({ cwd = util.root() }) end, "lazygit")
leader("gd", function() require("config.livediff").open(util.root()) end, "Live diff (auto-refresh)")
leader("gD", "<cmd>DiffviewOpen<cr>", "Side-by-side diff (Diffview)")
leader("gh", "<cmd>DiffviewFileHistory %<cr>", "File history")
leader("gH", "<cmd>DiffviewFileHistory<cr>", "Repo history")
leader("gc", function() require("neogit").open({ "commit", cwd = util.root() }) end, "Commit")
leader("gl", pick("git_log"), "Git log")
leader("gL", pick("git_log_file"), "Git log of this file")
leader("gS", pick("git_status"), "Changed files")
leader("gb", function() Snacks.picker.git_branches({ cwd = util.root() }) end, "Switch branch")
leader("go", function() Snacks.gitbrowse() end, "Open on GitHub (copies URL)", { "n", "x" })

-- PRs & CI of the origin's forge (gh by default), like Doom's SPC g p ---
local function gh(fn, ...)
  local args = { ... }
  return function() require("config.forge").dispatch(fn, unpack(args)) end
end
leader("gpl", gh("pr_list", "open"), "Open pull requests")
leader("gpm", gh("pr_list", "mine"), "My pull requests")
leader("gpr", gh("pr_list", "review"), "Waiting for my review")
leader("gpp", gh("pr_view_current"), "This branch's pull request")
leader("gpv", gh("pr_view_prompt"), "View PR (number or URL)")
leader("gpn", gh("pr_create"), "New pull request")
leader("gpa", gh("run_list"), "Actions runs")
leader("gpA", gh("run_list_branch"), "Actions runs of this branch")
leader("gpR", gh("pick_repo"), "Other repo (OWNER/REPO)")
leader("gpo", "<cmd>Octo pr list<cr>", "octo: PRs (line review)")
leader("gpO", "<cmd>Octo review<cr>", "octo: review this PR")

-- Windows -----------------------------------------------------------------
leader("wv", "<cmd>vsplit<cr>", "Split right")
leader("ws", "<cmd>split<cr>", "Split below")
leader("ww", "<C-w>w", "Next window")
leader("wh", "<C-w>h", "Window left")
leader("wj", "<C-w>j", "Window below")
leader("wk", "<C-w>k", "Window above")
leader("wl", "<C-w>l", "Window right")
leader("wH", "<C-w>H", "Move window far left")
leader("wJ", "<C-w>J", "Move window to the bottom")
leader("wK", "<C-w>K", "Move window to the top")
leader("wL", "<C-w>L", "Move window far right")
leader("wd", "<cmd>close<cr>", "Close window")
leader("wo", "<cmd>only<cr>", "Only this window")
leader("wm", function() Snacks.zen.zoom() end, "Maximize / restore")
leader("w=", "<C-w>=", "Balance windows")
for i = 1, 9 do
  leader(tostring(i), "<cmd>" .. i .. "wincmd w<cr>", "Window " .. i)
end

-- Workspaces = tab pages (Doom: one workspace per project) ----------------
leader("<tab><tab>", function()
  local items = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local win = vim.api.nvim_tabpage_get_win(tab)
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    local cwd = vim.fn.getcwd(-1, i)
    local mark = require("config.agent").mark(cwd)
    table.insert(items, { i = i, text = ("%d %s %s  %s"):format(i, mark ~= "" and mark or " ", vim.fn.fnamemodify(cwd, ":~"), vim.fn.fnamemodify(name, ":t")) })
  end
  vim.ui.select(items, { prompt = "Workspace", format_item = function(it) return it.text end },
    function(it) if it then vim.cmd("tabnext " .. it.i) end end)
end, "List workspaces")
leader("<tab>n", "<cmd>tabnew<cr>", "New workspace")
leader("<tab>d", "<cmd>tabclose<cr>", "Close workspace")
leader("<tab>]", "<cmd>tabnext<cr>", "Next workspace")
leader("<tab>[", "<cmd>tabprevious<cr>", "Previous workspace")
for i = 1, 9 do
  leader("<tab>" .. i, "<cmd>tabnext " .. i .. "<cr>", "Workspace " .. i)
end

-- Toggles -----------------------------------------------------------------
leader("tz", function() Snacks.zen() end, "Zen mode")
leader("tw", "<cmd>set wrap!<cr>", "Word wrap")
leader("tl", "<cmd>set relativenumber!<cr>", "Relative line numbers")
leader("tf", function()
  vim.g.format_on_save = vim.g.format_on_save == false
  vim.notify("Format on save " .. (vim.g.format_on_save and "on" or "off"))
end, "Format on save")
leader("td", function() vim.diagnostic.enable(not vim.diagnostic.is_enabled()) end, "Diagnostics")
leader("tm", function()
  if vim.bo.filetype ~= "markdown" then
    return vim.notify("Markdown rendering: open a markdown buffer first")
  end
  require("render-markdown").toggle()
end, "Markdown rendering")
leader("th", function() vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled()) end, "Inlay hints")

-- Help --------------------------------------------------------------------
leader("hk", pick("keymaps"), "What does this key do? (all keys)")
leader("hf", pick("help"), "Help pages")
leader("hh", pick("help"), "Help pages")
leader("hl", "<cmd>Lazy<cr>", "Plugins (lazy.nvim)")
leader("hm", "<cmd>messages<cr>", "Messages")
leader("hn", function() Snacks.notifier.show_history() end, "Notifications")

-- Quit --------------------------------------------------------------------
leader("qq", "<cmd>silent! wall | qa<cr>", "Save all and quit")
leader("qQ", "<cmd>qa!<cr>", "Quit without saving")

-- Commands ----------------------------------------------------------------
-- :LiveDiff [dir] turns the current window into a self-refreshing diff (= SPC g d).
vim.api.nvim_create_user_command("LiveDiff", function(o) require("config.livediff").open(o.args) end,
  { nargs = "?", complete = "dir", desc = "Live diff of a git repo (auto-refresh)" })
vim.api.nvim_create_user_command("GhPrList", function(o) require("config.gh").pr_list("open", o.args) end,
  { nargs = "?", desc = "Pull requests (optionally of OWNER/REPO)" })
vim.api.nvim_create_user_command("GhPr", function(o) require("config.gh").pr_view(o.fargs[1], o.fargs[2]) end,
  { nargs = "+", desc = "Pull request NUMBER|URL [OWNER/REPO]" })
vim.api.nvim_create_user_command("GhRuns", function(o) require("config.gh").run_list(o.args) end,
  { nargs = "?", desc = "GitHub Actions runs (optionally of OWNER/REPO)" })
vim.api.nvim_create_user_command("GhRun", function(o) require("config.gh").run_view(o.fargs[1], o.fargs[2]) end,
  { nargs = "+", desc = "GitHub Actions run ID [OWNER/REPO]" })
