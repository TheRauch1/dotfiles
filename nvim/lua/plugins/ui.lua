local nerd = vim.g.have_nerd_font

return {
  -- Theme: onedark is the Neovim cousin of doom-one.
  {
    "navarasu/onedark.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      require("onedark").setup({ style = "dark", diagnostics = { darker = false } })
      require("onedark").load()
    end,
  },

  -- SPC pops up a menu of everything (Doom: which-key, 0.3 s).
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      preset = "helix",
      delay = function(ctx) return ctx.plugin and 0 or 300 end,
      icons = { mappings = nerd, keys = nerd and {} or {
        Up = "↑", Down = "↓", Left = "←", Right = "→", C = "C-", M = "M-", D = "D-",
        S = "S-", CR = "RET ", Esc = "Esc ", ScrollWheelDown = "", ScrollWheelUp = "",
        NL = "RET ", BS = "BS ", Space = "SPC ", Tab = "TAB ",
        F1 = "F1", F2 = "F2", F3 = "F3", F4 = "F4", F5 = "F5", F6 = "F6",
        F7 = "F7", F8 = "F8", F9 = "F9", F10 = "F10", F11 = "F11", F12 = "F12",
      } },
      spec = {
        { "<leader>a", group = "agent" },
        { "<leader>b", group = "buffer" },
        { "<leader>c", group = "code" },
        { "<leader>f", group = "file" },
        { "<leader>g", group = "git" },
        { "<leader>gp", group = "PRs & CI" },
        { "<leader>h", group = "help" },
        { "<leader>o", group = "open" },
        { "<leader>p", group = "project" },
        { "<leader>q", group = "quit" },
        { "<leader>s", group = "search" },
        { "<leader>t", group = "toggle" },
        { "<leader>w", group = "window", proxy = "<c-w>" },
        { "<leader><tab>", group = "workspace (tabs)" },
        { "<leader>1", hidden = true }, { "<leader>2", hidden = true }, { "<leader>3", hidden = true },
        { "<leader>4", hidden = true }, { "<leader>5", hidden = true }, { "<leader>6", hidden = true },
        { "<leader>7", hidden = true }, { "<leader>8", hidden = true }, { "<leader>9", hidden = true },
      },
    },
  },

  -- Status line (Doom modeline).
  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    opts = {
      options = {
        theme = "onedark",
        icons_enabled = nerd,
        globalstatus = true,
        component_separators = "",
        section_separators = "",
        disabled_filetypes = { statusline = { "snacks_dashboard" } },
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch", { "diff", symbols = { added = "+", modified = "~", removed = "-" } } },
        lualine_c = { { "filename", path = 1 },
          { "diagnostics", symbols = { error = "E", warn = "W", info = "I", hint = "H" } } },
        lualine_x = {
          { function() return require("config.agent").statusline() end,
            color = function() return require("config.agent").statusline_color() end },
          "lsp_status", "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
    },
  },

  -- Highlight TODO / FIXME / NOTE (Doom hl-todo).
  {
    "folke/todo-comments.nvim",
    event = { "BufReadPost", "BufNewFile" },
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = { signs = false },
  },

  -- Pickers (Doom vertico), dashboard, notifications, terminal, lazygit, zen.
  {
    "folke/snacks.nvim",
    lazy = false,
    priority = 900,
    opts = {
      bigfile = { enabled = true },
      notifier = { enabled = true, timeout = 4000, icons = nerd and nil or
        { error = "E ", warn = "W ", info = "I ", debug = "D ", trace = "T " } },
      input = { enabled = true },
      quickfile = { enabled = true },
      scope = { enabled = false },
      words = { enabled = false },
      zen = { enabled = true },
      picker = {
        enabled = true,
        ui_select = true,
        icons = { files = { enabled = nerd } },
        sources = {
          files = { hidden = true },
          grep = { hidden = true },
          projects = { dev = { "~/dev" }, patterns = { ".git" } },
        },
        win = {
          input = { keys = { ["<C-d>"] = false } },
        },
      },
      terminal = { win = { style = "terminal" } },
      lazygit = { configure = true },
      dashboard = {
        enabled = true,
        preset = {
          header = table.concat({
            "███╗   ██╗██╗   ██╗██╗███╗   ███╗",
            "████╗  ██║██║   ██║██║████╗ ████║",
            "██╔██╗ ██║██║   ██║██║██╔████╔██║",
            "██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║",
            "██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║",
            "╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝",
            "",
            "SPC: menu of everything   SPC ?: cheat sheet",
          }, "\n"),
          keys = {
            { key = "f", desc = "Find file in project   SPC SPC", action = function() require("config.util").project_files() end },
            { key = "r", desc = "Recent files           SPC f r", action = function() Snacks.picker.recent() end },
            { key = "p", desc = "Switch project         SPC p p", action = function() Snacks.picker.projects() end },
            { key = "/", desc = "Search in project      SPC /", action = function() require("config.util").grep() end },
            { key = "g", desc = "Git status             SPC g g", action = function() require("neogit").open() end },
            { key = "d", desc = "Live diff              SPC g d", action = function() require("config.livediff").open() end },
            { key = "?", desc = "Cheat sheet            SPC ?", action = function() require("config.util").cheatsheet() end },
            { key = "q", desc = "Quit", action = ":qa" },
          },
        },
        sections = {
          { section = "header" },
          { section = "keys", gap = 0, padding = 1 },
          { section = "recent_files", title = "Recent files", indent = 2, padding = 1, limit = 6 },
        },
      },
    },
  },
}
