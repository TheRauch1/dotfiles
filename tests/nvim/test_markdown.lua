-- render-markdown.nvim: in-buffer rendering with Unicode-only icons.
local function marks(buf)
  local ns = vim.api.nvim_get_namespaces()["render-markdown.nvim"]
  if not ns then return {} end
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

local function render_text(buf)
  local out = {}
  for _, m in ipairs(marks(buf)) do
    for _, key in ipairs({ "virt_text", "sign_text" }) do
      for _, chunk in ipairs(m[4][key] or {}) do out[#out + 1] = type(chunk) == "table" and chunk[1] or chunk end
    end
  end
  return table.concat(out, " ")
end

local body = { "# Title", "", "- item one", "- [ ] todo", "- [x] done", "", "```lua", "print(1)", "```" }

local function show(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = "markdown"
  require("lazy").load({ plugins = { "render-markdown.nvim" } })
  vim.cmd("doautocmd FileType markdown")
  T.wait(function() return #marks(buf) > 0 end)
end

return {
  renders_markdown_buffer = function()
    vim.g.have_nerd_font = false
    local path = vim.fn.tempname() .. ".md"
    vim.fn.writefile(body, path)
    vim.cmd("edit " .. path)
    local buf = vim.api.nvim_get_current_buf()
    show(buf)
    T.ok(#marks(buf) > 0, "no render extmarks")
    local text = render_text(buf)
    T.ok(text:find("•", 1, true), "no bullet in: " .. text)
    T.ok(text:find("☐", 1, true), "no checkbox in: " .. text)
  end,

  renders_nofile_markdown = function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
    show(buf)
    T.ok(#marks(buf) > 0, "nofile buffer not rendered")
  end,

  toggle_key = function()
    T.ok(vim.fn.maparg("<leader>tm", "n") ~= "", "no <leader>tm mapping")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
    show(buf)
    T.ok(#marks(buf) > 0)
    local rhs = vim.fn.maparg("<leader>tm", "n", false, true).callback
    -- the plugin drops updates inside its debounce window (100 ms)
    vim.wait(250)
    rhs()
    T.ok(T.wait(function() return #marks(buf) == 0 end), "still rendered after toggle off")
    vim.wait(250)
    rhs()
    T.ok(T.wait(function() return #marks(buf) > 0 end), "not rendered after toggle on")
  end,
}
