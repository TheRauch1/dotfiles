;;; $DOOMDIR/gh.el -*- lexical-binding: t; -*-

;; GitHub pull requests, reviews and CI checks, driven by the gh CLI (so it
;; uses gh's login; nothing else to set up). SPC g p opens the menu; ? in any
;; gh buffer shows what you can do there. Loaded lazily from config.el.
;;
;; Every gh call is asynchronous, so a slow connection never freezes Emacs.
;; Buffers with running CI checks refresh themselves until the checks finish.

(require 'magit-section)
(require 'transient)
(require 'ansi-color)

(defvar +gh-refresh-interval 15
  "Seconds between refreshes of gh buffers that show running CI checks.")
(defvar +gh-auto-refresh t
  "Refresh gh buffers automatically while CI checks are running.")
(defvar +gh-pr-list-limit 50)
(defvar +gh-run-list-limit 30)
(defvar +gh-status-header t
  "Show the current branch's PR and CI status in magit status and the git panel.")


;;; Running gh

(defvar-local +gh-repo nil
  "OWNER/REPO this buffer shows, or nil for the repo of `default-directory'.")
(put '+gh-repo 'permanent-local t)

(defun +gh--args (args)
  (if +gh-repo (append args (list "-R" +gh-repo)) args))

(defun +gh--call (args callback &optional input errback)
  "Run `gh ARGS' asynchronously; call CALLBACK with its output on success.
INPUT is sent to gh's stdin. On failure call ERRBACK with gh's error
text, or show it in the echo area."
  (unless (executable-find "gh")
    (user-error "gh not found: install the GitHub CLI and run `gh auth login'"))
  (let* ((out (generate-new-buffer " *gh-out*"))
         (err (generate-new-buffer " *gh-err*"))
         (process-environment (append '("GH_PROMPT_DISABLED=1" "GH_NO_UPDATE_NOTIFIER=1"
                                        "GH_PAGER=cat" "NO_COLOR=1")
                                      process-environment))
         (proc (make-process
                :name "gh" :buffer out :stderr err :noquery t
                :connection-type 'pipe :command (cons "gh" args)
                :sentinel
                (lambda (p _)
                  (unless (process-live-p p)
                    (let ((stdout (with-current-buffer out (buffer-string)))
                          (stderr (string-trim (with-current-buffer err (buffer-string)))))
                      (kill-buffer out)
                      (let ((kill-buffer-query-functions nil)) (kill-buffer err))
                      (cond ((zerop (process-exit-status p)) (funcall callback stdout))
                            (errback (funcall errback stderr))
                            (t (message "gh %s: %s" (string-join (seq-take args 2) " ")
                                        (car (last (split-string stderr "\n" t))))))))))))
    (set-process-query-on-exit-flag (get-buffer-process err) nil)
    (when input
      (process-send-string proc input)
      (process-send-eof proc))
    proc))

(defun +gh--json (string)
  (json-parse-string string :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun +gh--root ()
  "Directory gh runs in: the git repo here, or anywhere if `+gh-repo' is set."
  (cond ((locate-dominating-file default-directory ".git"))
        (+gh-repo default-directory)
        ((user-error "Not in a git repo (SPC g p, then -R, picks another repo)"))))

(defun +gh--repo-name ()
  (or +gh-repo (file-name-nondirectory (directory-file-name (+gh--root)))))

(defun +gh--target-repo ()
  "Repo for a new gh buffer: the menu's -R option, else the current gh buffer's."
  (or (and (eq transient-current-command '+gh-dispatch)
           (transient-arg-value "--repo=" (transient-args '+gh-dispatch)))
      +gh-repo))


;;; Formatting

(defun +gh--face (string face)
  (propertize (or string "") 'face face 'font-lock-face face))

(defun +gh--time (iso)
  (and iso (not (string-prefix-p "0001" iso)) (date-to-time iso)))

(defun +gh--ago (iso)
  (if-let ((time (+gh--time iso)))
      (let ((s (truncate (float-time (time-subtract nil time)))))
        (cond ((< s 60) "now")
              ((< s 3600) (format "%dm" (/ s 60)))
              ((< s 86400) (format "%dh" (/ s 3600)))
              ((< s (* 86400 60)) (format "%dd" (/ s 86400)))
              ((< s (* 86400 365)) (format "%dmo" (/ s (* 86400 30))))
              (t (format "%dy" (/ s (* 86400 365))))))
    ""))

(defun +gh--duration (from to)
  "Duration between ISO times FROM and TO (TO missing = still running)."
  (if-let ((start (+gh--time from)))
      (let* ((s (max 0 (truncate (float-time (time-subtract (or (+gh--time to) nil) start)))))
             (d (cond ((< s 60) (format "%ds" s))
                      ((< s 3600) (format "%dm %ds" (/ s 60) (% s 60)))
                      (t (format "%dh %dm" (/ s 3600) (/ (% s 3600) 60))))))
        (if (+gh--time to) d (concat d "…")))
    ""))

(defun +gh--field (label value)
  (insert (+gh--face (format "%-9s" label) 'shadow) value "\n"))

(defun +gh--text (text &optional indent)
  "Insert markdown TEXT, fontified when markdown-mode is around, indented."
  (let ((text (string-trim (replace-regexp-in-string
                             "<!--\\(?:.\\|\n\\)*?-->\\|\r" "" (or text ""))))
        (indent (or indent "  ")))
    (if (string-empty-p text)
        (insert indent (+gh--face "(no description)" 'shadow) "\n")
      (when (fboundp 'gfm-mode)
        (setq text (with-temp-buffer
                     (insert text)
                     (delay-mode-hooks (gfm-mode))
                     (font-lock-ensure)
                     (let ((pos (point-min)) next)
                       (while (< pos (point-max))
                         (setq next (next-single-property-change pos 'face nil (point-max)))
                         (when-let ((f (get-text-property pos 'face)))
                           (put-text-property pos next 'font-lock-face f))
                         (setq pos next)))
                     (buffer-string))))
      (insert (replace-regexp-in-string "^" indent text) "\n"))))


;;; CI checks (statusCheckRollup entries, workflow jobs and steps)

(defun +gh--bucket (check)
  "One of pass, fail, pending, skip or cancel for CHECK."
  (let ((status (upcase (or (alist-get 'status check) "")))
        (result (upcase (or (alist-get 'conclusion check) (alist-get 'state check) ""))))
    (cond ((member status '("QUEUED" "IN_PROGRESS" "WAITING" "PENDING" "REQUESTED")) 'pending)
          ((equal result "SUCCESS") 'pass)
          ((member result '("FAILURE" "ERROR" "TIMED_OUT" "STARTUP_FAILURE" "ACTION_REQUIRED")) 'fail)
          ((equal result "CANCELLED") 'cancel)
          ((member result '("SKIPPED" "NEUTRAL" "STALE")) 'skip)
          (t 'pending))))

(defun +gh--icon (bucket)
  (pcase bucket
    ('pass    (+gh--face "✓" 'success))
    ('fail    (+gh--face "✗" 'error))
    ('pending (+gh--face "●" 'warning))
    ('cancel  (+gh--face "⊘" 'shadow))
    (_        (+gh--face "-" 'shadow))))

(defun +gh--rollup (checks)
  "Overall bucket of CHECKS, or nil when there are none."
  (let ((buckets (mapcar #'+gh--bucket checks)))
    (cond ((null buckets) nil)
          ((memq 'fail buckets) 'fail)
          ((memq 'pending buckets) 'pending)
          ((memq 'cancel buckets) 'cancel)
          ((memq 'pass buckets) 'pass)
          (t 'skip))))

(defun +gh--counts (checks)
  "Like \"✓ 5  ✗ 1  ● 2\"."
  (let ((buckets (mapcar #'+gh--bucket checks)))
    (string-join
     (delq nil (mapcar (lambda (b)
                         (let ((n (seq-count (lambda (x) (eq x b)) buckets)))
                           (and (> n 0) (format "%s %d" (+gh--icon b) n))))
                       '(pass fail pending cancel skip)))
     "  ")))

(defun +gh--check-name (check)
  (let-alist check
    (cond (.context)
          ((and .workflowName (not (string-empty-p .workflowName)))
           (concat .workflowName " / " .name))
          (t .name))))

(defun +gh--sort-checks (checks)
  (let ((rank '(fail 0 pending 1 cancel 2 pass 3 skip 4)))
    (sort (copy-sequence checks)
          (lambda (a b)
            (let ((ra (plist-get rank (+gh--bucket a)))
                  (rb (plist-get rank (+gh--bucket b))))
              (if (= ra rb)
                  (string< (+gh--check-name a) (+gh--check-name b))
                (< ra rb)))))))

(defun +gh--insert-checks (checks &optional indent)
  "Insert one `+gh-check' section per check; skipped ones folded away."
  (let* ((indent (or indent "  "))
         (width (min 60 (apply #'max 10 (mapcar (lambda (c) (length (+gh--check-name c))) checks))))
         (skipped (seq-filter (lambda (c) (eq (+gh--bucket c) 'skip)) checks)))
    (cl-flet ((insert-check (c)
                (magit-insert-section (+gh-check c)
                  (insert indent (+gh--icon (+gh--bucket c)) " "
                          (truncate-string-to-width (+gh--check-name c) width nil ?\s "…") "  "
                          (+gh--face (if (eq (+gh--bucket c) 'skip) ""
                                       (let-alist c (+gh--duration .startedAt .completedAt)))
                                     'shadow)
                          "\n"))))
      (mapc #'insert-check (seq-difference (+gh--sort-checks checks) skipped #'eq))
      (when skipped
        (magit-insert-section (+gh-skipped nil t)
          (magit-insert-heading indent (+gh--face (format "- %d skipped (TAB shows them)" (length skipped)) 'shadow))
          (mapc #'insert-check skipped))))))

(defun +gh--job-url-parts (url)
  "(REPO RUN-ID JOB-ID) from a GitHub Actions job URL, or nil."
  (when (and url (string-match "github\\.com/\\([^/]+/[^/]+\\)/actions/runs/\\([0-9]+\\)\\(?:/job/\\([0-9]+\\)\\)?" url))
    (list (match-string 1 url) (match-string 2 url) (match-string 3 url))))

(defun +gh--pending-p (checks)
  (seq-some (lambda (c) (eq (+gh--bucket c) 'pending)) checks))


;;; Buffers

(defvar-local +gh--data nil "What this buffer shows, as parsed JSON.")
(defvar-local +gh--fetch nil "Function that refetches this buffer's data.")
(defvar-local +gh--render nil "Function that inserts `+gh--data'.")
(defvar-local +gh--timer nil)
(defvar-local +gh--watching nil "Non-nil while CI was running at the last refresh.")

(define-derived-mode +gh-mode magit-section-mode "gh"
  "Base mode for gh buffers."
  :interactive nil
  (setq-local truncate-lines t
              revert-buffer-function (lambda (&rest _) (+gh-refresh)))
  (add-hook 'kill-buffer-hook #'+gh--stop-timer nil t)
  (when (fboundp 'doom-mark-buffer-as-real-h)
    (doom-mark-buffer-as-real-h)))

(defun +gh--buffer (name mode)
  "Get or make the gh buffer NAME in MODE for the current repo."
  (let ((repo (+gh--target-repo))
        (dir (let ((+gh-repo (+gh--target-repo))) (+gh--root))))
    (with-current-buffer (get-buffer-create name)
      (unless (eq major-mode mode) (funcall mode))
      (setq default-directory dir
            +gh-repo repo)
      (current-buffer))))

(defvar-local +gh--previous nil "Buffer that q goes back to.")
(put '+gh--previous 'permanent-local t)

(defun +gh--show (buffer)
  "Show BUFFER in the main window (never squeezed into a sidebar or popup)."
  (when (or (window-parameter nil 'window-side) (window-dedicated-p))
    (select-window (get-largest-window nil nil t)))
  (let ((prev (window-buffer)))
    (unless (eq prev buffer)
      (with-current-buffer buffer (setq +gh--previous prev))))
  (switch-to-buffer buffer))

(defun +gh-quit ()
  "Go back to where this buffer was opened from."
  (interactive)
  (let ((buf (current-buffer)))
    (if (and (buffer-live-p +gh--previous) (not (eq +gh--previous buf)))
        (progn (switch-to-buffer +gh--previous nil t)
               (bury-buffer buf))
      (quit-window))))

(defun +gh--redraw (buffer data)
  "Show DATA in BUFFER, keeping point on the same section."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((inhibit-read-only t)
             (section (magit-current-section))
             (ident (and section (magit-section-ident section)))
             (offset (and section (- (line-number-at-pos)
                                     (line-number-at-pos (oref section start)))))
             (line (line-number-at-pos))
             (win (get-buffer-window buffer))
             (start (and win (window-start win))))
        (setq +gh--data data)
        (erase-buffer)
        (magit-insert-section (+gh-root)
          (funcall +gh--render data))
        (magit-section-show magit-root-section)  ; applies the children's visibility
        (if-let ((s (and ident (magit-get-section ident))))
            (progn (goto-char (oref s start)) (forward-line offset))
          (goto-char (point-min))
          (forward-line (1- line)))
        (when win (set-window-start win (min start (point)) t))))))

(defun +gh-refresh ()
  "Fetch this buffer's data again."
  (interactive)
  (when +gh--fetch (funcall +gh--fetch)))

(defun +gh--stop-timer ()
  (when +gh--timer
    (cancel-timer +gh--timer)
    (setq +gh--timer nil)))

(defun +gh--watch (pending done-message)
  "Keep refreshing while PENDING; say DONE-MESSAGE once it stops."
  (when (and +gh--watching (not pending) done-message)
    (message "%s" done-message))
  (setq +gh--watching pending)
  (if (not (and pending +gh-auto-refresh))
      (+gh--stop-timer)
    (unless +gh--timer
      (let ((buf (current-buffer)))
        (setq +gh--timer
              (run-with-timer +gh-refresh-interval +gh-refresh-interval
                              (lambda ()
                                (when (and (buffer-live-p buf)
                                           (get-buffer-window buf 'visible))
                                  (with-current-buffer buf (+gh-refresh))))))))))

(defun +gh-toggle-auto-refresh ()
  "Turn auto-refresh of running CI checks on or off."
  (interactive)
  (setq +gh-auto-refresh (not +gh-auto-refresh))
  (if +gh-auto-refresh (+gh-refresh) (+gh--stop-timer))
  (message "gh auto-refresh %s" (if +gh-auto-refresh "on" "off")))

(defun +gh--refresh-all ()
  "Refresh visible gh buffers and magit status after something changed."
  (clrhash +gh--status-cache)
  (dolist (buf (buffer-list))
    (when (get-buffer-window buf 'visible)
      (with-current-buffer buf
        (cond ((derived-mode-p '+gh-mode) (+gh-refresh))
              ((derived-mode-p 'magit-status-mode) (magit-refresh-buffer)))))))


;;; What's at point

(defun +gh--thing ()
  "(TYPE . VALUE) for the innermost gh thing at point."
  (or (let ((s (magit-current-section)) found)
        (while (and s (not found))
          (when (memq (oref s type) '(+gh-check +gh-job +gh-run +gh-pr +gh-file +gh-commit))
            (setq found (cons (oref s type) (oref s value))))
          (setq s (oref s parent)))
        found)
      (pcase major-mode
        ('+gh-pr-mode  (cons '+gh-pr +gh--data))
        ('+gh-run-mode (cons '+gh-run +gh--data)))))

(defun +gh--pr ()
  "The PR at point (as parsed JSON), or the PR this buffer shows."
  (or (pcase (+gh--thing)
        (`(+gh-pr . ,pr) pr))
      (and (derived-mode-p '+gh-pr-mode) +gh--data)
      (user-error "No pull request here")))

(defun +gh--pr-number ()
  (number-to-string (alist-get 'number (+gh--pr))))

(defun +gh--url ()
  (pcase (+gh--thing)
    (`(+gh-check . ,c) (let-alist c (or .detailsUrl .targetUrl)))
    (`(+gh-file . ,_) (concat (alist-get 'url +gh--data) "/files"))
    (`(+gh-commit . ,c) (concat (alist-get 'url +gh--data) "/commits/" (alist-get 'oid c)))
    (`(,_ . ,v) (alist-get 'url v))))

(defun +gh-visit ()
  "Open the thing at point: a PR, run, check log, file diff or commit."
  (interactive)
  (pcase (+gh--thing)
    ((and `(+gh-pr . ,pr) (guard (not (derived-mode-p '+gh-pr-mode))))
     (+gh--pr-open (number-to-string (alist-get 'number pr))))
    ((and `(+gh-run . ,run) (guard (not (derived-mode-p '+gh-run-mode))))
     (+gh--run-open run))
    (`(,(or '+gh-check '+gh-job) . ,_) (+gh-log))
    (`(+gh-file . ,file) (+gh-pr-diff (alist-get 'path file)))
    (`(+gh-commit . ,c) (+gh--show-commit (alist-get 'oid c)))
    (_ (magit-section-toggle (magit-current-section)))))

(defun +gh-browse ()
  "Open the thing at point on github.com.
In a terminal frame (e.g. over SSH from the iPad) the URL is copied
instead; with OSC 52 it lands on the device's clipboard."
  (interactive)
  (let ((url (or (+gh--url) (user-error "Nothing to open here"))))
    (if (display-graphic-p)
        (browse-url url)
      (kill-new url)
      (message "Copied %s" url))))

(defun +gh-copy-url ()
  "Copy the URL of the thing at point."
  (interactive)
  (let ((url (or (+gh--url) (user-error "No URL here"))))
    (kill-new url)
    (message "Copied %s" url)))

(defun +gh--show-commit (oid)
  (if (and (fboundp 'magit-show-commit)
           (zerop (call-process "git" nil nil nil "cat-file" "-e" (concat oid "^{commit}"))))
      (magit-show-commit oid)
    (+gh-browse)))


;;; Pull request list

(defvar +gh-pr-list-filters
  '(("open"             "open"   nil)
    ("mine"             "open"   "author:@me")
    ("review requested" "open"   "review-requested:@me")
    ("merged"           "merged" nil)
    ("closed"           "closed" nil)
    ("all"              "all"    nil))
  "(NAME STATE SEARCH) choices for `f' in the PR list.")

(defvar-local +gh-pr-list--filter "open")
(defvar-local +gh-pr-list--search nil)

(define-derived-mode +gh-pr-list-mode +gh-mode "gh PRs"
  "Pull requests of a repo. ? shows the keys."
  :interactive nil
  (setq-local +gh--fetch #'+gh--pr-list-fetch
              +gh--render #'+gh--pr-list-render))

(defun +gh--review-icon (decision)
  (pcase decision
    ("APPROVED"          (+gh--face "✓" 'success))
    ("CHANGES_REQUESTED" (+gh--face "✗" 'error))
    ("REVIEW_REQUIRED"   (+gh--face "○" 'shadow))
    (_ " ")))

(defun +gh--pr-state (pr)
  (let-alist pr
    (cond ((equal .state "MERGED") (+gh--face "merged" 'font-lock-constant-face))
          ((equal .state "CLOSED") (+gh--face "closed" 'error))
          (.isDraft (+gh--face "draft" 'shadow))
          (t (+gh--face "open" 'success)))))

(defun +gh--pr-list-fetch ()
  (let* ((buf (current-buffer))
         (filter (assoc +gh-pr-list--filter +gh-pr-list-filters))
         (search (string-join (delq nil (list (nth 2 filter) +gh-pr-list--search)) " ")))
    (setq mode-line-process " loading…")
    (+gh--call (+gh--args
                `("pr" "list" "--state" ,(nth 1 filter) "-L" ,(number-to-string +gh-pr-list-limit)
                  ,@(unless (string-empty-p search) (list "--search" search))
                  "--json" "number,title,author,headRefName,isDraft,state,reviewDecision,statusCheckRollup,updatedAt,url"))
               (lambda (out)
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (setq mode-line-process nil)
                     (let ((prs (+gh--json out)))
                       (+gh--redraw buf prs)
                       (+gh--watch (seq-some (lambda (pr) (+gh--pending-p (alist-get 'statusCheckRollup pr))) prs)
                                   nil))))))))

(defun +gh--pr-list-render (prs)
  (insert (+gh--face "Pull requests" 'magit-section-heading) "  " (+gh--repo-name) "  "
          (+gh--face (concat "[" +gh-pr-list--filter
                             (if +gh-pr-list--search (concat " · " +gh-pr-list--search) "")
                             "]")
                     'font-lock-keyword-face)
          "\n"
          (+gh--face "RET open  TAB checks  f filter  / search  c checkout  m merge  ? more\n\n" 'shadow))
  (if (null prs)
      (insert (+gh--face "  No pull requests.\n" 'shadow))
    (let ((nw (1+ (length (number-to-string (apply #'max (mapcar (lambda (p) (alist-get 'number p)) prs)))))))
      (dolist (pr prs)
        (let-alist pr
          (magit-insert-section (+gh-pr pr t)
            (magit-insert-heading
              (+gh--face (string-pad (format "#%d" .number) nw t)
                         (pcase .state ("MERGED" 'font-lock-constant-face) ("CLOSED" 'error)
                                (_ (if .isDraft 'shadow 'font-lock-keyword-face))))
              " " (if-let ((b (+gh--rollup .statusCheckRollup))) (+gh--icon b) " ")
              " " (+gh--review-icon .reviewDecision)
              " " (+gh--face (string-pad (+gh--ago .updatedAt) 4) 'shadow)
              " " (+gh--face (truncate-string-to-width (or .author.login "") 12 nil ?\s "…")
                             'font-lock-function-name-face)
              " " (if .isDraft (+gh--face (concat "[draft] " .title) 'shadow) .title)
              "  " (+gh--face .headRefName 'font-lock-variable-name-face))
            (if .statusCheckRollup
                (+gh--insert-checks .statusCheckRollup (make-string (+ nw 3) ?\s))
              (insert (make-string (+ nw 3) ?\s) (+gh--face "no checks\n" 'shadow)))))))))

(defun +gh--pr-list-open (filter)
  (let ((buf (+gh--buffer (format "*gh PRs: %s*" (let ((+gh-repo (+gh--target-repo))) (+gh--repo-name)))
                          '+gh-pr-list-mode)))
    (with-current-buffer buf
      (setq +gh-pr-list--filter filter
            +gh-pr-list--search nil)
      (+gh-refresh))
    (+gh--show buf)))

(defun +gh-pr-list ()
  "Open pull requests."
  (interactive)
  (+gh--pr-list-open "open"))

(defun +gh-pr-list-mine ()
  "My open pull requests."
  (interactive)
  (+gh--pr-list-open "mine"))

(defun +gh-pr-list-review ()
  "Pull requests waiting for my review."
  (interactive)
  (+gh--pr-list-open "review requested"))

(defun +gh-pr-list-filter (filter)
  "Show only PRs matching FILTER (open, mine, review requested, merged, ...)."
  (interactive (list (completing-read "Show PRs: " (mapcar #'car +gh-pr-list-filters) nil t)))
  (setq +gh-pr-list--filter filter)
  (+gh-refresh))

(defun +gh-pr-list-search (query)
  "Narrow the PR list with a GitHub search QUERY (empty clears it).
E.g. `label:bug', `author:alice', `fix parser'."
  (interactive (list (read-string "Search PRs (empty = clear): " +gh-pr-list--search)))
  (setq +gh-pr-list--search (unless (string-empty-p query) query))
  (+gh-refresh))


;;; One pull request

(defconst +gh--pr-fields
  (concat "number,title,body,author,state,isDraft,headRefName,baseRefName,url,"
          "mergeable,mergeStateStatus,reviewDecision,reviewRequests,latestReviews,"
          "additions,deletions,changedFiles,files,comments,reviews,commits,"
          "statusCheckRollup,labels,createdAt,autoMergeRequest"))

(define-derived-mode +gh-pr-mode +gh-mode "gh PR"
  "One pull request: checks, conversation, files. ? shows the keys."
  :interactive nil
  (setq-local +gh--fetch #'+gh--pr-fetch
              +gh--render #'+gh--pr-render)
  ;; Descriptions and comments wrap at word boundaries, keeping their indent.
  (setq-local truncate-lines nil
              word-wrap t)
  (when (fboundp 'visual-wrap-prefix-mode) (visual-wrap-prefix-mode 1))
  ;; Long conversations: start with the checks and description in view.
  (setq-local magit-section-initial-visibility-alist
              '((+gh-files . hide) (+gh-commits . hide))))

(defun +gh--pr-open (selector)
  "Fetch the PR named by SELECTOR (number, URL or nil = this branch) and show it."
  (let ((repo (+gh--target-repo))
        (dir (let ((+gh-repo (+gh--target-repo))) (+gh--root))))
    (message "Loading pull request…")
    (let ((default-directory dir)
          (+gh-repo repo))
      (+gh--call (+gh--args `("pr" "view" ,@(and selector (list selector)) "--json" ,+gh--pr-fields))
                 (lambda (out)
                   (let* ((pr (+gh--json out))
                          (+gh-repo repo)
                          (default-directory dir)
                          (buf (+gh--buffer (format "*gh PR #%d: %s*" (alist-get 'number pr)
                                                    (+gh--repo-name))
                                            '+gh-pr-mode)))
                     (with-current-buffer buf
                       (+gh--pr-loaded pr))
                     (+gh--show buf)
                     (message nil)))))))

(defun +gh--repo-from-url (url)
  (and url (string-match "github\\.com/\\([^/]+/[^/]+\\)/" url) (match-string 1 url)))

(defun +gh--pr-fetch ()
  (let ((buf (current-buffer)))
    (setq mode-line-process " loading…")
    (+gh--call (+gh--args (list "pr" "view" (number-to-string (alist-get 'number +gh--data))
                                "--json" +gh--pr-fields))
               (lambda (out)
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (setq mode-line-process nil)
                     (+gh--pr-loaded (+gh--json out))))))))

(defun +gh--pr-loaded (pr)
  (+gh--redraw (current-buffer) pr)
  (let* ((checks (alist-get 'statusCheckRollup pr))
         (fails (seq-count (lambda (c) (eq (+gh--bucket c) 'fail)) checks)))
    (+gh--watch (+gh--pending-p checks)
                (format "PR #%d: %s" (alist-get 'number pr)
                        (if (> fails 0)
                            (format "%d check%s failed" fails (if (= fails 1) "" "s"))
                          "all checks passed")))))

(defun +gh--pr-review-summary (pr)
  (let-alist pr
    (string-join
     (delq nil
           (append
            (list (pcase .reviewDecision
                    ("APPROVED" (+gh--face "approved" 'success))
                    ("CHANGES_REQUESTED" (+gh--face "changes requested" 'error))
                    ("REVIEW_REQUIRED" (+gh--face "review required" 'warning))))
            (mapcar (lambda (r)
                      (let-alist r
                        (pcase .state
                          ("APPROVED" (concat (+gh--face "✓ " 'success) .author.login))
                          ("CHANGES_REQUESTED" (concat (+gh--face "✗ " 'error) .author.login))
                          ("COMMENTED" (concat (+gh--face "💬 " 'shadow) .author.login)))))
                    .latestReviews)
            (mapcar (lambda (r) (let-alist r (concat (+gh--face "○ " 'shadow) (or .login .name .slug))))
                    .reviewRequests)))
     "  ")))

(defun +gh--pr-merge-summary (pr)
  (let-alist pr
    (string-join
     (delq nil
           (list (cond ((member .state '("MERGED" "CLOSED")) nil)
                       ((equal .mergeable "CONFLICTING") (+gh--face "conflicts" 'error))
                       ((member .mergeStateStatus '("CLEAN" "HAS_HOOKS")) (+gh--face "ready" 'success))
                       ((equal .mergeStateStatus "BEHIND") (+gh--face "behind base" 'warning))
                       ((member .mergeStateStatus '("BLOCKED" "UNSTABLE")) (+gh--face "blocked" 'warning))
                       (.mergeStateStatus (downcase .mergeStateStatus)))
                 (and .autoMergeRequest
                      (+gh--face (format "auto-merge (%s)" (downcase (or .autoMergeRequest.mergeMethod "on")))
                                 'font-lock-keyword-face))
                 (format "%s %s in %d file%s"
                         (+gh--face (format "+%d" .additions) 'success)
                         (+gh--face (format "-%d" .deletions) 'error)
                         .changedFiles (if (= .changedFiles 1) "" "s"))))
     " · ")))

(defun +gh--pr-render (pr)
  (let-alist pr
    (magit-insert-section (+gh-pr-header)
      (insert (+gh--face (format "#%d " .number) 'shadow)
              (+gh--face .title 'magit-section-heading) "\n")
      (+gh--field "State" (concat (+gh--pr-state pr) "  "
                                  (+gh--face .author.login 'font-lock-function-name-face) "  "
                                  (+gh--face .headRefName 'font-lock-variable-name-face) " → "
                                  (+gh--face .baseRefName 'font-lock-variable-name-face) "  "
                                  (+gh--face (+gh--ago .createdAt) 'shadow)))
      (+gh--field "Review" (+gh--pr-review-summary pr))
      (+gh--field "Merge" (+gh--pr-merge-summary pr))
      (when .labels
        (+gh--field "Labels" (mapconcat (lambda (l) (+gh--face (alist-get 'name l) 'font-lock-type-face))
                                        .labels ", ")))
      (+gh--field "URL" .url)
      (insert (+gh--face "RET open  d diff  c checkout  a approve  C comment  m merge  L log  R rerun  ? more\n" 'shadow)
              "\n"))
    (magit-insert-section (+gh-checks)
      (magit-insert-heading (+gh--face "Checks" 'magit-section-heading) "  " (+gh--counts .statusCheckRollup)
        (if .statusCheckRollup "" (+gh--face "none" 'shadow)))
      (+gh--insert-checks .statusCheckRollup)
      (insert "\n"))
    (magit-insert-section (+gh-body)
      (magit-insert-heading (+gh--face "Description" 'magit-section-heading))
      (+gh--text .body)
      (insert "\n"))
    (let ((events (sort (append (mapcar (lambda (c) (cons 'comment c)) .comments)
                                (seq-filter (lambda (r)
                                              (let-alist (cdr r)
                                                (or (not (string-empty-p (or .body "")))
                                                    (member .state '("APPROVED" "CHANGES_REQUESTED")))))
                                            (mapcar (lambda (r) (cons 'review r)) .reviews)))
                        (lambda (a b)
                          (string< (or (alist-get 'createdAt (cdr a)) (alist-get 'submittedAt (cdr a)) "")
                                   (or (alist-get 'createdAt (cdr b)) (alist-get 'submittedAt (cdr b)) ""))))))
      (magit-insert-section (+gh-conversation)
        (magit-insert-heading (+gh--face (format "Conversation (%d)" (length events)) 'magit-section-heading))
        (dolist (e events)
          (let-alist (cdr e)
            (magit-insert-section (+gh-comment (cdr e))
              (magit-insert-heading
                "  " (+gh--face .author.login 'font-lock-function-name-face) " "
                (if (eq (car e) 'comment)
                    (+gh--face "commented" 'shadow)
                  (pcase .state
                    ("APPROVED" (+gh--face "approved" 'success))
                    ("CHANGES_REQUESTED" (+gh--face "requested changes" 'error))
                    (_ (+gh--face "reviewed" 'shadow))))
                " " (+gh--face (+gh--ago (or .createdAt .submittedAt)) 'shadow))
              (unless (string-empty-p (string-trim (or .body "")))
                (+gh--text .body "    ")))))
        (insert "\n")))
    (magit-insert-section (+gh-files)
      (magit-insert-heading (+gh--face (format "Files (%d)" .changedFiles) 'magit-section-heading))
      (dolist (f .files)
        (let-alist f
          (magit-insert-section (+gh-file f)
            (insert "  " (+gh--face (string-pad (format "+%d" .additions) 6 nil t) 'success)
                    " " (+gh--face (string-pad (format "-%d" .deletions) 6) 'error)
                    " " .path "\n"))))
      (insert "\n"))
    (magit-insert-section (+gh-commits)
      (magit-insert-heading (+gh--face (format "Commits (%d)" (length .commits)) 'magit-section-heading))
      (dolist (c .commits)
        (let-alist c
          (magit-insert-section (+gh-commit c)
            (insert "  " (+gh--face (substring .oid 0 7) 'font-lock-constant-face) " "
                    .messageHeadline "\n")))))))

(defun +gh-pr-view (selector)
  "Show a pull request, by number or URL."
  (interactive (list (read-string "Pull request (number or URL): ")))
  (+gh--pr-open selector))

(defun +gh-pr-view-current ()
  "Show the pull request of the current branch."
  (interactive)
  (+gh--pr-open nil))


;;; Diffs and logs

(defun +gh-pr-diff (&optional file)
  "Show the PR's diff (jumping to FILE)."
  (interactive)
  (let* ((n (+gh--pr-number))
         (name (format "*gh diff #%s: %s*" n (+gh--repo-name)))
         (repo +gh-repo) (dir default-directory))
    (message "Loading diff…")
    (+gh--call (+gh--args (list "pr" "diff" n "--color=never"))
               (lambda (out)
                 (with-current-buffer (get-buffer-create name)
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert out))
                   (+gh-diff-mode)
                   (setq buffer-read-only t
                         default-directory dir
                         +gh-repo repo)
                   (goto-char (point-min))
                   (when file
                     (re-search-forward (concat "^diff --git a/" (regexp-quote file) " ") nil t)
                     (beginning-of-line))
                   (+gh--show (current-buffer))
                   (message nil))))))

(define-derived-mode +gh-diff-mode diff-mode "gh diff"
  "A pull request's diff."
  :interactive nil
  (setq-local diff-refine 'font-lock))

;; evil-collection's diff keys (a minor mode) would shadow a major-mode q.
(add-hook '+gh-diff-mode-hook
          (defun +gh-diff-bind-quit-h () (evil-local-set-key 'normal "q" #'+gh-quit)))

(defvar-local +gh-log--job nil "(REPO RUN-ID JOB-ID NAME URL FAILED) of this log.")

(define-derived-mode +gh-log-mode special-mode "gh log"
  "A GitHub Actions job log. ]e / [e jump between errors."
  :interactive nil
  (setq-local revert-buffer-function (lambda (&rest _) (+gh--log-fetch))))

(defun +gh-log ()
  "Show the log of the check or job at point (only the failed steps, if any)."
  (interactive)
  (pcase-let* ((`(,type . ,v) (or (+gh--thing) (user-error "Move to a check or job first")))
               (url (pcase type
                      ('+gh-check (let-alist v (or .detailsUrl .targetUrl)))
                      ('+gh-job (alist-get 'url v))
                      (_ (user-error "Move to a check or job first"))))
               (`(,repo ,run ,job) (+gh--job-url-parts url)))
    (when (and (eq type '+gh-job) (not job))
      (setq repo (or +gh-repo (+gh--repo-from-url url))
            run (number-to-string (alist-get 'databaseId +gh--data))
            job (number-to-string (alist-get 'databaseId v))))
    (unless job
      (if url
          (progn (message "Not a GitHub Actions job; opening it instead") (+gh-browse))
        (user-error "This check has no log")))
    (let ((buf (get-buffer-create (format "*gh log: %s*" (or (alist-get 'name v) (+gh--check-name v))))))
      (with-current-buffer buf
        (+gh-log-mode)
        (setq +gh-log--job (list repo run job (or (alist-get 'name v) (+gh--check-name v)) url
                                 (eq (+gh--bucket v) 'fail)))
        (+gh--log-fetch))
      (+gh--show buf))))

(defun +gh--log-fetch ()
  (pcase-let ((`(,repo ,_run ,job ,name ,_url ,failed) +gh-log--job)
              (buf (current-buffer)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (+gh--face (format "Loading log of %s…\n" name) 'shadow)))
    (cl-labels
        ((fetch (failed-only)
           (+gh--call `("run" "view" "--job" ,job ,(if failed-only "--log-failed" "--log")
                        ,@(and repo (list "-R" repo)))
                      (lambda (out)
                        (if (and failed-only (string-empty-p (string-trim out)))
                            (fetch nil)
                          (+gh--log-insert buf out)))
                      nil
                      (lambda (err) (+gh--log-insert buf nil err)))))
      (fetch failed))))

(defun +gh--log-insert (buf log &optional err)
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (ansi-color-apply-face-function
             (lambda (beg end face)
               (when face (put-text-property beg end 'face face)))))
        (erase-buffer)
        (if err
            (insert (+gh--face (concat err "\n\n") 'error)
                    "Logs of running jobs only arrive when the job finishes.\n"
                    "o opens the job on github.com, gr tries again.\n")
          (insert log)
          (+gh--log-clean)
          (ansi-color-apply-on-region (point-min) (point-max)))
        (goto-char (point-min))
        (unless (+gh-log-next-error)
          (goto-char (point-max)))))))

(defconst +gh--log-error-re
  "\\(?:^\\|[^[:alnum:]_-]\\)\\(error\\|Error\\|ERROR\\|FAIL\\(?:ED\\)?\\|panicked\\|Traceback\\)\\(?:[^[:alnum:]_-]\\|$\\)")

(defun +gh--log-clean ()
  "Turn gh's `JOB<TAB>STEP<TAB>TIME text' lines into text with step headings."
  (goto-char (point-min))
  (when (looking-at "﻿") (replace-match ""))
  (let (step)
    (while (not (eobp))
      (when (looking-at "^[^\t\n]*\t\\([^\t\n]*\\)\t\\(?:﻿?[0-9-]+T[0-9:.]+Z ?\\)?")
        (let ((s (match-string 1)))
          (replace-match "")
          (unless (equal s step)
            (setq step s)
            (insert (+gh--face (concat "━━ " s " ━━") 'magit-section-heading) "\n"))))
      (cond ((looking-at "##\\[endgroup\\].*\n?") (replace-match ""))
            ((looking-at "##\\[group\\]\\(.*\\)")
             (replace-match (+gh--face (concat "▸ " (match-string 1)) 'bold) t t))
            ((looking-at "##\\[error\\]") (replace-match (+gh--face "Error: " 'error) t t))
            ((looking-at "##\\[warning\\]") (replace-match (+gh--face "Warning: " 'warning) t t))
            ((looking-at "##\\[\\(?:notice\\|debug\\)\\]") (replace-match ""))
            (t (forward-line 1)))))
  (goto-char (point-min))
  (let ((case-fold-search nil))
    (while (re-search-forward +gh--log-error-re nil t)
      (put-text-property (match-beginning 1) (match-end 1) 'face 'error))))

(defun +gh-log-next-error ()
  "Jump to the next line that looks like an error."
  (interactive)
  (let ((case-fold-search nil)
        (pos (save-excursion (end-of-line) (re-search-forward +gh--log-error-re nil t))))
    (if pos
        (progn (goto-char pos) (beginning-of-line) (recenter) t)
      (when (called-interactively-p 'any) (message "No more errors"))
      nil)))

(defun +gh-log-previous-error ()
  "Jump to the previous line that looks like an error."
  (interactive)
  (let ((case-fold-search nil))
    (if (save-excursion (beginning-of-line) (re-search-backward +gh--log-error-re nil t))
        (progn (goto-char (match-beginning 0)) (beginning-of-line) (recenter))
      (message "No earlier errors"))))

(defun +gh-log-browse ()
  "Open this job on github.com (copy its URL in a terminal)."
  (interactive)
  (let ((url (nth 4 +gh-log--job)))
    (if (display-graphic-p)
        (browse-url url)
      (kill-new url)
      (message "Copied %s" url))))


;;; Acting on pull requests

(defun +gh--do (args done &optional input)
  "Run gh ARGS (against this buffer's repo), then say DONE and refresh."
  (message "gh %s…" (string-join (seq-take args 3) " "))
  (+gh--call (+gh--args args)
             (lambda (_) (message "%s" done) (+gh--refresh-all))
             input))

(defvar-local +gh-compose--send nil)

(define-minor-mode +gh-compose-mode
  "Write a comment, review or PR description. C-c C-c sends, C-c C-k cancels."
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'+gh-compose-send)
            (define-key map (kbd "C-c C-k") #'+gh-compose-cancel)
            map))

(defun +gh--compose (title send &optional initial)
  "Edit text in a buffer; C-c C-c calls SEND with it."
  (let ((repo +gh-repo)
        (dir default-directory)
        (buf (generate-new-buffer (format "*gh: %s*" title))))
    (with-current-buffer buf
      (if (fboundp 'gfm-mode) (gfm-mode) (text-mode))
      (setq default-directory dir
            +gh-repo repo
            +gh-compose--send send
            header-line-format (format " %s   C-c C-c send  ·  C-c C-k cancel" title))
      (+gh-compose-mode 1)
      (when initial (insert initial) (goto-char (point-min))))
    (pop-to-buffer buf)
    (when (bound-and-true-p evil-local-mode) (evil-insert-state))))

(defun +gh-compose-send ()
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (send +gh-compose--send))
    (when (string-empty-p text) (user-error "Nothing written"))
    (funcall send text)
    (quit-window 'kill)))

(defun +gh-compose-cancel ()
  (interactive)
  (when (or (string-empty-p (string-trim (buffer-string)))
            (y-or-n-p "Throw away what you wrote? "))
    (quit-window 'kill)))

(defun +gh-pr-comment ()
  "Comment on the pull request."
  (interactive)
  (let ((n (+gh--pr-number)))
    (+gh--compose (format "Comment on #%s" n)
                  (lambda (text) (+gh--do (list "pr" "comment" n "--body-file" "-")
                                          (format "Commented on #%s" n) text)))))

(defun +gh-pr-approve ()
  "Approve the pull request."
  (interactive)
  (let ((n (+gh--pr-number)))
    (when (y-or-n-p (format "Approve #%s? " n))
      (+gh--do (list "pr" "review" n "--approve") (format "Approved #%s" n)))))

(defun +gh-pr-request-changes ()
  "Request changes on the pull request (with a comment)."
  (interactive)
  (let ((n (+gh--pr-number)))
    (+gh--compose (format "Request changes on #%s" n)
                  (lambda (text) (+gh--do (list "pr" "review" n "--request-changes" "--body-file" "-")
                                          (format "Requested changes on #%s" n) text)))))

(defun +gh-pr-add-reviewer (who)
  "Ask WHO (comma-separated logins) to review the pull request."
  (interactive (list (read-string "Request review from (logins, comma-separated): ")))
  (let ((n (+gh--pr-number)))
    (+gh--do (list "pr" "edit" n "--add-reviewer" who) (format "Asked %s to review #%s" who n))))

(defun +gh-pr-checkout ()
  "Check out the pull request's branch locally."
  (interactive)
  (let ((n (+gh--pr-number)))
    (+gh--do (list "pr" "checkout" n) (format "Checked out #%s" n))))

(defun +gh-pr-toggle-draft ()
  "Mark the pull request ready for review, or back to draft."
  (interactive)
  (let* ((pr (+gh--pr))
         (n (+gh--pr-number)))
    (if (alist-get 'isDraft pr)
        (+gh--do (list "pr" "ready" n) (format "#%s is ready for review" n))
      (+gh--do (list "pr" "ready" n "--undo") (format "#%s is a draft again" n)))))

(defun +gh-pr-toggle-closed ()
  "Close the pull request, or reopen it."
  (interactive)
  (let* ((pr (+gh--pr))
         (n (+gh--pr-number)))
    (if (equal (alist-get 'state pr) "OPEN")
        (when (yes-or-no-p (format "Close #%s without merging? " n))
          (+gh--do (list "pr" "close" n) (format "Closed #%s" n)))
      (+gh--do (list "pr" "reopen" n) (format "Reopened #%s" n)))))

(defun +gh--merge (method)
  (let ((n (+gh--pr-number))
        (args (transient-args '+gh-pr-merge)))
    (when (yes-or-no-p (format "%s #%s (%s)%s? "
                               (if (member "--auto" args) "Auto-merge" "Merge") n method
                               (if (member "--delete-branch" args) " and delete the branch" "")))
      (+gh--do `("pr" "merge" ,n ,(concat "--" method) ,@args)
               (if (member "--auto" args)
                   (format "#%s will merge when its checks pass" n)
                 (format "Merged #%s" n))))))

(transient-define-suffix +gh-pr-merge-squash () "Squash and merge." (interactive) (+gh--merge "squash"))
(transient-define-suffix +gh-pr-merge-commit () "Merge commit." (interactive) (+gh--merge "merge"))
(transient-define-suffix +gh-pr-merge-rebase () "Rebase and merge." (interactive) (+gh--merge "rebase"))

(transient-define-prefix +gh-pr-merge ()
  "Merge the pull request."
  ["Options"
   ("-d" "Delete branch afterwards" "--delete-branch")
   ("-a" "Wait for checks (auto-merge)" "--auto")
   ("-A" "Admin: skip requirements" "--admin")]
  ["Merge"
   ("s" "Squash" +gh-pr-merge-squash)
   ("m" "Merge commit" +gh-pr-merge-commit)
   ("r" "Rebase" +gh-pr-merge-rebase)])


;;; Creating pull requests

(defun +gh--git (&rest args)
  (with-temp-buffer
    (and (zerop (apply #'call-process "git" nil t nil args))
         (string-trim (buffer-string)))))

(defun +gh--ensure-pushed ()
  "Offer to push the current branch when GitHub doesn't have all of it yet."
  (let ((branch (or (+gh--git "symbolic-ref" "--short" "-q" "HEAD")
                    (user-error "Detached HEAD: check out a branch first")))
        (ahead (and (+gh--git "rev-parse" "--abbrev-ref" "@{upstream}")
                    (string-to-number (+gh--git "rev-list" "--count" "@{upstream}..HEAD"))))
        (remote (let ((remotes (split-string (or (+gh--git "remote") "") "\n" t)))
                  (if (member "origin" remotes) "origin" (car remotes)))))
    (when (and (or (null ahead) (> ahead 0))
               (y-or-n-p (if ahead
                             (format "Push %d new commit%s on %s first? " ahead (if (= ahead 1) "" "s") branch)
                           (format "Push %s to %s first? " branch remote))))
      (message "Pushing %s…" branch)
      (redisplay)
      (unless (zerop (call-process "git" nil nil nil "push" "-u" remote "HEAD"))
        (user-error "git push failed; push from magit (P p) to see why")))))

(defun +gh--pr-template ()
  "Title and body suggested by the branch's commits, gh --fill style."
  (let* ((base (+gh--git "rev-parse" "--abbrev-ref" "origin/HEAD"))
         (subjects (and base (split-string (or (+gh--git "log" "--reverse" "--format=%s" (concat base "..HEAD")) "")
                                           "\n" t))))
    (if (<= (length subjects) 1)
        (or (+gh--git "log" "-1" "--format=%B") "")
      (concat (capitalize (replace-regexp-in-string "[-_/]" " " (+gh--git "symbolic-ref" "--short" "HEAD")))
              "\n\n"
              (mapconcat (lambda (s) (concat "- " s)) subjects "\n")))))

(defun +gh--pr-created (out)
  (clrhash +gh--status-cache)
  (if-let ((url (and (string-match "https://\\S-+/pull/[0-9]+" out) (match-string 0 out))))
      (+gh--pr-open url)
    (message "%s" (string-trim out))))

(transient-define-suffix +gh-pr-create-write ()
  "Write the title and description, then create."
  (interactive)
  (let ((args (transient-args '+gh-pr-create))
        (default-directory (+gh--root)))
    (+gh--ensure-pushed)
    (+gh--compose "New pull request (first line = title)"
                  (lambda (text)
                    (let ((title (car (split-string text "\n")))
                          (body (string-trim (string-join (cdr (split-string text "\n")) "\n"))))
                      (message "Creating pull request…")
                      (+gh--call `("pr" "create" "--title" ,title "--body-file" "-" ,@args)
                                 #'+gh--pr-created body)))
                  (+gh--pr-template))))

(transient-define-suffix +gh-pr-create-fill ()
  "Create straight away, titled and described by the commits."
  (interactive)
  (let ((args (transient-args '+gh-pr-create))
        (default-directory (+gh--root)))
    (+gh--ensure-pushed)
    (message "Creating pull request…")
    (+gh--call `("pr" "create" "--fill" ,@args) #'+gh--pr-created)))

(transient-define-prefix +gh-pr-create ()
  "Open a pull request for the current branch."
  ["Options"
   ("-d" "Draft" "--draft")
   ("-b" "Base branch" "--base=")
   ("-r" "Reviewers (comma-separated)" "--reviewer=")]
  ["Create"
   ("c" "Write title & description" +gh-pr-create-write)
   ("f" "From commit messages, no questions" +gh-pr-create-fill)])


;;; Workflow runs

(defvar-local +gh-run-list--branch nil)

(define-derived-mode +gh-run-list-mode +gh-mode "gh runs"
  "GitHub Actions runs of a repo. ? shows the keys."
  :interactive nil
  (setq-local +gh--fetch #'+gh--run-list-fetch
              +gh--render #'+gh--run-list-render))

(define-derived-mode +gh-run-mode +gh-mode "gh run"
  "One GitHub Actions run with its jobs and steps. ? shows the keys."
  :interactive nil
  (setq-local +gh--fetch #'+gh--run-fetch
              +gh--render #'+gh--run-render))

(defun +gh--run-list-fetch ()
  (let ((buf (current-buffer)))
    (setq mode-line-process " loading…")
    (+gh--call (+gh--args `("run" "list" "-L" ,(number-to-string +gh-run-list-limit)
                            ,@(and +gh-run-list--branch (list "--branch" +gh-run-list--branch))
                            "--json" "databaseId,displayTitle,workflowName,headBranch,status,conclusion,event,createdAt,updatedAt,startedAt,url"))
               (lambda (out)
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (setq mode-line-process nil)
                     (let ((runs (+gh--json out)))
                       (+gh--redraw buf runs)
                       (+gh--watch (+gh--pending-p runs) nil))))))))

(defun +gh--run-list-render (runs)
  (insert (+gh--face "Workflow runs" 'magit-section-heading) "  " (+gh--repo-name)
          (if +gh-run-list--branch (+gh--face (concat "  [" +gh-run-list--branch "]") 'font-lock-keyword-face) "")
          "\n"
          (+gh--face "RET open  b this branch / all  R rerun failed  X cancel  o browser  ? more\n\n" 'shadow))
  (if (null runs)
      (insert (+gh--face "  No runs.\n" 'shadow))
    (let ((ww (min 24 (apply #'max 8 (mapcar (lambda (r) (length (alist-get 'workflowName r))) runs))))
          (bw (min 20 (apply #'max 6 (mapcar (lambda (r) (length (alist-get 'headBranch r))) runs)))))
      (dolist (run runs)
        (let-alist run
          (magit-insert-section (+gh-run run)
            (insert (+gh--icon (+gh--bucket run)) " "
                    (+gh--face (truncate-string-to-width .workflowName ww nil ?\s "…") 'font-lock-keyword-face) " "
                    (+gh--face (truncate-string-to-width .headBranch bw nil ?\s "…") 'font-lock-variable-name-face) " "
                    (+gh--face (string-pad (+gh--ago .createdAt) 4) 'shadow) " "
                    .displayTitle "  " (+gh--face .event 'shadow) "\n")))))))

(defun +gh--run-list-open (branch)
  (let ((buf (+gh--buffer (format "*gh runs: %s*" (let ((+gh-repo (+gh--target-repo))) (+gh--repo-name)))
                          '+gh-run-list-mode)))
    (with-current-buffer buf
      (setq +gh-run-list--branch branch)
      (+gh-refresh))
    (+gh--show buf)))

(defun +gh-run-list ()
  "Recent GitHub Actions runs."
  (interactive)
  (+gh--run-list-open nil))

(defun +gh-run-list-branch ()
  "Recent GitHub Actions runs of the current branch."
  (interactive)
  (+gh--run-list-open (or (+gh--git "symbolic-ref" "--short" "-q" "HEAD")
                          (user-error "Detached HEAD"))))

(defun +gh-run-list-toggle-branch ()
  "Switch between all runs and the current branch's."
  (interactive)
  (setq +gh-run-list--branch (unless +gh-run-list--branch
                               (or (+gh--git "symbolic-ref" "--short" "-q" "HEAD")
                                   (user-error "Detached HEAD"))))
  (+gh-refresh))

(defun +gh--run-open (run)
  (let* ((+gh-repo (or +gh-repo (+gh--repo-from-url (alist-get 'url run))))
         (buf (+gh--buffer (format "*gh run %s: %s*" (alist-get 'databaseId run) (+gh--repo-name))
                           '+gh-run-mode)))
    (with-current-buffer buf
      (setq +gh--data run)
      (+gh-refresh))
    (+gh--show buf)))

(defun +gh--run-fetch ()
  (let ((buf (current-buffer)))
    (setq mode-line-process " loading…")
    (+gh--call (+gh--args (list "run" "view" (number-to-string (alist-get 'databaseId +gh--data))
                                "--json" "databaseId,displayTitle,workflowName,headBranch,status,conclusion,event,createdAt,url,jobs,attempt,number"))
               (lambda (out)
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (setq mode-line-process nil)
                     (let ((run (+gh--json out)))
                       (+gh--redraw buf run)
                       (+gh--watch (eq (+gh--bucket run) 'pending)
                                   (let-alist run
                                     (format "%s #%s: %s" .workflowName .number
                                             (downcase (or .conclusion "done"))))))))))))

(defun +gh--run-render (run)
  (let-alist run
    (insert (+gh--face (format "%s #%s " (or .workflowName "") (or .number "")) 'shadow)
            (+gh--face (or .displayTitle "") 'magit-section-heading) "\n")
    (+gh--field "Status" (concat (+gh--icon (+gh--bucket run)) " "
                                 (downcase (if (equal .status "completed") (or .conclusion "") (or .status "")))
                                 "  " (+gh--face (or .headBranch "") 'font-lock-variable-name-face)
                                 "  " (+gh--face (or .event "") 'shadow)
                                 "  " (+gh--face (+gh--ago .createdAt) 'shadow)
                                 (if (and .attempt (> .attempt 1)) (format "  attempt %d" .attempt) "")))
    (+gh--field "URL" (or .url ""))
    (insert (+gh--face "RET log  TAB steps  R rerun failed  X cancel  o browser  ? more\n\n" 'shadow))
    (magit-insert-section (+gh-jobs)
      (magit-insert-heading (+gh--face "Jobs" 'magit-section-heading) "  " (+gh--counts .jobs))
      (unless .jobs
        (insert (+gh--face "  No jobs: the run failed before starting any (o shows why).\n" 'shadow)))
      (dolist (job (+gh--sort-checks .jobs))
        (let-alist job
          (magit-insert-section (+gh-job job (not (eq (+gh--bucket job) 'fail)))
            (magit-insert-heading "  " (+gh--icon (+gh--bucket job)) " " .name "  "
                                  (+gh--face (+gh--duration .startedAt .completedAt) 'shadow))
            (dolist (step .steps)
              (let-alist step
                (insert "      " (+gh--icon (+gh--bucket step)) " "
                        (if (eq (+gh--bucket step) 'skip) (+gh--face .name 'shadow) .name) "\n")))))))))

(defun +gh-rerun ()
  "Rerun the failed jobs: of the check/job/run at point, or all of a PR's."
  (interactive)
  (pcase (+gh--thing)
    (`(+gh-check . ,c)
     (pcase-let ((`(,repo ,_run ,job) (+gh--job-url-parts (alist-get 'detailsUrl c))))
       (unless job (user-error "Not a GitHub Actions check"))
       (+gh--do (list "run" "rerun" "--job" job "-R" repo) (format "Rerunning %s" (+gh--check-name c)))))
    (`(+gh-job . ,j)
     (+gh--do (list "run" "rerun" "--job" (number-to-string (alist-get 'databaseId j)))
              (format "Rerunning %s" (alist-get 'name j))))
    (`(+gh-run . ,r)
     (+gh--do (list "run" "rerun" (number-to-string (alist-get 'databaseId r)) "--failed")
              "Rerunning the failed jobs"))
    (`(+gh-pr . ,pr)
     (let ((runs (delete-dups
                  (delq nil (mapcar (lambda (c)
                                      (and (memq (+gh--bucket c) '(fail cancel))
                                           (seq-take (+gh--job-url-parts (alist-get 'detailsUrl c)) 2)))
                                    (alist-get 'statusCheckRollup pr))))))
       (unless runs (user-error "No failed GitHub Actions checks to rerun"))
       (pcase-dolist (`(,repo ,run) runs)
         (+gh--do (list "run" "rerun" run "--failed" "-R" repo)
                  (format "Rerunning failed jobs of %d run%s" (length runs) (if (cdr runs) "s" ""))))))
    (_ (user-error "Nothing to rerun here"))))

(defun +gh-run-cancel ()
  "Cancel the workflow run at point."
  (interactive)
  (pcase (+gh--thing)
    (`(+gh-run . ,r)
     (when (y-or-n-p (format "Cancel run of %s? " (alist-get 'workflowName r)))
       (+gh--do (list "run" "cancel" (number-to-string (alist-get 'databaseId r))) "Cancelled")))
    (_ (user-error "Move to a workflow run first"))))


;;; Menus and keys

(defun +gh-browse-repo ()
  "Open the repo on github.com (copy its URL in a terminal)."
  (interactive)
  (let ((+gh-repo (+gh--target-repo))
        (default-directory (let ((+gh-repo (+gh--target-repo))) (+gh--root))))
    (+gh--call (+gh--args '("repo" "view" "--json" "url"))
               (lambda (out)
                 (let ((url (alist-get 'url (+gh--json out))))
                   (if (display-graphic-p)
                       (browse-url url)
                     (kill-new url)
                     (message "Copied %s" url)))))))

(transient-define-prefix +gh-dispatch ()
  "GitHub pull requests and CI, via the gh CLI."
  ["Options"
   ("-R" "Another repo (OWNER/REPO)" "--repo=")]
  [["Pull requests"
    ("p" "Open PRs" +gh-pr-list)
    ("m" "Mine" +gh-pr-list-mine)
    ("r" "Waiting for my review" +gh-pr-list-review)
    ("." "This branch's PR" +gh-pr-view-current)
    ("#" "PR by number or URL" +gh-pr-view)
    ("n" "New PR from this branch" +gh-pr-create)]
   ["CI (GitHub Actions)"
    ("a" "All runs" +gh-run-list)
    ("b" "This branch's runs" +gh-run-list-branch)]
   ["Repo"
    ("o" "Open on github.com" +gh-browse-repo)]])

(transient-define-prefix +gh-pr-menu ()
  "Act on the pull request at point."
  [["View"
    ("RET" "Open thing at point" +gh-visit)
    ("d" "Diff" +gh-pr-diff)
    ("o" "Open on github.com" +gh-browse)
    ("Y" "Copy URL" +gh-copy-url)
    ("gr" "Refresh" +gh-refresh)]
   ["Review"
    ("a" "Approve" +gh-pr-approve)
    ("r" "Request changes" +gh-pr-request-changes)
    ("C" "Comment" +gh-pr-comment)
    ("A" "Ask someone to review" +gh-pr-add-reviewer)]
   ["Branch"
    ("c" "Check out" +gh-pr-checkout)
    ("m" "Merge…" +gh-pr-merge)
    ("D" "Draft / ready" +gh-pr-toggle-draft)
    ("X" "Close / reopen" +gh-pr-toggle-closed)]
   ["CI checks"
    ("L" "Log of check at point" +gh-log)
    ("R" "Rerun failed" +gh-rerun)
    ("W" "Auto-refresh on/off" +gh-toggle-auto-refresh)]]
  [:if (lambda () (derived-mode-p '+gh-pr-list-mode))
   ["List"
    ("f" "Filter (mine, review requested, merged…)" +gh-pr-list-filter)
    ("/" "Search" +gh-pr-list-search)]])

(transient-define-prefix +gh-run-menu ()
  "Act on workflow runs."
  [["View"
    ("RET" "Open run / log of job" +gh-visit)
    ("L" "Log of job at point" +gh-log)
    ("o" "Open on github.com" +gh-browse)
    ("Y" "Copy URL" +gh-copy-url)
    ("gr" "Refresh" +gh-refresh)]
   ["Act"
    ("R" "Rerun failed jobs" +gh-rerun)
    ("X" "Cancel run" +gh-run-cancel)
    ("W" "Auto-refresh on/off" +gh-toggle-auto-refresh)]
   ["List"
    :if (lambda () (derived-mode-p '+gh-run-list-mode))
    ("b" "This branch / all" +gh-run-list-toggle-branch)]])

(defun +gh-menu ()
  "Show what you can do in this buffer."
  (interactive)
  (call-interactively (if (derived-mode-p '+gh-run-list-mode '+gh-run-mode)
                          #'+gh-run-menu
                        #'+gh-pr-menu)))

(map! (:map +gh-mode-map
       :n "RET" #'+gh-visit
       :n [tab] #'magit-section-toggle
       :n "TAB" #'magit-section-toggle
       :n "gr"  #'+gh-refresh
       :n "q"   #'+gh-quit
       :n "?"   #'+gh-menu
       :n "o"   #'+gh-browse
       :n "Y"   #'+gh-copy-url
       :n "L"   #'+gh-log
       :n "R"   #'+gh-rerun
       :n "W"   #'+gh-toggle-auto-refresh
       :n "C-j" #'magit-section-forward
       :n "C-k" #'magit-section-backward)
      (:map (+gh-pr-list-mode-map +gh-pr-mode-map)
       :n "d" #'+gh-pr-diff
       :n "c" #'+gh-pr-checkout
       :n "a" #'+gh-pr-approve
       :n "r" #'+gh-pr-request-changes
       :n "C" #'+gh-pr-comment
       :n "A" #'+gh-pr-add-reviewer
       :n "m" #'+gh-pr-merge
       :n "D" #'+gh-pr-toggle-draft
       :n "X" #'+gh-pr-toggle-closed)
      (:map +gh-pr-list-mode-map
       :n "f" #'+gh-pr-list-filter
       :n "/" #'+gh-pr-list-search)
      (:map (+gh-run-list-mode-map +gh-run-mode-map)
       :n "X" #'+gh-run-cancel)
      (:map +gh-run-list-mode-map
       :n "b" #'+gh-run-list-toggle-branch)
      (:map +gh-log-mode-map
       :n "]e" #'+gh-log-next-error
       :n "[e" #'+gh-log-previous-error
       :n "gr" #'revert-buffer
       :n "o"  #'+gh-log-browse
       :n "q"  #'+gh-quit)
      (:map +gh-compose-mode-map
       :n "ZZ" #'+gh-compose-send
       :n "ZQ" #'+gh-compose-cancel))

(dolist (mode '(+gh-pr-list-mode +gh-pr-mode +gh-run-list-mode +gh-run-mode +gh-log-mode +gh-diff-mode))
  (evil-set-initial-state mode 'normal))

;; Comment / review / PR description editor: a roomy popup that ESC
;; doesn't close (so a stray key can't lose what you wrote).
(set-popup-rule! "^\\*gh: " :size 0.4 :select t :quit nil :ttl nil :modeline t)


;;; The current branch's PR in magit status (and the git panel)

(defvar +gh--status-cache (make-hash-table :test #'equal)
  "(ROOT . BRANCH) -> (TIME . PR), PR being :none when the branch has none.")
(defvar +gh--status-inflight (make-hash-table :test #'equal))

(defun +gh--status-refetch (key)
  "Look up the PR of KEY's branch, then redraw magit status if it changed."
  (unless (gethash key +gh--status-inflight)
    (puthash key t +gh--status-inflight)
    (let ((default-directory (car key)))
      (cl-flet ((done (pr)
                  (remhash key +gh--status-inflight)
                  (let ((old (cdr (gethash key +gh--status-cache))))
                    (puthash key (cons (float-time) pr) +gh--status-cache)
                    (unless (equal old pr)
                      (dolist (buf (buffer-list))
                        (with-current-buffer buf
                          (when (and (derived-mode-p 'magit-status-mode)
                                     (get-buffer-window buf 'visible)
                                     (file-equal-p default-directory (car key)))
                            (magit-refresh-buffer))))))))
        (+gh--call (list "pr" "view" "--json" "number,title,state,isDraft,reviewDecision,statusCheckRollup,url")
                   (lambda (out) (done (+gh--json out)))
                   nil
                   (lambda (_) (done :none)))))))

(defun +gh--status-github-p ()
  (seq-some (lambda (r) (string-match-p "github" (or (magit-get "remote" r "url") "")))
            (magit-list-remotes)))

(defun +gh-insert-pr-header ()
  "Header line in magit status: this branch's PR, its checks and review."
  (when-let* (((and +gh-status-header (executable-find "gh")))
              (branch (magit-get-current-branch))
              (root (magit-toplevel))
              ((+gh--status-github-p))
              (key (cons root branch)))
    (pcase-let* ((`(,time . ,pr) (gethash key +gh--status-cache))
                 (checks (and (consp pr) (alist-get 'statusCheckRollup pr)))
                 (ttl (cond ((null time) 0)
                            ((+gh--pending-p checks) +gh-refresh-interval)
                            (t 60))))
      (when (> (- (float-time) (or time 0)) ttl)
        (+gh--status-refetch key)
        ;; While checks run, look again even if nothing else redraws the buffer.
        (when (+gh--pending-p checks)
          (run-with-timer (1+ +gh-refresh-interval) nil
                          (lambda ()
                            (dolist (buf (buffer-list))
                              (with-current-buffer buf
                                (when (and (derived-mode-p 'magit-status-mode)
                                           (get-buffer-window buf 'visible))
                                  (magit-refresh-buffer))))))))
      (when (consp pr)
        (let-alist pr
          (magit-insert-section (+gh-pr pr)
            (insert (format "%-10s" "PR:")
                    (+gh--face (format "#%d" .number) 'font-lock-keyword-face) " "
                    (if-let ((b (+gh--rollup checks)))
                        (concat (+gh--icon b) " "
                                (pcase b
                                  ('fail (format "%d failing" (seq-count (lambda (c) (eq (+gh--bucket c) 'fail)) checks)))
                                  ('pending (format "%d running" (seq-count (lambda (c) (eq (+gh--bucket c) 'pending)) checks)))
                                  (_ "checks"))
                                "  ")
                      "")
                    (pcase .state
                      ("MERGED" (+gh--face "merged  " 'font-lock-constant-face))
                      ("CLOSED" (+gh--face "closed  " 'error))
                      (_ (cond (.isDraft (+gh--face "draft  " 'shadow))
                               ((equal .reviewDecision "APPROVED") (+gh--face "approved  " 'success))
                               ((equal .reviewDecision "CHANGES_REQUESTED") (+gh--face "changes requested  " 'error))
                               (t ""))))
                    .title "\n")))))))

(defvar magit-+gh-pr-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit-visit-thing] #'+gh-visit)
    (define-key map [remap magit-browse-thing] #'+gh-browse)
    map)
  "Keys on the PR line in magit status: RET opens the PR.")

(with-eval-after-load 'magit
  (magit-add-section-hook 'magit-status-headers-hook #'+gh-insert-pr-header nil t)
  (map! :map magit-status-mode-map :n "@" #'+gh-dispatch)
  (transient-append-suffix 'magit-dispatch "!"
    '("@" "GitHub PRs & CI" +gh-dispatch)))

(provide '+gh)
;;; gh.el ends here
