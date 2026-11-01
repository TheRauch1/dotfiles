local o = vim.opt

o.number = true
o.relativenumber = true       -- Doom: display-line-numbers-type 'relative
o.mouse = "a"                 -- tap / trackpad / two-finger scroll
o.mousemodel = "extend"
o.termguicolors = true
o.background = "dark"
o.signcolumn = "yes"
o.cursorline = true
o.scrolloff = 3               -- Doom: scroll-margin 3
o.splitbelow = true           -- Doom: evil-split-window-below
o.splitright = true           -- Doom: evil-vsplit-window-right
o.splitkeep = "screen"
o.ignorecase = true
o.smartcase = true
o.undofile = true             -- persistent undo (Doom :emacs undo)
o.updatetime = 300
o.timeoutlen = 400
o.ttimeoutlen = 10            -- Alt/Option keys arrive as Esc+key: keep short, no Esc lag
o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.breakindent = true
o.linebreak = true
o.wrap = false
o.showmode = false            -- the status line shows it
o.laststatus = 3              -- one status line, like Doom's modeline
o.confirm = false             -- never pop questions; commands fail with a message instead
o.shortmess:append("IcWA")    -- no intro, no "written" spam, no swap-file prompt (A)
o.swapfile = false            -- agents edit files behind our back; swap prompts would block
o.autoread = true
o.fillchars = { eob = " ", diff = "╱" }
o.pumheight = 12
o.completeopt = "menu,menuone,noselect"
o.inccommand = "split"
o.virtualedit = "block"
o.foldlevelstart = 99         -- Doom :editor fold: za / zc / zo, everything open by default
o.foldmethod = "indent"
o.list = true
o.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
o.sessionoptions = "buffers,curdir,tabpages,winsize"
o.title = true
