local nerd = vim.g.have_nerd_font

-- Without a Nerd Font the plugin's glyphs show as boxes: swap them for
-- plain Unicode (or nothing) so the layout stays the same.
local function plain()
  local custom = {}
  for name in pairs(require("render-markdown.settings").link.default.custom) do
    custom[name] = { icon = "" } -- per-site link icons
  end
  return {
    heading = { icons = { "█ ", "▌ ", "▌ ", "▎ ", "▎ ", "▎ " }, sign = false },
    bullet = { icons = { "•", "◦", "▪", "▫" } },
    checkbox = { unchecked = { icon = "☐ " }, checked = { icon = "☑ " } },
    code = { language_icon = false, sign = false }, -- keep the language name
    link = { footnote = { icon = "" }, image = "", email = "", hyperlink = "", custom = custom },
  }
end

return {
  -- Renders Markdown in place (headings, lists, tables, code); the cursor
  -- line stays raw. Uses Neovim's bundled markdown parsers, so no
  -- nvim-treesitter. nofile buffers (SPC ?) render in all modes by default.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = "markdown",
    opts = function() return nerd and {} or plain() end,
  },
}
