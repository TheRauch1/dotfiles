;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Built for terminal Emacs reached from an iPad (Blink/Termius over SSH/mosh,
;; usually inside tmux). Run in a daemon so sessions survive dropped
;; connections: `e file` in the shell attaches (see shell.zsh).
;;
;; Press SPC ? for the cheat sheet.

(setq user-full-name "Kaj Rauch")


;;; Looks

(setq doom-theme 'doom-one
      display-line-numbers-type 'relative)


;;; Discoverability: SPC pops up a menu of everything, fast

(after! which-key
  (setq which-key-idle-delay 0.3
        which-key-idle-secondary-delay 0.05))

(map! :leader
      :desc "Cheat sheet" "?" (cmd! (find-file (expand-file-name "CHEATSHEET.org" doom-user-dir))))


;;; iPad keyboard ergonomics

;; Hardware iPad keyboards have no Esc. `jk` (typed quickly) leaves insert
;; mode; C-[ also works, and Blink can remap Caps Lock to Esc.
(after! evil-escape
  (setq evil-escape-key-sequence "jk"
        evil-escape-delay 0.2))

;; Familiar save key in every evil state.
(map! :nvi "C-s" #'save-buffer)

(setq evil-split-window-below t
      evil-vsplit-window-right t
      scroll-margin 3)

;; Wide (landscape) screens split side by side, narrow ones stack.
(setq split-width-threshold 120)


;;; Terminal frames: mouse/trackpad + touch scrolling

(add-hook! 'tty-setup-hook
  (xterm-mouse-mode 1))


;;; Flaky connections: save work automatically

;; Save visited files after 5s idle, but never mid-typing in insert mode
;; (format-on-save would otherwise rewrite text under the cursor).
(setq auto-save-visited-interval 5
      auto-save-visited-predicate
      (lambda () (not (and (bound-and-true-p evil-local-mode)
                           (evil-insert-state-p)))))
(auto-save-visited-mode 1)


;;; Folder browsing: h = up a folder, l = open (like arrow keys)

(map! :after dired
      :map dired-mode-map
      :n "h" #'dired-up-directory
      :n "l" #'dired-find-file)


;;; Live diff: watch what a coding agent (pi) changes, as it changes it

;; Open files reload when changed on disk (inotify, no polling).
(setq auto-revert-avoid-polling t
      auto-revert-verbose nil)
(global-auto-revert-mode 1)

(after! magit
  (setq magit-diff-refine-hunk 'all))   ; word-level highlights in every hunk

(defvar-local +live-diff--fingerprint nil)
(defvar +live-diff--timer nil)

(defun +live-diff--fingerprint ()
  "Cheap hash of the repo's working-tree state (diff vs HEAD + untracked)."
  (secure-hash 'md5 (shell-command-to-string
                     "git diff HEAD --no-color 2>/dev/null; git ls-files --others --exclude-standard")))

(defun +live-diff--expand ()
  "Unfold every changed file down to its hunks; keep commit lists folded."
  (magit-section-show-level-4-all)
  (dolist (section (oref magit-root-section children))
    (when (memq (oref section type) '(recent stashes unpulled unpushed))
      (magit-section-hide section))))

(defun +live-diff--tick ()
  "Refresh visible live-diff buffers, but only when the repo actually changed."
  (let (alive)
    (dolist (buf (buffer-list))
      (when (buffer-local-value '+live-diff--fingerprint buf)
        (setq alive t)
        (when (and (get-buffer-window buf 'visible)
                   (not (active-minibuffer-window)))
          (with-current-buffer buf
            (let ((fp (+live-diff--fingerprint)))
              (unless (equal fp +live-diff--fingerprint)
                (setq +live-diff--fingerprint fp)
                (magit-refresh-buffer)
                (+live-diff--expand)))))))
    (unless alive
      (cancel-timer +live-diff--timer)
      (setq +live-diff--timer nil))))

(defun +live-diff (&optional dir)
  "Full-window magit status for DIR's repo with all diffs expanded.
Refreshes itself every 2s when files change. Pair with `pd' in the shell."
  (interactive)
  (let ((default-directory (or dir default-directory)))
    (magit-status-setup-buffer default-directory)
    (delete-other-windows)
    (setq +live-diff--fingerprint (+live-diff--fingerprint))
    (magit-refresh-buffer)
    (+live-diff--expand)
    (unless +live-diff--timer
      (setq +live-diff--timer (run-with-timer 2 2 #'+live-diff--tick)))))

(map! :leader :desc "Live diff (auto-refresh)" "g d" #'+live-diff)


;;; Projects

(setq projectile-project-search-path '(("~/dev" . 1) ("~/" . 1)))

;; No cached file lists: agents create files behind Emacs's back, and
;; `git ls-files' is fast enough to run on every SPC SPC.
(after! projectile
  (setq projectile-enable-caching nil))


;;; Python

(after! conda
  (setq conda-anaconda-home (expand-file-name "~/miniconda3")
        conda-env-home-directory (expand-file-name "~/miniconda3")))

;; Prefer ty (fast, from Astral) when installed; eglot falls back to
;; pyright/basedpyright/pylsp otherwise.
(after! python
  (when (executable-find "ty")
    (set-eglot-client! '(python-mode python-ts-mode) '("ty" "server")))
  (when (executable-find "ruff")
    (set-formatter! 'ruff :modes '(python-mode python-ts-mode))))


;;; Typst

(use-package! typst-ts-mode
  :mode "\\.typ\\'"
  :init
  (after! treesit
    (add-to-list 'treesit-language-source-alist
                 '(typst "https://github.com/uben0/tree-sitter-typst")))
  :config
  (set-eglot-client! 'typst-ts-mode '("tinymist"))
  (add-hook 'typst-ts-mode-local-vars-hook #'lsp! 'append))
