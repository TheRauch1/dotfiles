-- Yanks go to the system clipboard of whatever terminal you're sitting at
-- (iPad Blink, Ghostty, Windows Terminal) via OSC 52, also through SSH and
-- tmux (tmux.conf sets set-clipboard on). Like Doom's (tty +osc).
--
-- Pasting reads Neovim's own last yank instead of asking the terminal:
-- many terminals ignore OSC 52 read requests, and waiting for an answer
-- that never comes freezes Neovim for seconds. To paste from the iPad
-- clipboard use the terminal's paste (Cmd+V), which types the text in.

local ok, osc52 = pcall(require, "vim.ui.clipboard.osc52")
if not ok then return end

local cache = { ["+"] = { {}, "v" }, ["*"] = { {}, "v" } }

local function copy(reg)
  local send = osc52.copy(reg)
  return function(lines, regtype)
    cache[reg] = { lines, regtype }
    send(lines, regtype)
  end
end

local function paste(reg)
  return function() return cache[reg] end
end

vim.g.clipboard = {
  name = "OSC 52 (copy only)",
  copy = { ["+"] = copy("+"), ["*"] = copy("*") },
  paste = { ["+"] = paste("+"), ["*"] = paste("*") },
}
vim.opt.clipboard = "unnamedplus"
