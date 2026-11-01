local nerd = vim.g.have_nerd_font

return {
  -- Full git UI, a magit clone (SPC g g): s stage, u unstage, x discard,
  -- c c commit, P p push, TAB folds, q closes.
  {
    "NeogitOrg/neogit",
    cmd = "Neogit",
    dependencies = { "nvim-lua/plenary.nvim", "sindrets/diffview.nvim" },
    opts = {
      kind = "tab",
      graph_style = "ascii",
      disable_hint = false,
      disable_insert_on_commit = "auto",
      filewatcher = { enabled = true, interval = 1000 },
      integrations = { diffview = true, snacks = true },
      signs = { hunk = { "", "" }, item = { ">", "v" }, section = { ">", "v" } },
      commit_editor = { kind = "split" },
    },
  },

  -- Side-by-side diffs and file history (SPC g D, SPC g h).
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    opts = {
      use_icons = nerd,
      enhanced_diff_hl = true,
      signs = { fold_closed = "▸", fold_open = "▾", done = "✓" },
      icons = { folder_closed = "▸", folder_open = "▾" },
    },
  },

  -- Git markers in the gutter (Doom vc-gutter). ]d / [d jump between hunks.
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      attach_to_untracked = true,
      on_attach = function(buf)
        local gs = require("gitsigns")
        local function map(lhs, rhs, desc, mode)
          vim.keymap.set(mode or "n", lhs, rhs, { buffer = buf, desc = desc })
        end
        map("]d", function() gs.nav_hunk("next") end, "Next git change")
        map("[d", function() gs.nav_hunk("prev") end, "Previous git change")
        map("<leader>gs", gs.stage_hunk, "Stage hunk")
        map("<leader>gr", gs.reset_hunk, "Revert hunk")
        map("<leader>gR", gs.reset_buffer, "Revert file")
        map("<leader>gb", gs.blame_line, "Blame line")
        map("<leader>gB", gs.blame, "Blame file")
        map("<leader>g=", gs.preview_hunk, "Show hunk diff")
        map("<leader>gt", gs.toggle_current_line_blame, "Toggle inline blame")
        map("ih", ":<C-u>Gitsigns select_hunk<cr>", "Inside hunk", { "o", "x" })
      end,
    },
  },

  -- File tree + git changes panel, stacked in a right sidebar (like VS Code).
  -- SPC o p / SPC o g; see lua/config/sidebar.lua.
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    cmd = "Neotree",
    dependencies = { "nvim-lua/plenary.nvim", "MunifTanjim/nui.nvim", "folke/edgy.nvim" },
    opts = {
      sources = { "filesystem", "git_status" },
      close_if_last_window = true,
      popup_border_style = "rounded",
      enable_diagnostics = true,
      default_component_configs = {
        indent = { with_expanders = false, indent_marker = "│", last_indent_marker = "└" },
        icon = nerd and {} or {
          folder_closed = "▸", folder_open = "▾", folder_empty = "▹", folder_empty_open = "▿",
          default = " ", provider = function(icon, node)
            if node.type == "file" then icon.text = " " end
          end,
        },
        modified = { symbol = "●" },
        name = { trailing_slash = true },
        diagnostics = { symbols = { hint = "H", info = "I", warn = "W", error = "E" } },
        git_status = { symbols = nerd and {} or {
          added = "A", modified = "M", deleted = "D", renamed = "R",
          untracked = "?", ignored = "!", unstaged = "", staged = "S", conflict = "C",
        } },
      },
      window = {
        position = "right",
        width = 40,
        mappings = {
          ["l"] = "open",
          ["h"] = "close_node",
          ["<tab>"] = "toggle_node",
          ["<space>"] = "none", -- keep SPC as the leader in the sidebar (TAB toggles)
          ["q"] = "close_window",
        },
      },
      filesystem = {
        follow_current_file = { enabled = true },
        use_libuv_file_watcher = true,      -- agents create files: show them at once
        hijack_netrw_behavior = "disabled", -- oil handles directories
        bind_to_cwd = false,
        filtered_items = { visible = true, hide_dotfiles = false, hide_gitignored = true },
      },
      git_status = {
        window = {
          mappings = {
            ["s"] = "git_add_file",
            ["u"] = "git_unstage_file",
            ["x"] = "git_revert_file",
            ["S"] = "git_add_all",
            ["c"] = "none",
            ["cc"] = "git_commit",
            ["P"] = "git_push",
            ["q"] = { function() require("config.sidebar").hide_git() end, desc = "Hide (until SPC o g)" },
            ["="] = { function(state)
              local node = state.tree:get_node()
              if node and node.type == "file" then
                require("config.sidebar").main_window_do("DiffviewOpen -- " .. vim.fn.fnameescape(node.path))
              end
            end, desc = "Diff this file" },
          },
        },
      },
    },
  },

  -- Stacks the two neo-tree windows in one right-hand sidebar.
  {
    "folke/edgy.nvim",
    opts = {
      animate = { enabled = false },
      exit_when_last = false,
      icons = { closed = "▸ ", open = "▾ " },
      options = { right = { size = 40 } },
      wo = { winbar = true, winfixwidth = true, winfixheight = false, signcolumn = "no" },
      right = {
        {
          title = "Files",
          ft = "neo-tree",
          filter = function(buf) return vim.b[buf].neo_tree_source == "filesystem" end,
          size = { height = 0.55 },
        },
        {
          title = "Git changes",
          ft = "neo-tree",
          filter = function(buf) return vim.b[buf].neo_tree_source == "git_status" end,
          size = { height = 0.45 },
        },
      },
    },
  },
}
