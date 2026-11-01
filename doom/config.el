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


;;; Right sidebar, like VS Code: file tree (SPC o p) above a git panel (SPC o g)

(setq treemacs-position 'right
      treemacs-width 40)

;; The git panel is a narrow magit status in a right side window, below
;; treemacs. It opens by itself when you visit a file in a git repo on a
;; wide enough screen, follows you between repos, and refreshes when files
;; change on disk. Its own buffer, so SPC g g still opens the big magit.

(defvar +git-panel-auto t
  "Show the git panel automatically. SPC o g / q in the panel toggles it.")
(defvar +git-panel-min-frame-width 150
  "Only auto-show the panel on frames at least this many columns wide.")
(defvar +git-panel-width 40)
(defvar +git-panel--timer nil)
(defvar-local +git-panel--fingerprint nil)

(defun +git-panel--root ()
  (when-let ((dir (locate-dominating-file default-directory ".git")))
    (expand-file-name dir)))

(defun +git-panel--window (&optional frame)
  (seq-find (lambda (w) (window-parameter w '+git-panel))
            (window-list frame 'nomini)))

(defun +git-panel--main-window (&optional frame)
  "Most recently used window that isn't a sidebar or popup."
  (car (sort (seq-remove (lambda (w) (window-parameter w 'window-side))
                         (window-list frame 'nomini))
             (lambda (a b) (> (window-use-time a) (window-use-time b))))))

(defun +git-panel--display (buffer)
  (let ((win (display-buffer-in-side-window
              buffer `((side . right) (slot . 1)
                       (window-width . ,+git-panel-width)
                       (preserve-size . (t . nil))
                       (window-parameters . ((no-delete-other-windows . t)))))))
    (set-window-parameter win '+git-panel buffer)
    win))

(defun +git-panel--fingerprint ()
  (secure-hash 'md5 (shell-command-to-string
                     "git rev-parse HEAD 2>/dev/null; git status --porcelain 2>/dev/null; git diff --numstat 2>/dev/null; git diff --cached --numstat 2>/dev/null")))

(defun +git-panel--tick ()
  "Refresh visible panels whose repo changed; stop when none are left."
  (let (alive)
    (dolist (frame (frame-list))
      (when-let ((win (+git-panel--window frame)))
        (setq alive t)
        (when (and (frame-visible-p frame) (not (active-minibuffer-window)))
          (with-current-buffer (window-buffer win)
            (when (derived-mode-p '+git-panel-mode)
              (let ((fp (+git-panel--fingerprint)))
                (unless (equal fp +git-panel--fingerprint)
                  (setq +git-panel--fingerprint fp)
                  (magit-refresh-buffer))))))))
    (unless alive
      (cancel-timer +git-panel--timer)
      (setq +git-panel--timer nil))))

(defun +git-panel-show (root)
  "Show the git panel for the repo at ROOT without leaving the current window."
  (require 'magit)
  (let ((default-directory root)
        (magit-display-buffer-function #'+git-panel--display)
        (magit-display-buffer-noselect t))
    (pcase-let ((`(,dargs ,dfiles) (magit-diff--get-value 'magit-status-mode 'status))
                (`(,largs ,lfiles) (magit-log--get-value 'magit-status-mode 'status)))
      (magit-setup-buffer #'+git-panel-mode nil
        (magit-buffer-diff-args  dargs)
        (magit-buffer-diff-files dfiles)
        (magit-buffer-log-args   largs)
        (magit-buffer-log-files  lfiles))))
  (unless +git-panel--timer
    (setq +git-panel--timer (run-with-timer 2 2 #'+git-panel--tick))))

(defun +git-panel-hide ()
  "Close the git panel and stop auto-showing it until SPC o g."
  (interactive)
  (setq +git-panel-auto nil)
  (when-let ((win (+git-panel--window)))
    (delete-window win)))

(defun +git-panel-toggle ()
  "Show or hide the git panel for the current repo."
  (interactive)
  (if (+git-panel--window)
      (+git-panel-hide)
    (setq +git-panel-auto t)
    (+git-panel-show (or (+git-panel--root) (user-error "Not inside a git repo")))))

(defun +git-panel--maybe-show (window)
  (when (and +git-panel-auto
             (window-live-p window)
             (not (window-parameter window 'window-side))
             (>= (frame-width (window-frame window)) +git-panel-min-frame-width))
    (with-selected-window window
      (when-let ((root (and buffer-file-name
                            (not (file-remote-p default-directory))
                            (+git-panel--root))))
        (let ((panel (+git-panel--window)))
          (unless (or (and panel (file-equal-p root (buffer-local-value
                                                     'default-directory
                                                     (window-buffer panel))))
                      ;; Big magit (or the live diff) already on screen.
                      (seq-find (lambda (w) (eq (buffer-local-value 'major-mode (window-buffer w))
                                                'magit-status-mode))
                                (window-list nil 'nomini)))
            (+git-panel-show root)))))))

;; A plain timer, not an idle one: files opened via emacsclient arrive
;; while Emacs is already idle, and idle timers would wait for a keypress.
(defun +git-panel-auto-h (&rest _)
  (when +git-panel-auto
    (run-at-time 0.3 nil #'+git-panel--maybe-show (selected-window))))

(add-hook 'doom-switch-buffer-hook #'+git-panel-auto-h)

(defun +git-panel--guard-h (frame)
  "Keep the panel showing only the panel; anything else opens in the main area."
  (when-let* ((win (+git-panel--window frame))
              (panel (window-parameter win '+git-panel))
              (buf (window-buffer win))
              ((not (eq buf panel))))
    (let ((main (+git-panel--main-window frame)))
      (if (buffer-live-p panel)
          (set-window-buffer win panel)
        (delete-window win))
      (when main
        (set-window-buffer main buf)
        (select-window main)))))

(add-hook 'window-buffer-change-functions #'+git-panel--guard-h)

(map! :leader :desc "Git panel" "o g" #'+git-panel-toggle)

(after! magit
  (define-derived-mode +git-panel-mode magit-status-mode "Git panel"
    "Narrow magit status for the right sidebar."
    (setq-local truncate-lines t
                ;; File list only, like VS Code; TAB on a file shows its diff.
                magit-section-initial-visibility-alist
                '((file . hide) (stashes . hide) (recent . hide)
                  (unpushed . hide) (unpulled . hide))))

  (defun +git-panel-refresh-buffer ()
    (magit-status-refresh-buffer))

  (defun +git-panel-visit-file ()
    "Open the file at point in the main area, not inside the panel."
    (interactive)
    (let ((main (+git-panel--main-window)))
      (magit-diff-visit-file--internal
       t (lambda (buf)
           (when main (select-window main))
           (switch-to-buffer buf)))))

  ;; Commands run from the panel (diffs, commit message, logs) open in
  ;; the main area instead of squeezing into the sidebar.
  (defadvice! +git-panel--display-in-main-a (&rest _)
    :before #'magit-display-buffer
    (when-let (((window-parameter nil '+git-panel))
               (main (+git-panel--main-window)))
      (select-window main)))

  ;; Staging in the panel updates the big magit status, and vice versa.
  (add-hook! 'magit-post-refresh-hook
    (defun +git-panel--sync-h ()
      (ignore-errors
        (when-let ((other (magit-get-mode-buffer
                           (if (derived-mode-p '+git-panel-mode)
                               'magit-status-mode
                             '+git-panel-mode))))
          (unless (or (eq other (current-buffer))
                      (not (get-buffer-window other 'visible)))
            (with-current-buffer other
              (magit-refresh-buffer)))))))

  (map! :map +git-panel-mode-map
        [remap magit-diff-visit-file]          #'+git-panel-visit-file
        [remap magit-diff-visit-worktree-file] #'+git-panel-visit-file
        :n "q" #'+git-panel-hide))


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
