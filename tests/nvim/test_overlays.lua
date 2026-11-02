-- Overlay contract: nvim/lua/overlay/*.lua modules and shell.sh hooks.

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- Fresh overlay root; clears cached overlay.* modules and globals.
local function new_root()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.env.DOTFILES_D = root
  for k in pairs(package.loaded) do
    if k:match("^overlay%.") then package.loaded[k] = nil end
  end
  _G.HELLO, _G.ZZ, _G.ORDER = nil, nil, nil
  package.loaded["config.overlays"] = nil
  return root
end

local function mod(root, name, file, body)
  write(("%s/%s/nvim/lua/overlay/%s.lua"):format(root, name, file), body)
end

return {
  no_overlays = function()
    new_root()
    local o = require("config.overlays")
    T.eq(o.dirs(), {})
    local n = T.notifications()
    o.load()
    T.eq(#n, 0)
  end,

  loads_overlay_module = function()
    local root = new_root()
    mod(root, "a", "hello", "_G.HELLO = 1")
    local o = require("config.overlays")
    o.setup_rtp()
    o.load()
    T.eq(_G.HELLO, 1)
  end,

  broken_overlay_notifies_once = function()
    local root = new_root()
    mod(root, "a", "bad", 'error("boom")')
    mod(root, "a", "zz", "_G.ZZ = 1")
    local o = require("config.overlays")
    o.setup_rtp()
    local n = T.notifications()
    o.load()
    T.eq(#n, 1)
    T.eq(n[1].level, vim.log.levels.ERROR)
    T.ok(n[1].msg:match("^overlay bad: .*boom"), n[1].msg)
    T.eq(_G.ZZ, 1)
  end,

  load_order_sorted = function()
    local root = new_root()
    for _, name in ipairs({ "b", "a" }) do
      mod(root, name, "m_" .. name,
        ('_G.ORDER = _G.ORDER or {}; table.insert(_G.ORDER, "%s")'):format(name))
    end
    local o = require("config.overlays")
    o.setup_rtp()
    o.load()
    T.eq(_G.ORDER, { "a", "b" })
  end,

  shell_hook = function()
    local root = new_root()
    local home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    local cmd = ("DOTFILES_D=%s HOME=%s . %s/doom/shell.zsh; echo $OVL")
      :format(vim.fn.shellescape(root), vim.fn.shellescape(home), vim.fn.shellescape(repo))
    local function run()
      return vim.system({ "bash", "-c", cmd }, { text = true }):wait()
    end
    local r = run()
    T.eq(r.code, 0)
    T.eq(r.stderr, "")
    T.eq(r.stdout, "\n")
    write(root .. "/a/shell.sh", "OVL=yes\n")
    r = run()
    T.eq(r.stdout, "yes\n")
    T.eq(r.stderr, "")
  end,
}
