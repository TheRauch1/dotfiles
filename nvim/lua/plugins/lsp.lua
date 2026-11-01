-- Language servers come from mise (mise/config.toml) and are found on PATH.
-- A server that isn't installed is simply skipped, quietly.
local servers = {
  ty = "ty",                                  -- Python (types), like Doom's eglot + ty
  ruff = "ruff",                              -- Python (lint, fixes)
  rust_analyzer = "rust-analyzer",
  tinymist = "tinymist",                      -- Typst
  bashls = "bash-language-server",
  yamlls = "yaml-language-server",
  jsonls = "vscode-json-language-server",
  html = "vscode-html-language-server",
  cssls = "vscode-css-language-server",
  gopls = "gopls",
}

return {
  {
    "neovim/nvim-lspconfig", -- only the server definitions (lsp/*.lua); setup is vim.lsp.config
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      vim.diagnostic.config({
        severity_sort = true,
        virtual_text = { spacing = 2, source = "if_many" },
        float = { border = "rounded", source = "if_many" },
        signs = { text = { "E", "W", "I", "H" } },
      })

      vim.lsp.config("*", {
        capabilities = require("blink.cmp").get_lsp_capabilities(),
      })
      -- ruff only lints / fixes; hover and types come from ty.
      vim.lsp.config("ruff", {
        on_attach = function(client) client.server_capabilities.hoverProvider = false end,
      })

      local enable = {}
      for name, exe in pairs(servers) do
        if vim.fn.executable(exe) == 1 then table.insert(enable, name) end
      end
      vim.lsp.enable(enable)

      -- JS / TS: mise installs TypeScript 7, the native compiler, which has
      -- its own language server (`tsc --lsp`) and no tsserver.js, so
      -- typescript-language-server can't use it. Pick whichever works, once,
      -- when the first JS/TS file opens.
      local ts_fts = { "javascript", "javascriptreact", "typescript", "typescriptreact" }
      vim.api.nvim_create_autocmd("FileType", {
        pattern = ts_fts,
        once = true,
        callback = function()
          local server
          if vim.fn.executable("tsc") == 1 then
            local v = vim.system({ "tsc", "--version" }, { text = true }):wait(3000)
            local major = tonumber(((v.stdout or ""):match("Version (%d+)")) or "0")
            if major >= 7 then server = "tsc" end
          end
          if not server and vim.fn.executable("typescript-language-server") == 1 then server = "ts_ls" end
          if server then vim.lsp.enable(server) end
        end,
      })

      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("dotfiles-lsp", { clear = true }),
        callback = function(ev)
          local function map(lhs, rhs, desc, mode)
            vim.keymap.set(mode or "n", lhs, rhs, { buffer = ev.buf, desc = desc })
          end
          local pick = function(src) return function() Snacks.picker[src]() end end
          map("gd", pick("lsp_definitions"), "Go to definition")
          map("gD", pick("lsp_references"), "References") -- Doom: gD
          map("gI", pick("lsp_implementations"), "Implementations")
          map("gy", pick("lsp_type_definitions"), "Type definition")
          map("K", function() vim.lsp.buf.hover({ border = "rounded" }) end, "Docs for symbol")
          map("<leader>ca", vim.lsp.buf.code_action, "Code actions", { "n", "x" })
          map("<leader>cr", vim.lsp.buf.rename, "Rename symbol")
          map("<leader>cs", pick("lsp_symbols"), "Symbols in file")
          map("<leader>cS", pick("lsp_workspace_symbols"), "Symbols in project")
          map("<leader>cl", "<cmd>checkhealth vim.lsp<cr>", "LSP info")
        end,
      })
    end,
  },

  -- Completion popup (Doom corfu + orderless). Tab / S-Tab or C-n / C-p
  -- move, RET accepts, C-e closes.
  {
    "saghen/blink.cmp",
    version = "1.*", -- release tags ship a prebuilt fuzzy matcher: no Rust / C toolchain
    event = { "InsertEnter", "CmdlineEnter" },
    dependencies = { "rafamadriz/friendly-snippets" },
    opts = {
      keymap = {
        preset = "enter",
        ["<Tab>"] = { "select_next", "snippet_forward", "fallback" },
        ["<S-Tab>"] = { "select_prev", "snippet_backward", "fallback" },
      },
      appearance = { nerd_font_variant = "mono", use_nvim_cmp_as_default = false },
      completion = {
        list = { selection = { preselect = false, auto_insert = true } },
        documentation = { auto_show = true, auto_show_delay_ms = 300, window = { border = "rounded" } },
        menu = { border = "rounded", draw = { columns = { { "label", "label_description", gap = 1 }, { "kind" } } } },
      },
      cmdline = { enabled = true, keymap = { preset = "cmdline" }, completion = { menu = { auto_show = true } } },
      signature = { enabled = true, window = { border = "rounded" } },
      sources = { default = { "lsp", "path", "snippets", "buffer" } },
      fuzzy = { implementation = "prefer_rust" }, -- quietly falls back to Lua if the binary is missing
    },
  },

  -- Format on save (Doom (format +onsave)); ruff for Python.
  {
    "stevearc/conform.nvim",
    event = "BufWritePre",
    cmd = "ConformInfo",
    opts = {
      notify_on_error = false,
      notify_no_formatters = false,
      formatters_by_ft = {
        python = { "ruff_format" },
        rust = { "rustfmt", lsp_format = "fallback" },
        typst = { lsp_format = "prefer" },
        go = { "gofmt" },
        sh = { "shfmt" },
        javascript = { "prettierd", "prettier", stop_after_first = true },
        typescript = { "prettierd", "prettier", stop_after_first = true },
        typescriptreact = { "prettierd", "prettier", stop_after_first = true },
        json = { "prettierd", "prettier", stop_after_first = true },
        yaml = { "prettierd", "prettier", stop_after_first = true },
      },
      format_on_save = function(buf)
        if vim.g.format_on_save == false or vim.b[buf].format_on_save == false then return end
        return { timeout_ms = 1500, lsp_format = "never" }
      end,
    },
  },
}
