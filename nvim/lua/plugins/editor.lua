return {
  -- `jk` typed quickly leaves insert mode: iPad keyboards have no Esc.
  -- (C-[ also works.) Doom: evil-escape, 0.2 s.
  {
    "max397574/better-escape.nvim",
    event = "InsertEnter",
    opts = {
      timeout = 200,
      default_mappings = false,
      mappings = {
        i = { j = { k = "<Esc>" } },
        c = { j = { k = "<C-c>" } },
      },
    },
  },

  -- Multi-cursor like VS Code's Cmd+D (Doom: evil-mc / M-d).
  -- C-d or M-d selects the word under the cursor, again adds the next
  -- match; then c (or s) and type to replace them all. Cmd never reaches a
  -- terminal, hence the two keys (M-d = Option+d with "Option as Meta").
  {
    "mg979/vim-visual-multi",
    branch = "master",
    keys = {
      { "<C-d>", mode = { "n", "x" }, desc = "Multi-cursor: select word / add next match" },
      { "<M-d>", mode = { "n", "x" }, desc = "Multi-cursor: select word / add next match" },
    },
    init = function()
      vim.g.VM_default_mappings = 1
      vim.g.VM_set_statusline = 0
      vim.g.VM_silent_exit = 1
      vim.g.VM_show_warnings = 0
      vim.g.VM_maps = {
        ["Find Under"] = "<C-d>",
        ["Find Subword Under"] = "<C-d>",
        ["Find Prev"] = "<M-D>",
        ["Skip Region"] = "<CR>",       -- Doom: RET skips the match at the cursor
        ["Remove Region"] = "Q",
        ["Visual All"] = "R",          -- Doom: R in visual selects all matches
      }
    end,
    config = function()
      -- M-d does exactly what C-d does, before and during a multi-cursor session.
      vim.keymap.set("n", "<M-d>", "<Plug>(VM-Find-Under)", { remap = true })
      vim.keymap.set("x", "<M-d>", "<Plug>(VM-Find-Subword-Under)", { remap = true })
      vim.api.nvim_create_autocmd("User", {
        pattern = "visual_multi_start",
        callback = function()
          for _, mode in ipairs({ "n", "x" }) do
            local m = vim.fn.maparg("<C-d>", mode, false, true)
            if m and m.buffer == 1 and m.rhs then
              vim.keymap.set(mode, "<M-d>", m.rhs, { buffer = true, remap = true, nowait = true })
            end
          end
        end,
      })
    end,
  },

  -- ys / cs / ds surround, like evil-surround.
  { "kylechui/nvim-surround", event = "VeryLazy", opts = {} },

  -- Auto-close brackets (Doom +smartparens).
  { "nvim-mini/mini.pairs", event = "InsertEnter", opts = {} },

  -- Detect indentation from the file (Doom whitespace +guess).
  { "NMAC427/guess-indent.nvim", event = { "BufReadPost", "BufNewFile" }, opts = {} },

  -- Folder browser (Doom dired): h = up a folder, l = open.
  {
    "stevearc/oil.nvim",
    cmd = "Oil",
    init = function()
      -- Take over `nvim some/dir` (netrw is disabled).
      local arg = vim.fn.argv(0)
      if vim.fn.argc() == 1 and type(arg) == "string" and vim.fn.isdirectory(arg) == 1 then
        require("oil")
      end
    end,
    opts = {
      default_file_explorer = true,
      columns = vim.g.have_nerd_font and { "icon" } or {},
      skip_confirm_for_simple_edits = true,
      view_options = { show_hidden = true },
      float = { padding = 2, max_width = 100, max_height = 30 },
      keymaps = {
        ["h"] = { "actions.parent", mode = "n" },
        ["l"] = { "actions.select", mode = "n" },
        ["q"] = { "actions.close", mode = "n" },
        ["+"] = { function() vim.api.nvim_feedkeys("o", "n", false) end, mode = "n", desc = "New file / folder/ (type a name, then :w)" },
      },
    },
  },
}
