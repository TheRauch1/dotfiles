;;; $DOOMDIR/init.el -*- lexical-binding: t; -*-

;; Module selection, tuned for terminal use (iPad over SSH/mosh + herdr).
;; Run `doom sync` after changing anything here.
;;
;; LSP note: eglot starts a language server only if one is on PATH.
;; Missing servers just mean "no LSP" in that language -- nothing breaks.
;; See ~/.config/doom/CHEATSHEET.org for which servers to install.

(doom! :input

       :completion
       (corfu +orderless)  ; inline completion popups
       vertico             ; fuzzy minibuffer search (files, commands, ...)

       :ui
       doom                ; Doom look
       dashboard           ; start screen with shortcuts
       hl-todo             ; highlight TODO/FIXME/NOTE
       modeline            ; status line
       nav-flash           ; flash cursor line after big jumps (easy to find on iPad)
       ophints             ; highlight region an operation acts on
       (popup +defaults)   ; tame temporary windows
       treemacs            ; VS Code-like file tree (SPC o p)
       (vc-gutter +pretty) ; git diff markers
       (window-select +numbers) ; jump to window by number
       workspaces          ; one workspace per project, like tabs
       zen                 ; distraction-free writing (SPC t z)

       :editor
       (evil +everywhere)  ; vim keys; `jk` = Esc (iPad keyboards lack Esc)
       file-templates
       fold                ; za / zc / zo
       (format +onsave)    ; format on save when a formatter exists
       multiple-cursors
       snippets
       (whitespace +guess +trim)
       word-wrap

       :emacs
       dired               ; file manager (SPC o -)
       electric
       ibuffer
       tramp
       undo                ; persistent undo, survives restarts
       vc

       :term
       eshell              ; shell inside Emacs, no external deps (SPC o e)

       :checkers
       syntax

       :tools
       ansible
       direnv
       docker
       editorconfig
       (eval +overlay)     ; run code inline / REPLs
       lookup              ; go-to-definition, docs (gd, K)
       (lsp +eglot)        ; IDE features via eglot
       magit               ; git UI (SPC g g)
       make
       tree-sitter

       :os
       (tty +osc)          ; terminal polish + clipboard to iPad via OSC 52

       :lang
       data                ; csv etc.
       emacs-lisp
       (go +lsp)
       (javascript +lsp +tree-sitter) ; JS/TS/TSX
       (json +lsp)
       latex
       markdown
       org
       (python +lsp +conda +uv)
       ess                 ; R
       (rust +lsp)
       (sh +lsp)
       (web +lsp)          ; HTML/CSS
       (yaml +lsp)

       :config
       (default +bindings +smartparens))
