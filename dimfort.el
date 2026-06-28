;;; dimfort.el --- Emacs companion for the DimFort Fortran unit checker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victor Arrial

;; Author: Victor Arrial
;; URL: https://github.com/ArrialVictor/DimFort-EmacsCompanion
;; Version: 0.2.6
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, fortran, lsp, tools
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Emacs front-end for `dimfort lsp', the language server shipped by
;; DimFort (https://github.com/ArrialVictor/DimFort).  Registers the
;; server with both eglot (built-in since Emacs 29) and lsp-mode
;; (MELPA) when each is available, exposes the same per-feature
;; toggle commands the VSCode companion does, and wires up the
;; `dimfort.insertSnippet' workspace command used by the U005 code
;; action.

;; Quick start:
;;
;;   (require 'dimfort)
;;   (dimfort-setup)
;;
;; Then open any .f90/.F90 file and start eglot or lsp-mode as usual.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup dimfort nil
  "Emacs companion for the DimFort Fortran unit checker."
  :group 'languages
  :prefix "dimfort-")

(defcustom dimfort-executable "dimfort"
  "Path to the dimfort binary.  Override if it's not on `exec-path'."
  :type 'string)

(defcustom dimfort-inlay-hints-enabled nil
  "Whether the LSP server should emit inlay hints.

Off by default: detailed hover is the primary surface, so inlay
hints are redundant noise beside it.  Toggle on with
`dimfort-toggle-inlay-hints'."
  :type 'boolean)

(defcustom dimfort-completion-enabled t
  "Whether the LSP server should provide unit-name completion."
  :type 'boolean)

(defcustom dimfort-code-actions-enabled t
  "Whether the LSP server should advertise code actions."
  :type 'boolean)

(defcustom dimfort-goto-definition-enabled t
  "Whether the LSP server should answer textDocument/definition."
  :type 'boolean)

(defcustom dimfort-hover "short"
  "Hover verbosity: \"disabled\", \"short\", or \"detailed\".

\"disabled\" shows no hover at all; \"short\" a one-line summary;
\"detailed\" the full unit-algebra tree.  Defaults to \"short\" — a
compact unit surface alongside the side panel (on by default).  Cycle
with `dimfort-cycle-hover'.  The panel is unaffected by this setting."
  :type '(choice (const "disabled") (const "short") (const "detailed")))

(defcustom dimfort-cache-mode "read-write"
  "Content-hash check cache mode forwarded to the server.

\"off\" disables the cache; \"read-write\" (the default) reads and
writes it; \"read-only\" reads but never writes."
  :type '(choice (const "off") (const "read-only") (const "read-write")))

(defcustom dimfort-cache-dir ""
  "Directory for the content-hash cache.

Empty string means let the server pick its default location; only
a non-empty value is forwarded as `cacheDir'."
  :type 'string)

(defcustom dimfort-scale-mode "auto"
  "Opt-in scale/magnitude checking (S001 multiplicative, S002 affine).

\"auto\" (the default) defers to the project's `dimfort.toml'
`[scale] enabled' — the `scaleMode' option is not forwarded, so the
server config wins. \"on\"/\"off\" forward an explicit boolean that
overrides the toml for the session.  Cycle with `dimfort-cycle-scale'."
  :type '(choice (const "auto") (const "on") (const "off")))

(defcustom dimfort-max-workset-size 40
  "Cap on the number of files a single workset check loads."
  :type 'integer)

(defcustom dimfort-external-modules nil
  "Module names treated as known-out-of-workset (silences U007)."
  :type '(repeat string))

(defcustom dimfort-fortran-modes '(f90-mode fortran-mode)
  "Major modes DimFort should attach to."
  :type '(repeat symbol))


;;; Internal helpers

(defun dimfort--init-options ()
  "Return the initializationOptions table sent to the LSP server.

Mirrors the field set the VSCode and Neovim companions send, so all
three clients present an identical surface to the server."
  (let ((opts
         `((inlayHintsEnabled . ,(if dimfort-inlay-hints-enabled t :json-false))
           (completionEnabled . ,(if dimfort-completion-enabled t :json-false))
           (codeActionsEnabled . ,(if dimfort-code-actions-enabled t :json-false))
           (gotoDefinitionEnabled . ,(if dimfort-goto-definition-enabled t :json-false))
           (hover . ,dimfort-hover)
           (cacheMode . ,dimfort-cache-mode)
           (maxWorksetSize . ,dimfort-max-workset-size)
           (externalModules . ,(or dimfort-external-modules [])))))
    ;; Only forward cacheDir if the user set one; an empty string would
    ;; shadow the server's default-cache-dir fallback.
    (when (and dimfort-cache-dir (not (string-empty-p dimfort-cache-dir)))
      (setq opts (append opts `((cacheDir . ,dimfort-cache-dir)))))
    ;; Scale checking is tri-state: "auto" omits scaleMode so the server's
    ;; dimfort.toml [scale] enabled wins; "on"/"off" send an explicit
    ;; boolean that overrides the toml for the session.
    (when (member dimfort-scale-mode '("on" "off"))
      (setq opts (append opts
                         `((scaleMode . ,(if (equal dimfort-scale-mode "on")
                                             t :json-false))))))
    opts))

(defun dimfort--command ()
  "Return the LSP server command line."
  (list dimfort-executable "lsp"))

(defun dimfort--insert-snippet (uri line character snippet)
  "Handle the `dimfort.insertSnippet' server command.
Emacs has no native LSP snippet expander, so we strip
placeholder syntax (`${N}', `${N:default}', `$0') and insert
the literal text at (LINE, CHARACTER) inside the buffer for URI."
  (let* ((file (if (string-prefix-p "file://" uri)
                   (url-unhex-string (substring uri 7))
                 uri))
         (buf (find-file-noselect file)))
    (with-current-buffer buf
      ;; No `save-excursion' here: the whole point of the snippet's `$0`
      ;; is to leave point between the braces. Wrapping the move in
      ;; `save-excursion' would restore the prior point and undo it.
      (goto-char (point-min))
      (forward-line line)
      (move-to-column character)
      (let ((plain snippet)
            (cursor-mark nil))
        ;; Mark $0 / ${0} with a unique sentinel before stripping
        ;; the other placeholders, so we can move point there.
        (setq plain (replace-regexp-in-string "\\${0}\\|\\$0" "\0" plain))
        (setq plain (replace-regexp-in-string "\\${[0-9]+:\\([^}]*\\)}" "\\1" plain))
        (setq plain (replace-regexp-in-string "\\${[0-9]+}" "" plain))
        (when (string-match "\0" plain)
          (setq cursor-mark (match-beginning 0))
          (setq plain (replace-regexp-in-string "\0" "" plain)))
        (let ((insert-start (point)))
          (insert plain)
          (when cursor-mark
            (goto-char (+ insert-start cursor-mark))))))
    (switch-to-buffer buf)))

(defun dimfort--uri-to-file (uri)
  "Return the local path for URI (handles the file:// scheme)."
  (if (string-prefix-p "file://" uri)
      (url-unhex-string (substring uri 7))
    uri))

(defun dimfort--field (obj key)
  "Read string KEY from OBJ, whether a plist (eglot) or hash-table (lsp-mode)."
  (cond
   ((hash-table-p obj) (gethash key obj))
   ((listp obj) (plist-get obj (intern (concat ":" key))))
   (t nil)))

(defun dimfort--pos-at (line character)
  "Return the buffer position at 0-based LINE / CHARACTER in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line line)
    (move-to-column character)
    (point)))

(defun dimfort--extract-to-parameter (uri range-start range-end
                                          insert-line indent literal-text
                                          target-unit default-name)
  "Handle the `dimfort.extractToParameter' server command (H010 D1.5).

Prompt for a name, validate it as a Fortran identifier, then apply
the two-edit refactor: insert a typed PARAMETER declaration at the
end of the enclosing routine's decl block, and replace the literal
at the use site with the new name.  RANGE-START / RANGE-END are LSP
Position objects (plist under eglot, hash-table under lsp-mode)."
  (let* ((file (dimfort--uri-to-file uri))
         (buf (find-file-noselect file))
         ;; Pre-fill DEFAULT-NAME as editable initial input (like Nvim's
         ;; vim.ui.input default and VSCode's showInputBox value), not as
         ;; read-string's DEFAULT-VALUE — that only kicks in on empty
         ;; input and isn't shown, so the user saw no proposed name.
         (name (read-string
                (format "Parameter name for %s (%s): " literal-text target-unit)
                default-name)))
    (when (and name (not (string-empty-p name)))
      (unless (string-match-p "\\`[A-Za-z][A-Za-z0-9_]*\\'" name)
        (user-error
         "DimFort: invalid Fortran identifier — must start with a letter, then letters/digits/_"))
      (with-current-buffer buf
        (save-excursion
          (let* ((s-line (dimfort--field range-start "line"))
                 (s-char (dimfort--field range-start "character"))
                 (e-line (dimfort--field range-end "line"))
                 (e-char (dimfort--field range-end "character"))
                 ;; Markers survive the decl-line insertion below, so the
                 ;; literal is replaced at the right spot regardless of
                 ;; whether the insertion sits above or below it.
                 (m-start (copy-marker (dimfort--pos-at s-line s-char)))
                 (m-end (copy-marker (dimfort--pos-at e-line e-char)))
                 (decl (format "%sreal, parameter :: %s = %s   !< @unit{%s}\n"
                               indent name literal-text target-unit)))
            (goto-char (point-min))
            (forward-line insert-line)
            (insert decl)
            (delete-region m-start m-end)
            (goto-char m-start)
            (insert name)
            (set-marker m-start nil)
            (set-marker m-end nil))))
      (switch-to-buffer buf))))


;; Workspace-bar state forward-declared so callers in eglot /
;; lsp-mode setup blocks can reference them without byte-compilation
;; free-variable warnings.  Real defvars + the helper functions live
;; further down with the panel renderer (search for the
;; "Workspace coverage bar" section).
(defvar dimfort--ws-snapshot)
(defvar dimfort--ws-stale)
(defvar dimfort--ws-refreshing)
(defvar dimfort--ws-spinner-frame)
(defvar dimfort--ws-spinner-timer)
(defvar dimfort--file-coverage-cache)
(defvar dimfort--panel-buffer)
(defvar dimfort--panel-last-payload)
(defvar dimfort--panel-divider)
(defvar dimfort--panel-source-buffer)


;;; Workspace-root detection
;;
;; Mirrors the cross-companion `dimfort.toml`-only marker policy
;; introduced in 0.2.7 (Nvim and VSCompanion equivalents land
;; alongside). Adds a custom entry to `project-find-functions' that
;; walks upward from the active file looking for a `dimfort.toml',
;; returning a `transient' project rooted there when found. Falls
;; through to project.el's existing chain (e.g. `project-try-vc') when
;; no `dimfort.toml' is upstream — that path keeps working unchanged
;; for projects without a `dimfort.toml'.
;;
;; The companion also emits a one-time `message' warning when the
;; upward walk encounters a second `dimfort.toml' above the chosen
;; one — typically signals an unintended sub-project or configuration
;; drift. Per-root deduped so the warning fires at most once per
;; workspace per session. Only fires for `dimfort.toml' specifically;
;; the implementation never warns about duplicate `.git' directories
;; upstream (the user's home or a personal-projects parent — noise,
;; not signal).

(defvar dimfort--root-source nil
  "Identifier for the marker that anchored the last resolved workspace
root. Set to the string `\"dimfort.toml\"' when our custom
`project-find-functions' entry matched, or `nil' when project.el's
default chain handled the resolution (or no project was found at all).
The panel footer reads this via `dimfort--root-source-tag'.")

(defvar dimfort--warned-nested-roots (make-hash-table :test 'equal)
  "Per-root memo of nested-`dimfort.toml' warnings so the same root
never warns twice in one session.")

(defun dimfort--root-source-tag ()
  "Return a parenthesised source tag for the panel footer.

Returns `\"(dimfort.toml)\"' when our project-find-function anchored
the active project; empty string otherwise (project.el's default chain
won, or no project was found). The panel appends this verbatim to the
`Project:' line — empty string renders as no tag, which is the correct
behaviour when we don't have something specific to report."
  (if dimfort--root-source
      (format " (%s)" dimfort--root-source)
    ""))

(defun dimfort--find-project (dir)
  "Custom `project-find-functions' entry preferring `dimfort.toml'.

Walks upward from DIR looking for `dimfort.toml'. Returns a
`(transient . ROOT)' cons cell when found (project.el's
documented format for ad-hoc transient projects), or `nil' to let
the next entry in `project-find-functions' attempt to match.

Sets `dimfort--root-source' as a side effect so the panel can surface
the marker. Emits a deduped `message' when a second `dimfort.toml'
exists above the chosen one — see the section header for the
deduplication contract."
  (when-let* ((found (locate-dominating-file dir "dimfort.toml")))
    (let* ((root (expand-file-name found))
           (root-toml (expand-file-name "dimfort.toml" root)))
      (setq dimfort--root-source "dimfort.toml")
      ;; Nested-`dimfort.toml' check: walk one directory above the
      ;; resolved root and see if another `dimfort.toml' lives there.
      ;; One-time per root via the hash-table memo.
      (let* ((parent (file-name-directory (directory-file-name root)))
             (above (and parent
                         (not (equal parent root))
                         (locate-dominating-file parent "dimfort.toml"))))
        (when (and above
                   (not (gethash root dimfort--warned-nested-roots)))
          (puthash root t dimfort--warned-nested-roots)
          (message
           (concat "DimFort: found dimfort.toml at %s; note another "
                   "exists at %s above. The lower one is in effect — "
                   "the upper one is ignored.")
           root-toml
           (expand-file-name "dimfort.toml" above))))
      (cons 'transient root))))


;;; eglot integration

(defvar eglot-server-programs)
(declare-function eglot-execute-command "eglot")
(declare-function eglot-execute "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-shutdown "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot--update-hints-1 "eglot")
(defvar eglot-inlay-hints-mode)

(defcustom dimfort-inlay-refresh-delay 1.2
  "Seconds to wait after attach/restart before forcing an inlay re-request.

Eglot (as of Emacs 30) doesn't handle ``workspace/inlayHint/refresh''
notifications from the server — its inlay-hint requests are
JIT-driven by scroll/edit events.  After we attach or restart, the
server's initial workspace check may not finish before eglot's
first inlay request, so the first response comes back empty and
eglot caches it.  This timer forces a re-request once the check
should be done."
  :type 'number)

(defun dimfort--force-inlay-refresh ()
  "Force eglot to re-request inlay hints in every DimFort-managed buffer."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (boundp 'eglot-inlay-hints-mode)
                 eglot-inlay-hints-mode
                 (fboundp 'eglot-current-server)
                 (eglot-current-server)
                 (fboundp 'eglot--update-hints-1))
        (ignore-errors
          (eglot--update-hints-1 (point-min) (point-max)))))))

(defun dimfort--clear-inlay-overlays ()
  "Remove every eglot inlay-hint overlay in every managed buffer.

Used for the immediate-feedback half of toggling inlay hints off:
without this, the overlays linger until eglot processes the next
inlayHint response (which may be delayed or skipped after the
server restart)."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (boundp 'eglot-inlay-hints-mode) eglot-inlay-hints-mode)
        (save-restriction
          (widen)
          (dolist (o (overlays-in (point-min) (point-max)))
            (when (overlay-get o 'eglot--inlay-hint)
              (delete-overlay o))))))))

(defun dimfort--schedule-inlay-refresh ()
  "Schedule a delayed `dimfort--force-inlay-refresh' call."
  (run-at-time dimfort-inlay-refresh-delay nil
               #'dimfort--force-inlay-refresh))

(defun dimfort--register-project-finder ()
  "Add the `dimfort.toml'-aware entry to `project-find-functions'.

Idempotent — `add-hook' deduplicates. Called from both the eglot
and lsp-mode setup paths since the finder is LSP-client-agnostic
(it's a project.el hook, surfaces in `project-current' regardless
of which LSP backend asked)."
  (add-hook 'project-find-functions #'dimfort--find-project))

(defun dimfort--eglot-setup ()
  "Register DimFort with eglot."
  (when (require 'eglot nil t)
    (dimfort--register-project-finder)
    ;; eglot reads server initialization options from
    ;; `eglot-workspace-configuration' or from the `:initializationOptions'
    ;; the contact-class provides. The simplest path that mirrors VSCode
    ;; behaviour is a contact entry that includes the options inline.
    (dolist (mode dimfort-fortran-modes)
      (add-to-list
       'eglot-server-programs
       (cons mode
             (lambda (_interactive)
               (append (dimfort--command)
                       (list :initializationOptions
                             (dimfort--init-options)))))))
    ;; Intercept the DimFort client-side commands (`dimfort.insertSnippet',
    ;; `dimfort.extractToParameter') before eglot forwards them to the
    ;; server as `workspace/executeCommand' (the server doesn't define
    ;; them — they edit the client buffer). Emacs 30's code-action path
    ;; dispatches through `eglot-execute (server action)'; Emacs 29 used
    ;; the now-obsolete `eglot-execute-command (server command args)'.
    (if (fboundp 'eglot-execute)
        (advice-add 'eglot-execute :around #'dimfort--eglot-execute-action-advice)
      (advice-add 'eglot-execute-command :around #'dimfort--eglot-execute-advice))
    ;; eglot 1.17 (Emacs 30) ignores `workspace/inlayHint/refresh',
    ;; so after every fresh attach we schedule our own re-request
    ;; once the server's initial workspace check has had time to
    ;; finish.  Without this, the first inlay request races and
    ;; loses, and the buffer renders no hints until the user edits.
    (add-hook 'eglot-managed-mode-hook
              #'dimfort--schedule-inlay-refresh)
    ;; Open the side panel on attach when the user opted in.
    (add-hook 'eglot-managed-mode-hook
              #'dimfort--panel-maybe-autoopen)
    ;; Wire up the coverage layer (no-ops in `disabled' mode but the
    ;; per-buffer hooks are still installed so flipping into
    ;; `gutter' / `background' later works without an attach cycle).
    (add-hook 'eglot-managed-mode-hook
              #'dimfort--coverage-on-attach)
    ;; audited(0.2.7): error-surfacing — wrap the server process's
    ;; sentinel so an unexpected exit (segfault, ImportError on the
    ;; missing `lsp' extra, Python crash mid-handler, etc.)
    ;; surfaces as a DimFort `message' instead of just a passive
    ;; modeline indicator. Matches the Nvim companion's on_exit
    ;; handler and the planned VSCompanion onDidChangeState wiring.
    (add-hook 'eglot-managed-mode-hook
              #'dimfort--install-server-exit-sentinel)))

(defvar dimfort--warned-server-exits (make-hash-table :test 'equal)
  "Per-(code, signal-name) dedup memo for the unexpected-exit
notification — a rapid-retry crash loop won't carpet the user.")

(defvar dimfort--sentineled-processes (make-hash-table :test 'eq
                                                       :weakness 'key)
  "Weak-key memo of server processes we've already wrapped — keeps
the wrapping idempotent across `eglot-managed-mode-hook' firings,
which run once per managed buffer (Nvim's on_exit equivalent is
per-client, but Emacs hooks per-buffer).")

(defun dimfort--install-server-exit-sentinel ()
  "Wrap the active eglot server's process sentinel for exit detection.

Looks up `eglot-current-server' (no-op for lsp-mode — that path
would need an `lsp-after-uninitialized-functions' hook instead;
not implemented since lsp-mode users are a minority and lsp-mode
has its own server-died UX).

Idempotent: each process is wrapped at most once per Emacs session
via `dimfort--sentineled-processes'."
  (when (and (featurep 'eglot)
             (fboundp 'eglot-current-server))
    (let ((server (eglot-current-server)))
      (when (and server
                 (fboundp 'jsonrpc--process))
        (let ((proc (jsonrpc--process server)))
          (when (and (process-live-p proc)
                     (not (gethash proc dimfort--sentineled-processes)))
            (puthash proc t dimfort--sentineled-processes)
            (dimfort--wrap-process-sentinel proc)))))))

(defun dimfort--wrap-process-sentinel (proc)
  "Wrap PROC's existing sentinel with the dimfort-exit notifier.
The existing sentinel (eglot's own teardown logic) runs first;
ours runs after and surfaces unexpected exits."
  (let ((existing (process-sentinel proc)))
    (set-process-sentinel
     proc
     (lambda (process event)
       (when existing
         ;; Eglot's sentinel may raise (e.g., trying to clean up a
         ;; mode that's already dead); we still need to fire our
         ;; notification.
         (ignore-errors (funcall existing process event)))
       (dimfort--maybe-warn-on-exit process event)))))

(defun dimfort--maybe-warn-on-exit (process event)
  "Emit a DimFort error message when PROCESS's EVENT is abnormal.

EVENT is a string like `\"finished\\n\"' / `\"exited abnormally with
code 1\\n\"' / `\"killed by signal 9\\n\"'. Clean exits (\"finished\")
and user-initiated SIGTERM/SIGINT are skipped — those happen on
`M-x eglot-shutdown' or `M-x dimfort-restart' and don't warrant a
notification."
  (let ((evt (string-trim event)))
    (when (and (not (process-live-p process))
               (not (string= evt "finished"))
               ;; SIGTERM / SIGINT are graceful user-initiated kills.
               (not (string-match-p "killed by signal 15\\>" evt))
               (not (string-match-p "killed by signal 2\\>" evt)))
      (let ((key (concat (process-name process) ":" evt)))
        (unless (gethash key dimfort--warned-server-exits)
          (puthash key t dimfort--warned-server-exits)
          (message
           (concat "DimFort: LSP server exited unexpectedly (%s). "
                   "Check `*EGLOT events*' / `*Messages*' for details; "
                   "common causes include a missing 'lsp' extra "
                   "(pipx install 'dimfort[lsp]') or a Python crash "
                   "mid-handler.")
           evt))))))

(defun dimfort--eglot-execute-advice (orig server command arguments &rest rest)
  "Intercept DimFort commands on Emacs 29's `eglot-execute-command' path."
  (cond
   ((equal command "dimfort.insertSnippet")
    (apply #'dimfort--insert-snippet (append arguments nil)))
   ((equal command "dimfort.extractToParameter")
    (apply #'dimfort--extract-to-parameter (append arguments nil)))
   (t (apply orig server command arguments rest))))

(defun dimfort--action-command (action)
  "Return (COMMAND-STRING . ARGS) carried by ACTION, or nil.

ACTION is an LSP `Command' / `ExecuteCommandParams' (whose `:command'
is a string) or a `CodeAction' (whose `:command' is a nested `Command'
plist). Recurses one level to reach the string command name."
  (let ((cmd (plist-get action :command)))
    (cond
     ((stringp cmd) (cons cmd (plist-get action :arguments)))
     ((and cmd (listp cmd)) (dimfort--action-command cmd))
     (t nil))))

(defun dimfort--eglot-execute-action-advice (orig server action &rest rest)
  "Intercept DimFort commands on Emacs 30+'s `eglot-execute' path.

Handle our client-side commands locally; defer everything else (and
any action that has no command of ours) to eglot's default handling."
  (let* ((cv (dimfort--action-command action))
         (command (car cv))
         (arguments (cdr cv)))
    (cond
     ((equal command "dimfort.insertSnippet")
      (apply #'dimfort--insert-snippet (append arguments nil)))
     ((equal command "dimfort.extractToParameter")
      (apply #'dimfort--extract-to-parameter (append arguments nil)))
     (t (apply orig server action rest)))))

;; Async workspace check (DimFort 0.2.5+): catch the server-fired
;; `dimfort/workspaceCheckCompleted' notification.  eglot dispatches
;; custom notifications via `eglot-handle-notification' specialised
;; on the method symbol; we route the payload to the shared handler.
(cl-defmethod eglot-handle-notification
  (_server (_method (eql dimfort/workspaceCheckCompleted)) &rest params
   &allow-other-keys)
  "Catch the workspace-check completion notification from DimFort."
  (dimfort--handle-workspace-check-completed
   ;; eglot delivers notification params as a plist via &rest; the
   ;; shared handler treats it the same shape as lsp-mode's hash.
   params))


;;; lsp-mode integration

(defvar lsp-language-id-configuration)
(declare-function lsp-register-client "lsp-mode")
(declare-function make-lsp-client "lsp-mode")
(declare-function lsp-stdio-connection "lsp-mode")
(declare-function lsp-activate-on "lsp-mode")
(declare-function lsp-workspace-restart "lsp-mode")
(declare-function lsp--workspace-print "lsp-mode")

(defun dimfort--lsp-mode-setup ()
  "Register DimFort with lsp-mode (if loaded)."
  (when (featurep 'lsp-mode)
    (dimfort--register-project-finder)
    ;; Make sure f90/fortran modes are mapped to a known language id.
    (dolist (mode dimfort-fortran-modes)
      (add-to-list 'lsp-language-id-configuration `(,mode . "fortran")))
    ;; Open the side panel on attach when the user opted in.
    (add-hook 'lsp-managed-mode-hook #'dimfort--panel-maybe-autoopen)
    ;; Coverage layer setup (no-ops in `disabled' mode).
    (add-hook 'lsp-managed-mode-hook #'dimfort--coverage-on-attach)
    (lsp-register-client
     (make-lsp-client
      :new-connection (lsp-stdio-connection #'dimfort--command)
      :activation-fn (lsp-activate-on "fortran")
      :server-id 'dimfort
      :initialization-options #'dimfort--init-options
      :notification-handlers
      (let ((m (make-hash-table :test #'equal)))
        (puthash "dimfort/workspaceCheckCompleted"
                 (lambda (_workspace params)
                   (dimfort--handle-workspace-check-completed params))
                 m)
        m)
      :action-handlers
      (let ((m (make-hash-table :test #'equal)))
        (puthash "dimfort.insertSnippet"
                 (lambda (action)
                   (let* ((args (gethash "arguments" action)))
                     (apply #'dimfort--insert-snippet (append args nil))))
                 m)
        (puthash "dimfort.extractToParameter"
                 (lambda (action)
                   (let* ((args (gethash "arguments" action)))
                     (apply #'dimfort--extract-to-parameter (append args nil))))
                 m)
        m)))))


;;; Public API

;;;###autoload
(defun dimfort-setup ()
  "Register DimFort with whichever LSP front-end is loaded.

Safe to call multiple times — both eglot and lsp-mode registrations
de-duplicate by server-id / mode."
  (interactive)
  (dimfort--eglot-setup)
  (dimfort--lsp-mode-setup))

;;;###autoload
(defun dimfort-restart ()
  "Restart the active DimFort language server.

Tries lsp-mode first (it has a native workspace-restart), then
falls back to a full eglot shutdown + reattach.

We deliberately avoid `eglot-reconnect': it restarts from the
*saved* initargs of the original connect, so our contact
lambda is not re-invoked and a fresh `dimfort-*-enabled' value
never reaches the new server.  Shutdown + `eglot-ensure'
forces eglot to walk `eglot-server-programs' again, which
re-evaluates our lambda with the live customizables.

Also schedules a delayed inlay-hint re-request, since eglot
ignores `workspace/inlayHint/refresh' and would otherwise
leave the buffer with the pre-restart hint cache."
  (interactive)
  ;; Reset workspace-bar state — the prior server's cached coverage
  ;; payload and any in-flight spinner do not survive the restart.
  ;; Mirrors the Nvim companion's stats.reset() pattern.
  (dimfort--ws-stop-spinner)
  (setq dimfort--ws-snapshot nil
        dimfort--ws-stale nil
        dimfort--ws-refreshing nil)
  (clrhash dimfort--file-coverage-cache)
  (dimfort--panel-repaint)
  (cond
   ((and (featurep 'lsp-mode) (fboundp 'lsp-workspace-restart)
         (fboundp 'lsp-find-workspace))
    (call-interactively 'lsp-workspace-restart))
   ((featurep 'eglot)
    (let ((server (and (fboundp 'eglot-current-server) (eglot-current-server))))
      (if server
          (progn
            ;; audited(0.2.7): silent-OK — shutdown is a tear-down
            ;; step in a multi-step restart sequence. If the server
            ;; is already dead / unreachable, shutdown raising is
            ;; expected; we want to forge ahead to `eglot-ensure'
            ;; either way. The next attach attempt surfaces any
            ;; real problem.
            (ignore-errors
              (eglot-shutdown server nil nil 'preserve-buffers))
            (eglot-ensure)
            (dimfort--schedule-inlay-refresh))
        (message "DimFort: no active eglot server in this buffer."))))
   (t (message "DimFort: neither eglot nor lsp-mode is active.")))
  ;; Force one panel refresh once the new LSP client is actually
  ;; reachable from the source buffer.  Polling with a deadline
  ;; rather than a fixed delay because:
  ;;   - eglot-ensure and lsp-mode's workspace-restart are
  ;;     fire-and-forget; we can't await the attach.
  ;;   - A fixed delay (tried 0.8 s, 2 s) either fires before
  ;;     the new server is reachable (request returns empty,
  ;;     panel rebuilds against null payload) or feels sluggish
  ;;     on warm restarts.
  ;; Without this, a scale-toggle / hover-mode / cache-mode flip
  ;; would leave the panel showing the prior server's payload
  ;; until the user moved the cursor.
  (dimfort--restart-wait-and-refresh (+ (float-time) 10.0)))

(defun dimfort--restart-eglot-ready-p (server)
  "Return non-nil when eglot SERVER has completed the initialize handshake.
`eglot-current-server' returns the server object as soon as the
underlying process spawns, but requests issued before initialize
completes are silently dropped by our `ignore-errors' wrapper —
which left the post-restart auto-refresh firing into a void and the
panel blank until the next cursor motion happened to land in a
ready-state window.

Probe capabilities to gate on the initialize roundtrip having
landed.  Prefer the public `eglot-server-capable' (Emacs 29 /
eglot 1.13+); fall back to the internal `eglot--server-capable'
for older eglot; if neither is bound, fall back to the legacy
process-attached check (no worse than pre-fix behaviour)."
  (ignore-errors
    (cond
     ((fboundp 'eglot-server-capable)
      (eglot-server-capable :textDocumentSync))
     ((fboundp 'eglot--server-capable)
      (eglot--server-capable :textDocumentSync))
     (t server))))

(defun dimfort--restart-have-server-p (buf)
  "Return non-nil when an LSP client is attached AND initialized for BUF."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (or (and (featurep 'eglot)
                  (fboundp 'eglot-current-server)
                  (when-let ((server (eglot-current-server)))
                    (dimfort--restart-eglot-ready-p server)))
             (and (featurep 'lsp-mode)
                  (fboundp 'lsp-workspaces)
                  (lsp-workspaces))))))

(defun dimfort--restart-wait-and-refresh (deadline)
  "Poll until an LSP server is reachable, then refresh once.
Refreshes both the panel (so the cursor-position analysis populates
against the new server) and the file-coverage stats for the source
buffer (so the footer's File: segment doesn't keep the prior
server's numbers).  DEADLINE is a `float-time' cutoff; give up
silently after it."
  (let ((buf dimfort--panel-source-buffer))
    (cond
     ((and buf (dimfort--restart-have-server-p buf))
      (dimfort--restart-after-didopen buf))
     ((< (float-time) deadline)
      (run-at-time 0.3 nil #'dimfort--restart-wait-and-refresh deadline))
     (t nil))))

(defun dimfort--restart-after-didopen (buf)
  "Wait for BUF's `textDocument/didOpen' to be processed, then refresh.

Even once the initialize handshake has landed (capabilities-probe
in `dimfort--restart-have-server-p'), eglot still has to send
`textDocument/didOpen' for every managed buffer.  Firing
`dimfort/panelInfo' before the server has processed that didOpen
returns a valid-but-empty payload — the side-panel renders every
section but each one shows `(none)' until the next cursor motion
schedules another refresh.

LSP guarantees in-order processing per stream, so a
`textDocument/documentSymbol' request issued AFTER didOpen will
not be processed until didOpen has landed.  We piggy-back on that
ordering: probe with documentSymbol, then fire the real refreshes
in its callback.  On probe failure (timeout, server crash, etc.)
the callback never fires and the panel keeps the dimmed pre-restart
cache — strictly no worse than the prior \"refresh anyway\" path."
  (let ((params (list :textDocument (list :uri (dimfort--uri-of buf)))))
    (dimfort--panel-rpc
     buf "textDocument/documentSymbol" params
     (lambda (_result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           ;; Panel: cursor-position params + dimfort/panelInfo request.
           (ignore-errors (dimfort--panel-refresh))
           ;; File-coverage stats: refresh active-file's footer File:
           ;; segment.  Without this, the segment carries the prior
           ;; server's numbers until the user edits the buffer.
           (ignore-errors (dimfort--coverage-stats-refresh-active))))))))

;;;###autoload
(defun dimfort-check-workspace ()
  "Run the workspace-wide unit check via workspace/executeCommand.

Async since DimFort 0.2.5: the server returns an ack immediately and
delivers the coverage payload via the `dimfort/workspaceCheckCompleted'
notification.  The spinner runs until that notification arrives.
A duplicate trigger while a check is already in flight is coalesced
server-side; the server sends a heads-up toast in that case."
  (interactive)
  (cond
   (dimfort--ws-refreshing
    (message "DimFort: workspace check already in progress"))
   ((and (featurep 'eglot) (fboundp 'eglot-current-server)
         (eglot-current-server))
    (setq dimfort--ws-refreshing t)
    (dimfort--ws-start-spinner)
    (dimfort--panel-repaint)
    (let ((server (eglot-current-server)))
      ;; audited(0.2.7): error-surfacing — wire-level errors on
      ;; the executeCommand request previously silently cleared
      ;; the spinner with no user-visible signal. The server's
      ;; documented refusals (started:false ack — already in
      ;; progress, index not ready, no files) come back through
      ;; `window/showMessage' which eglot routes to the
      ;; *Messages* buffer, so we don't double-warn those. This
      ;; branch only fires on the request CRASHING (transport
      ;; error, server unreachable) — that case must surface.
      (condition-case err
          (eglot-execute-command server "dimfort/checkWorkspace" [])
        (error
         (setq dimfort--ws-refreshing nil)
         (dimfort--ws-stop-spinner)
         (dimfort--panel-repaint)
         (message "DimFort: workspace check request failed — %s"
                  (error-message-string err))))))
   ((and (featurep 'lsp-mode) (fboundp 'lsp--send-execute-command))
    (setq dimfort--ws-refreshing t)
    (dimfort--ws-start-spinner)
    (dimfort--panel-repaint)
    ;; audited(0.2.7): error-surfacing — same shape as the eglot
    ;; branch above. lsp-mode's variant of the same wire failure.
    (condition-case err
        (lsp--send-execute-command "dimfort/checkWorkspace" [])
      (error
       (setq dimfort--ws-refreshing nil)
       (dimfort--ws-stop-spinner)
       (dimfort--panel-repaint)
       (message "DimFort: workspace check request failed — %s"
                (error-message-string err)))))
   (t (message "DimFort: no LSP client active for this buffer."))))

;; Per-feature toggles: flip the customizable variable, restart the
;; server so the new initializationOptions take effect.
(defmacro dimfort--define-toggle (name var label)
  "Define an interactive toggle command for VAR with display LABEL."
  `(progn
     ;;;###autoload
     (defun ,name ()
       ,(format "Toggle %s and restart the DimFort language server." label)
       (interactive)
       (setq ,var (not ,var))
       (message "DimFort: %s %s" ,label (if ,var "on" "off"))
       (dimfort-restart))))

;;;###autoload
(defun dimfort-toggle-inlay-hints ()
  "Toggle inlay hints and restart the DimFort language server.

Unlike the other toggles, this one clears any leftover hint
overlays immediately when transitioning to off — the server
restart + eglot re-request flow doesn't reliably wipe them
otherwise."
  (interactive)
  (setq dimfort-inlay-hints-enabled (not dimfort-inlay-hints-enabled))
  (message "DimFort: inlay hints %s"
           (if dimfort-inlay-hints-enabled "on" "off"))
  (dimfort-restart)
  (unless dimfort-inlay-hints-enabled
    (dimfort--clear-inlay-overlays)))

(dimfort--define-toggle dimfort-toggle-completion
                        dimfort-completion-enabled
                        "unit completion")
(dimfort--define-toggle dimfort-toggle-code-actions
                        dimfort-code-actions-enabled
                        "code actions")
(dimfort--define-toggle dimfort-toggle-goto-definition
                        dimfort-goto-definition-enabled
                        "go-to-definition")

;; Cycle an enum-valued setting through VALUES and restart. Used for
;; the hover Disabled/Short/Detailed and the cache off <-> read-write
;; toggles.
(defmacro dimfort--define-cycle (name var label values)
  "Define an interactive command cycling VAR through VALUES, shown as LABEL."
  `(progn
     ;;;###autoload
     (defun ,name ()
       ,(format "Cycle %s and restart the DimFort language server." label)
       (interactive)
       (let* ((vals ,values)
              (pos (or (cl-position ,var vals :test #'equal) -1))
              (next (nth (mod (1+ pos) (length vals)) vals)))
         (setq ,var next)
         (message "DimFort: %s -> %s" ,label next)
         (dimfort-restart)))))

(dimfort--define-cycle dimfort-cycle-hover
                       dimfort-hover
                       "hover" '("disabled" "short" "detailed"))
;; Content-hash cache cycles all three values (off -> read-only ->
;; read-write -> off) matching the cache_mode enum's full range and
;; the cycle-hover / cycle-scale / cycle-coverage shape.
(dimfort--define-cycle dimfort-cycle-cache
                       dimfort-cache-mode
                       "cache" '("off" "read-only" "read-write"))
;; Scale checking is tri-state: "auto" defers to the project dimfort.toml,
;; "on"/"off" override it for the session.
(dimfort--define-cycle dimfort-cycle-scale
                       dimfort-scale-mode
                       "scale checking" '("auto" "on" "off"))

;;;###autoload
(defun dimfort-clear-cache ()
  "Delete the on-disk content-hash cache directory and restart the server.

Cache dir mirrors the server's resolution: the user's
`dimfort-cache-dir' setting if non-empty, else `.dimfort-cache/'
under the first workspace folder.  Cross-companion parity with
VSCompanion's `dimfort.clearCache' and Nvim's
`:DimFortClearCache'."
  (interactive)
  (let* ((workspace (or (when (and (fboundp 'project-current)
                                   (fboundp 'project-root))
                          (when-let ((proj (project-current)))
                            (project-root proj)))
                        default-directory))
         (dir (if (and dimfort-cache-dir
                       (not (string-empty-p dimfort-cache-dir)))
                  dimfort-cache-dir
                (expand-file-name ".dimfort-cache" workspace))))
    (cond
     ((not (file-directory-p dir))
      (message "DimFort: cache directory does not exist (already clean)."))
     (t
      (condition-case err
          (progn
            (delete-directory dir t)
            (message "DimFort: cache cleared (%s)" dir))
        (error
         (message "DimFort: clear cache failed — %s" (error-message-string err))
         (signal (car err) (cdr err))))))
    (dimfort-restart)))

;; =====================================================================
;; M-x dimfort-open-config — open or create dimfort.toml / units file.
;; =====================================================================
;;
;; Mirrors VSCompanion's `DimFort: Open Config…' (VSCompanion PR #34)
;; and Nvim's `:DimFortOpenConfig'. Two-step `completing-read': first
;; the file (`'dimfort.toml'' or `Project units file''), then for
;; units file when creating, a sub-pick between `Empty template' and
;; `Defaults as reference (all commented out)'. Auto-wires
;; `[units].file = "units.toml"' into `dimfort.toml' so the server
;; picks up the new units file immediately.

(defun dimfort--workspace-root ()
  "Return the workspace root (project root if available, else `default-directory')."
  (or (when (and (fboundp 'project-current)
                 (fboundp 'project-root))
        (when-let ((proj (project-current)))
          (project-root proj)))
      default-directory))

(defun dimfort--dimfort-toml-stub-empty ()
  "Return a minimal commented stub for a fresh ``dimfort.toml``."
  (mapconcat
   #'identity
   '("# DimFort project configuration."
     "#"
     "# Add project-wide settings here. Reference:"
     "#   https://github.com/ArrialVictor/DimFort/blob/main/docs/reference/dimfort-toml.md"
     "")
   "\n"))

(defun dimfort--dimfort-toml-stub ()
  "Return a minimal commented stub for a fresh ``dimfort.toml``."
  (mapconcat
   #'identity
   '("# DimFort project configuration."
     "#"
     "# Optional. Without this file, DimFort uses bundled defaults for"
     "# everything. Each section below is also optional — uncomment +"
     "# customise as needed. Reference:"
     "#   https://github.com/ArrialVictor/DimFort/blob/main/docs/reference/dimfort-toml.md"
     ""
     "# [units]"
     "# file = \"units.toml\"   # Project units file (extends bundled defaults)"
     ""
     "# [parser]"
     "# # Extra comment delimiters for unit annotations."
     "# # Defaults already recognise `!< @unit{...}' and friends."
     ""
     "# [diagnostics]"
     "# # H001 = \"off\"   # Per-code severity overrides"
     ""
     "# [scale]"
     "# # enabled = true   # Enable S001/S002 scale-aware checking"
     ""
     "# [project]"
     "# # src_paths = [\"src\"]   # Narrow the workspace check to these subdirs"
     "")
   "\n"))

(defun dimfort--units-stub-header ()
  "Return the common header for a fresh project units file."
  (mapconcat
   #'identity
   '("# DimFort project units file."
     "#"
     "# Extends (does not replace) the bundled defaults. To see what's"
     "# already in the defaults, run:  dimfort show-defaults units"
     "#"
     "# Schema:"
     "#   [base]     — base units mapping to SI dimension slots"
     "#                (M / L / T / Theta / I / N / J)"
     "#   [prefixes] — SI prefix multipliers (numeric or \"p/q\" rationals)"
     "#   [derived]  — derived units; `expr' parsed against the table;"
     "#                `prefixable = true' opts in to prefix expansion"
     "#"
     "")
   "\n"))

(defun dimfort--units-stub-empty ()
  "Return the ``Empty template'' units-file stub."
  (concat
   (dimfort--units-stub-header)
   (mapconcat
    #'identity
    '("# Example: a custom derived unit."
      "#"
      "# [derived]"
      "# barrel = { expr = \"159 * L\", prefixable = false }   # US oil barrel"
      "")
    "\n")))

(defun dimfort--units-stub-from-defaults ()
  "Return the ``Defaults as reference'' units-file stub.
Shells out to ``dimfort show-defaults units'' and comments every
non-blank, non-comment line so the file is a no-op until the user
uncomments what they want. Falls through to the empty stub with an
explanatory comment if the CLI invocation fails."
  (let* ((default-directory (dimfort--workspace-root))
         (defaults
          (with-temp-buffer
            (let ((exit (ignore-errors
                          (call-process dimfort-executable nil t nil
                                        "show-defaults" "units"))))
              (if (eq exit 0)
                  (buffer-string)
                "")))))
    (if (or (null defaults) (string-empty-p defaults))
        (concat
         (dimfort--units-stub-empty)
         "\n# (Couldn't fetch the bundled defaults; install or upgrade"
         "\n#  DimFort, then run `dimfort show-defaults units' to see"
         "\n#  what's available.)\n")
      (let* ((banner (concat
                      (dimfort--units-stub-header)
                      "# Below: bundled defaults, ALL commented out.\n"
                      "# Uncomment any line to enable, override, or extend.\n"
                      "# To start from scratch instead, delete everything below this banner.\n"
                      "#\n"))
             (lines (split-string defaults "\n"))
             (commented (mapconcat
                         (lambda (line)
                           (if (or (string-empty-p line)
                                   (string-prefix-p "#" line))
                               line
                             (concat "# " line)))
                         lines
                         "\n")))
        (concat banner commented)))))

(defun dimfort--try-wire-units-file (toml-path)
  "Ensure TOML-PATH has ``[units].file = \"units.toml\"``.
Returns one of the symbols ``wired'', ``already-wired'', or
``exists-with-units-section''. The string-ops approach only handles
the common path (no existing ``[units]`` section); the edge case
returns the symbol and lets the caller surface a hint."
  (let ((existing (if (file-exists-p toml-path)
                      (with-temp-buffer
                        (insert-file-contents toml-path)
                        (buffer-string))
                    "")))
    (cond
     ((string-match "\\[units\\][^\\[]*?\n[ \t]*file[ \t]*=" existing)
      'already-wired)
     ((string-match "\\(\\`\\|\n\\)\\[units\\][ \t]*\n" existing)
      'exists-with-units-section)
     (t
      (let ((sep (cond
                  ((string-empty-p existing) "")
                  ((not (eq (aref existing (1- (length existing))) ?\n)) "\n\n")
                  (t "\n"))))
        (with-temp-file toml-path
          (insert existing sep "[units]\nfile = \"units.toml\"\n"))
        'wired)))))

(defun dimfort--open-or-create-dimfort-toml (root)
  "Open ROOT/dimfort.toml, creating a stub if it doesn't exist."
  (let ((path (expand-file-name "dimfort.toml" root)))
    (if (file-exists-p path)
        (find-file path)
      (let ((flavour
             (completing-read
              "DimFort — Project configuration file: start from? "
              '("Empty file"
                "Reference template (all sections commented out)")
              nil t)))
        (when (and flavour (not (string-empty-p flavour)))
          (let ((content (if (string= flavour "Empty file")
                             (dimfort--dimfort-toml-stub-empty)
                           (dimfort--dimfort-toml-stub))))
            (with-temp-file path
              (insert content))
            (find-file path)
            (message "DimFort: created %s" path)))))))

(defun dimfort--open-or-create-units-file (root)
  "Open ROOT/units.toml, creating a stub if it doesn't exist."
  (let ((path (expand-file-name "units.toml" root)))
    (if (file-exists-p path)
        (find-file path)
      (let ((flavour
             (completing-read
              "DimFort — Project units file: start from? "
              '("Empty file"
                "Reference template (bundled defaults, all commented out)")
              nil t)))
        (when (and flavour (not (string-empty-p flavour)))
          (let ((content (if (string= flavour "Empty file")
                             (dimfort--units-stub-empty)
                           (dimfort--units-stub-from-defaults))))
            (with-temp-file path
              (insert content))
            (let ((wired (dimfort--try-wire-units-file
                          (expand-file-name "dimfort.toml" root))))
              (find-file path)
              (cond
               ((eq wired 'wired)
                (message "DimFort: created units.toml + wired into dimfort.toml"))
               ((eq wired 'exists-with-units-section)
                (message
                 "DimFort: created units.toml. Your dimfort.toml already has a [units] section — add 'file = \"units.toml\"' under it to enable the new file."))
               (t
                (message "DimFort: created units.toml"))))))))))

;;;###autoload
(defun dimfort-open-config ()
  "Quick-pick to open or create ``dimfort.toml'' / project units file.

When the chosen file does not exist, a stub is created (units file
offers an additional sub-pick between empty and defaults-as-reference).
For the units file, ``[units].file = \"units.toml\"`` is auto-wired
into ``dimfort.toml`` (creating it if necessary)."
  (interactive)
  (let ((root (dimfort--workspace-root)))
    (if (null root)
        (message
         "DimFort: open a project folder first; nothing to wire a config into.")
      (let ((choice (completing-read
                     "DimFort — Open Config: which config file? "
                     '("Project configuration file (dimfort.toml)"
                       "Project units file (units.toml)")
                     nil t)))
        (cond
         ((string= choice "Project configuration file (dimfort.toml)")
          (dimfort--open-or-create-dimfort-toml root))
         ((string= choice "Project units file (units.toml)")
          (dimfort--open-or-create-units-file root)))))))

;;;###autoload
(defun dimfort-status ()
  "Print the current DimFort feature flags in the echo area.

Users don't have to track toggle counts to know which features
are on — invoke this to see the live state."
  (interactive)
  (cl-flet ((flag (v) (if v "on" "off")))
    (message
     (concat
      "DimFort status\n"
      (format "  executable        : %s\n" dimfort-executable)
      (format "  inlay hints       : %s\n" (flag dimfort-inlay-hints-enabled))
      (format "  completion        : %s\n" (flag dimfort-completion-enabled))
      (format "  code actions      : %s\n" (flag dimfort-code-actions-enabled))
      (format "  go-to-definition  : %s\n" (flag dimfort-goto-definition-enabled))
      (format "  hover             : %s\n" dimfort-hover)
      (format "  cache             : %s\n" dimfort-cache-mode)
      (format "  scale checking    : %s\n" dimfort-scale-mode)
      (format "  cache dir         : %s\n"
              (if (string-empty-p dimfort-cache-dir) "(default)" dimfort-cache-dir))
      (format "  max workset size  : %d\n" dimfort-max-workset-size)
      (format "  external modules  : %s"
              (if dimfort-external-modules
                  (mapconcat #'identity dimfort-external-modules ", ")
                "(none)"))))))


;;; Coverage visualisation (0.2.4+)
;;
;; Per-line status decoration driven by the server's
;; `dimfort/lineStatus' LSP method.  Mirrors the VSCompanion and the
;; Nvim companion: three mutually-exclusive modes
;; (disabled / gutter / background) toggled via
;; `dimfort-cycle-coverage'.  `gutter' paints a coloured fringe dot
;; per line; `background' paints a line-tint via an overlay face.
;; Both encode the same per-line tier; the user picks the visual
;; weight they prefer.

(defcustom dimfort-coverage-mode "disabled"
  "Per-line coverage visualisation mode.

Values:
- \"disabled\": no decoration.
- \"gutter\": coloured dot in the left fringe per line, in four
  tiers (green / yellow / red / blue).
- \"background\": low-alpha line tint behind the text in the same
  four tiers.

`gutter' and `background' are mutually exclusive — pick the visual
weight you prefer.  Cycle with `dimfort-cycle-coverage'.  Requires
DimFort 0.2.4+ (server side `dimfort/lineStatus' method)."
  :type '(choice (const "disabled") (const "gutter") (const "background")))

(defcustom dimfort-coverage-debounce 0.5
  "Seconds to wait after a buffer change before refreshing coverage.

Should be slightly longer than the server's own `didChange'
debounce (~0.4 s) so the coverage query reaches the server after
its re-check completes."
  :type 'number)

;; Fringe-dot foreground faces. The same saturated hex reads well on
;; both light and dark backgrounds, so a single ``t'' spec is fine
;; here — the colour stays consistent across theme switches.
(defface dimfort-coverage-green
  '((t :foreground "#28a745"))
  "Face for the fringe dot of the green coverage tier (verified-OK).")
(defface dimfort-coverage-yellow
  '((t :foreground "#ffc107"))
  "Face for the fringe dot of the yellow coverage tier (needs attention).")
(defface dimfort-coverage-red
  '((t :foreground "#dc3545"))
  "Face for the fringe dot of the red coverage tier (hard fire).")
(defface dimfort-coverage-blue
  '((t :foreground "#0d6efd"))
  "Face for the fringe dot of the blue coverage tier (unparsed).")

;; Background tint faces. Theme-aware via the ``(background dark)'' /
;; ``(background light)'' display selectors — Emacs picks the
;; appropriate spec based on ``(frame-parameter nil 'background-mode)``
;; which is derived from the active colorscheme. The dark-theme hexes
;; are pre-darkened so the tint reads as a subtle wash on a dark
;; background; the light-theme hexes are pre-lightened so the tint
;; reads as a subtle wash on white. ``M-x customize-face'' lets users
;; override either spec individually.
(defface dimfort-coverage-bg-green
  '((((background dark))  :background "#0a3320")
    (((background light)) :background "#d4f4dd")
    (t :background "#d4f4dd"))
  "Background face for the green coverage tier in background mode.")
(defface dimfort-coverage-bg-yellow
  '((((background dark))  :background "#3b2e00")
    (((background light)) :background "#fff3cd")
    (t :background "#fff3cd"))
  "Background face for the yellow coverage tier in background mode.")
(defface dimfort-coverage-bg-red
  '((((background dark))  :background "#3b0a13")
    (((background light)) :background "#f8d7da")
    (t :background "#f8d7da"))
  "Background face for the red coverage tier in background mode.")
(defface dimfort-coverage-bg-blue
  '((((background dark))  :background "#0a1c3b")
    (((background light)) :background "#cfe2ff")
    (t :background "#cfe2ff"))
  "Background face for the blue coverage tier in background mode.")

;; Fringe bitmap shared by all four tiers — a filled circle. The face
;; (per tier) supplies the colour.
(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'dimfort-coverage-dot
    [#b00111100
     #b01111110
     #b11111111
     #b11111111
     #b11111111
     #b11111111
     #b01111110
     #b00111100]))

(defvar-local dimfort--coverage-overlays nil
  "Buffer-local list of active coverage overlays.")
(defvar-local dimfort--coverage-timer nil
  "Buffer-local debounce timer for coverage refresh.")

(defun dimfort--coverage-clear ()
  "Remove every coverage overlay from the current buffer."
  (dolist (ov dimfort--coverage-overlays)
    (when (overlayp ov)
      (delete-overlay ov)))
  (setq dimfort--coverage-overlays nil))

(defun dimfort--coverage-uri ()
  "Return the file:// URI for the current buffer, or nil if none."
  (let ((file (buffer-file-name)))
    (when file
      (concat "file://" (expand-file-name file)))))

(defun dimfort--coverage-apply (lines)
  "Paint LINES — a sequence of `:line' / `:status' plists — in the current buffer.
Clears any previous coverage decoration first."
  (dimfort--coverage-clear)
  (when (not (string= dimfort-coverage-mode "disabled"))
    (save-excursion
      (save-restriction
        (widen)
        (let ((max-line (line-number-at-pos (point-max))))
          (mapc
           (lambda (entry)
             (let ((lnum (or (plist-get entry :line)
                             (and (hash-table-p entry)
                                  (gethash "line" entry))))
                   (status (or (plist-get entry :status)
                               (and (hash-table-p entry)
                                    (gethash "status" entry)))))
               (when (and lnum status (<= lnum max-line))
                 (goto-char (point-min))
                 (forward-line (1- lnum))
                 (let* ((beg (point))
                        (end (line-end-position))
                        (face-fg (intern (format "dimfort-coverage-%s" status)))
                        (face-bg (intern (format "dimfort-coverage-bg-%s" status))))
                   (cond
                    ((string= dimfort-coverage-mode "gutter")
                     (let ((ov (make-overlay beg beg)))
                       (overlay-put
                        ov 'before-string
                        (propertize " " 'display
                                    `(left-fringe dimfort-coverage-dot ,face-fg)))
                       (overlay-put ov 'dimfort-coverage t)
                       (push ov dimfort--coverage-overlays)))
                    ((string= dimfort-coverage-mode "background")
                     ;; Extend to the start of the next line so the
                     ;; whole row is tinted (including trailing
                     ;; whitespace and the newline).
                     (let ((ov (make-overlay beg (min (1+ end) (point-max)))))
                       (overlay-put ov 'face face-bg)
                       ;; Low priority so squiggles / other overlays
                       ;; remain visible above the tint.
                       (overlay-put ov 'priority -50)
                       (overlay-put ov 'dimfort-coverage t)
                       (push ov dimfort--coverage-overlays))))))))
           lines))))))

(defun dimfort--coverage-request ()
  "Send the `dimfort/lineStatus' request for the current buffer and paint."
  (let ((uri (dimfort--coverage-uri))
        (buf (current-buffer)))
    (cond
     ;; eglot path
     ((and uri (featurep 'eglot)
           (fboundp 'eglot-current-server)
           (eglot-current-server))
      (let ((server (eglot-current-server)))
        (when server
          (jsonrpc-async-request
           server :dimfort/lineStatus `(:uri ,uri)
           :success-fn
           (lambda (result)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (let ((lines (or (plist-get result :lines)
                                  (and (hash-table-p result)
                                       (gethash "lines" result)))))
                   (dimfort--coverage-apply (or lines '()))))))
           :error-fn (lambda (&rest _) nil)
           :timeout-fn (lambda (&rest _) nil)))))
     ;; lsp-mode path
     ((and uri (featurep 'lsp-mode)
           (fboundp 'lsp-request-async))
      (lsp-request-async
       "dimfort/lineStatus" `(:uri ,uri)
       (lambda (result)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (let ((lines (or (and (hash-table-p result)
                                   (gethash "lines" result))
                              (plist-get result :lines))))
               (dimfort--coverage-apply (or lines '()))))))
       :mode 'tick)))))

(defun dimfort--coverage-schedule-refresh ()
  "Schedule a coverage refresh after the debounce on the current buffer."
  (when dimfort--coverage-timer
    (cancel-timer dimfort--coverage-timer))
  (let ((buf (current-buffer)))
    (setq dimfort--coverage-timer
          (run-at-time
           dimfort-coverage-debounce nil
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (setq dimfort--coverage-timer nil)
                 (dimfort--coverage-request))))))))

(defun dimfort--coverage-on-after-change (_beg _end _len)
  "Hook for `after-change-functions': schedule a debounced refresh."
  (unless (string= dimfort-coverage-mode "disabled")
    (dimfort--coverage-schedule-refresh))
  ;; Workspace coverage bar: mark the workspace snapshot stale and
  ;; refresh the file-scope stats so the footer's File: cell tracks
  ;; live edits.  Cheap LSP round-trip; same debounce path as the
  ;; per-line coverage refresh.
  (when (and dimfort--ws-snapshot (not dimfort--ws-stale))
    (setq dimfort--ws-stale t)
    (dimfort--panel-repaint))
  (dimfort--coverage-stats-refresh-active))

(defun dimfort--coverage-on-attach ()
  "Hook for `eglot-managed-mode-hook' / `lsp-managed-mode-hook'.
Wires up the per-buffer refresh trigger and paints once initially."
  (add-hook 'after-change-functions
            #'dimfort--coverage-on-after-change nil t)
  (add-hook 'after-save-hook
            (lambda ()
              (unless (string= dimfort-coverage-mode "disabled")
                (dimfort--coverage-schedule-refresh)))
            nil t)
  (unless (string= dimfort-coverage-mode "disabled")
    ;; Initial paint: defer slightly so the first server check has a
    ;; chance to complete on attach.
    (run-at-time 1.5 nil
                 (lambda ()
                   (when (buffer-live-p (current-buffer))
                     (dimfort--coverage-request)))))
  ;; Prime the footer's File stats unconditionally — independent of
  ;; the coverage-layer feature toggle. Without this, the footer's
  ;; ``File:`` cell stays ``–`` on a freshly-opened buffer until the
  ;; user makes their first edit (after-change-functions is the only
  ;; other trigger). 1.5 s defer same as the gutter path so the
  ;; first server check has time to complete.
  (run-at-time 1.5 nil
               (lambda ()
                 (when (buffer-live-p (current-buffer))
                   (dimfort--coverage-stats-refresh-active)))))

(defun dimfort--coverage-refresh-all ()
  "Refresh coverage in every buffer that has a DimFort LSP attached."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (or (and (featurep 'eglot)
                     (fboundp 'eglot-current-server)
                     (eglot-current-server))
                (and (featurep 'lsp-mode)
                     (fboundp 'lsp-workspaces)
                     (lsp-workspaces)))
        (dimfort--coverage-clear)
        (unless (string= dimfort-coverage-mode "disabled")
          (dimfort--coverage-request))))))

;;;###autoload
(defun dimfort-cycle-coverage ()
  "Cycle the coverage visualisation mode.

Order: disabled → gutter → background → disabled.  Companion-only
— flipping the mode does NOT restart the language server."
  (interactive)
  (let* ((order '("disabled" "gutter" "background"))
         (pos (or (cl-position dimfort-coverage-mode order :test #'equal) -1))
         (next (nth (mod (1+ pos) (length order)) order)))
    (setq dimfort-coverage-mode next)
    (message "DimFort: coverage %s" next)
    (dimfort--coverage-refresh-all)))


;;; Side panel

;; A cursor-following side window with two stacked sections:
;;   1. Expression — the unit-algebra tree under the cursor.
;;   2. Scope — declarations of every enclosing scope, stacked
;;      outermost-first, each variable marked 🟢 / 🟡 / 🔴.
;; Driven by the custom `dimfort/panelInfo' LSP request (see
;; DimFort/docs/design/shipped/panel-info.md). Closed by default; open it with
;; `dimfort-toggle-panel'.

(declare-function jsonrpc-async-request "jsonrpc")
(declare-function jsonrpc-running-p "jsonrpc")
(declare-function lsp-request-async "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")

(defcustom dimfort-panel-enabled t
  "Whether to open the side panel automatically when the server attaches.

On by default — set to nil to keep it closed and open it on demand
with `dimfort-toggle-panel'."
  :type 'boolean)

(defcustom dimfort-panel-side 'right
  "Which side of the frame the panel window docks to."
  :type '(choice (const right) (const left) (const bottom)))

(defcustom dimfort-panel-width 0.35
  "Panel window width as a fraction of the frame (for left/right docking)."
  :type 'number)

(defcustom dimfort-panel-height 0.3
  "Panel window height as a fraction of the frame (for bottom docking)."
  :type 'number)

(defcustom dimfort-panel-debounce 0.2
  "Idle seconds before the panel refreshes after the cursor moves."
  :type 'number)

;; Per-section visibility (0.2.6).  Replaces the previous tristate
;; `dimfort-panel-layout' (`both' / `expression' / `routine') with three
;; independent booleans, matching VSCompanion's
;; `dimfort.show.{cursor,scope,imports}' and Nvim's
;; `panel_show_{cursor,scope,imports}'.
(defcustom dimfort-show-cursor t
  "Show the Cursor section (Expression / Diagnostics / Interactions / Actions).
Toggle in-session with `\\[dimfort-toggle-cursor]'.  Persistent via
\\[customize-variable]."
  :type 'boolean)

(defcustom dimfort-show-scope t
  "Show the Scope section (declarations in enclosing scopes at cursor).
Toggle in-session with `\\[dimfort-toggle-scope]'.  Persistent via
\\[customize-variable]."
  :type 'boolean)

(defcustom dimfort-show-imports t
  "Show the Imports section (symbols brought in by `use' clauses).
Toggle in-session with `\\[dimfort-toggle-imports]'.  Persistent via
\\[customize-variable]."
  :type 'boolean)

(defcustom dimfort-panel-sort-mode "line"
  "Sort order shared by the panel's Scope and Imports sections.
\"line\" preserves source order (default).  \"alphabetic\" is a
case-insensitive name compare.  \"status\" puts errors first, then
unannotated, then annotated; ties broken by line for Scope and by
name for Imports.  Cycle via `\\[dimfort-cycle-sort-mode]'."
  :type '(choice (const "line") (const "alphabetic") (const "status")))

(defcustom dimfort-panel-unit-display-mode "canonical"
  "Which unit columns the Scope and Imports sections render.
\"input\" shows only the source unit (e.g. `hPa') — thinnest.
\"canonical\" shows only the canonical base-SI form (default) — most
visually consistent across declarations.  \"both\" shows input plus a
normalized column when it differs (legacy display).  Cycle via
`\\[dimfort-cycle-unit-display]'."
  :type '(choice (const "input") (const "canonical") (const "both")))

;;; Workspace coverage bar — file + workspace stats footer
;;
;; Mirrors the VSCompanion `CoverageStatsProvider` and the Nvim
;; companion's stats.lua module. Three pieces of state:
;;
;;   * `dimfort--ws-snapshot`: the workspace coverage payload from the
;;     most recent `dimfort/workspaceCheckCompleted' notification, or
;;     nil before the first refresh.
;;
;;   * `dimfort--ws-stale': non-nil once any diagnostics change after
;;     the last successful workspace refresh.  The footer dims the WS
;;     segment while this is set.
;;
;;   * `dimfort--ws-refreshing': non-nil while a workspace check is
;;     in flight on the server side.  Drives the Braille-spinner
;;     animation in the Project segment.
;;
;; File-scope refreshes are served by `dimfort/coverageStats' (the
;; same server endpoint used by the VS / Nvim companions); the
;; results live in `dimfort--file-coverage-cache' keyed by URI.
;;
;; Async since DimFort 0.2.5: the executeCommand returns an ack
;; immediately and the workspace coverage payload arrives later via
;; `dimfort/workspaceCheckCompleted'.  The notification handler
;; (`dimfort--handle-workspace-check-completed') stores the payload
;; and stops the spinner.

(defvar dimfort--ws-snapshot nil
  "Plist `(:ok N :warn N :fire N :coverage-pct PCT)' for the workspace.
nil before the first manual `dimfort-check-workspace' completes.")

(defvar dimfort--ws-stale nil
  "Non-nil when files have changed since the last workspace refresh.
The footer dims the Project segment in that case.")

(defvar dimfort--ws-refreshing nil
  "Non-nil while a workspace check is in flight.
Drives the spinner and keeps duplicate triggers coalesced.")

(defvar dimfort--ws-spinner-frame 0
  "Current frame index into `dimfort--ws-spinner-frames'.")

(defvar dimfort--ws-spinner-timer nil
  "Active spinner repeating timer, or nil.")

(defconst dimfort--ws-spinner-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Braille spinner cycle, ~80 ms cadence to match the other companions.")

(defconst dimfort--ws-spinner-interval 0.08
  "Spinner repaint interval (seconds).")

(defvar dimfort--file-coverage-cache (make-hash-table :test #'equal)
  "URI → plist `(:ok N :warn N :fire N :coverage-pct PCT)' for file-scope.")

(defun dimfort--coverage-from-row (row)
  "Build the canonical plist shape from a server-side coverage ROW."
  (list :ok (or (dimfort--field row "ok") 0)
        :warn (or (dimfort--field row "warn") 0)
        :fire (or (dimfort--field row "fire") 0)
        :unparsed (or (dimfort--field row "unparsed") 0)
        :coverage-pct (or (dimfort--field row "coverage_pct") 0)))

(defun dimfort--ws-stop-spinner ()
  "Cancel the spinner repeating timer if any."
  (when dimfort--ws-spinner-timer
    (cancel-timer dimfort--ws-spinner-timer)
    (setq dimfort--ws-spinner-timer nil)))

(defun dimfort--ws-start-spinner ()
  "Start the spinner repeating timer, repainting the panel each frame."
  (dimfort--ws-stop-spinner)
  (setq dimfort--ws-spinner-frame 0)
  (setq dimfort--ws-spinner-timer
        (run-at-time
         dimfort--ws-spinner-interval
         dimfort--ws-spinner-interval
         (lambda ()
           (setq dimfort--ws-spinner-frame
                 (mod (1+ dimfort--ws-spinner-frame)
                      (length dimfort--ws-spinner-frames)))
           (dimfort--panel-repaint)))))

(defun dimfort--ws-spinner-glyph ()
  "Return the current Braille spinner frame."
  (aref dimfort--ws-spinner-frames
        (mod dimfort--ws-spinner-frame
             (length dimfort--ws-spinner-frames))))

(defun dimfort--handle-workspace-check-completed (params)
  "Notification handler for `dimfort/workspaceCheckCompleted'.
PARAMS is the server-side workspace coverage payload, or `(:failed t)'
on the daemon worker's crash path.  Clears the in-flight flag and
spinner, updates `dimfort--ws-snapshot' on success, and repaints the
panel so the bar reflects the new state."
  (setq dimfort--ws-refreshing nil)
  (dimfort--ws-stop-spinner)
  (unless (or (null params)
              (and (hash-table-p params)
                   (gethash "failed" params))
              (plist-get params :failed))
    (let ((total (dimfort--field params "total")))
      (when total
        (setq dimfort--ws-snapshot (dimfort--coverage-from-row total))
        (setq dimfort--ws-stale nil))))
  (dimfort--panel-repaint))

(defun dimfort--ws-on-diagnostics-changed ()
  "Mark the workspace snapshot stale, refresh the active file's stats.
Called from the LSP-mode / eglot diagnostics-change hooks."
  (when (and dimfort--ws-snapshot (not dimfort--ws-stale))
    (setq dimfort--ws-stale t)
    (dimfort--panel-repaint))
  (dimfort--coverage-stats-refresh-active))

(defun dimfort--coverage-stats-refresh-active ()
  "Send `dimfort/coverageStats' for the current buffer's URI.
Updates `dimfort--file-coverage-cache' on response and repaints."
  (let ((uri (dimfort--coverage-uri)))
    (when uri
      (cond
       ((and (featurep 'eglot)
             (fboundp 'eglot-current-server)
             (eglot-current-server))
        (let ((server (eglot-current-server)))
          (when server
            (jsonrpc-async-request
             server :dimfort/coverageStats `(:uri ,uri)
             :success-fn
             (lambda (result)
               (dimfort--coverage-stats-store uri result))
             :error-fn (lambda (&rest _) nil)
             :timeout-fn (lambda (&rest _) nil)))))
       ((and (featurep 'lsp-mode)
             (fboundp 'lsp-request-async))
        (lsp-request-async
         "dimfort/coverageStats" `(:uri ,uri)
         (lambda (result)
           (dimfort--coverage-stats-store uri result))
         :mode 'tick))))))

(defun dimfort--coverage-stats-store (uri result)
  "Cache the file-scope coverage RESULT for URI and repaint the panel."
  (let ((files (or (and (hash-table-p result) (gethash "files" result))
                   (plist-get result :files))))
    (cond
     ((or (null files) (zerop (length files)))
      (remhash uri dimfort--file-coverage-cache))
     (t
      (let ((row (if (vectorp files) (aref files 0) (car files))))
        (when row
          (puthash uri (dimfort--coverage-from-row row)
                   dimfort--file-coverage-cache))))))
  (dimfort--panel-repaint))

(defun dimfort--coverage-active-uri ()
  "Return the URI of the panel's source Fortran buffer, or nil.

Reads `dimfort--panel-source-buffer' (the explicitly-tracked buffer
the panel is following) rather than `current-buffer'.  The footer
re-renders from multiple contexts (cursor moves, stats notifications,
workspace check completion …) and `current-buffer' is not reliable
across them — using it caused the footer to flash between populated
and empty depending on which event triggered the repaint."
  (let ((buf (or dimfort--panel-source-buffer (current-buffer))))
    (when (and (buffer-live-p buf)
               (with-current-buffer buf
                 (memq major-mode dimfort-fortran-modes)))
      (with-current-buffer buf
        (dimfort--coverage-uri)))))

(defun dimfort--panel-repaint ()
  "Repaint the panel buffer from the cached last payload.
Thin wrapper that re-renders cells using `dimfort--panel-last-payload'
and the current footer state without sending any LSP request — used
by the workspace coverage bar's spinner, notification handler, and
stale-flag toggle.  No-op when the panel buffer doesn't exist.

Also re-renders the *DimFort Coverage* report buffer when it's open
so the report tracks live state without any race-prone delays."
  (when (get-buffer dimfort--panel-buffer)
    (dimfort--panel-paint
     (dimfort--panel-render dimfort--panel-last-payload) nil))
  (when (get-buffer "*DimFort Coverage*")
    (dimfort--coverage-report-on-change)))

(defun dimfort--fmt-count (n)
  "Format a count N for the footer bar's parenthetical 🟡 / 🔴 counts.
Three-tier abbreviation chosen so big projects (e.g. 50k+ U-diags at
workspace scale on a real-world codebase) don't blow the footer width:

  <= 999      -> full integer (\"52\", \"999\")        -- actionable detail
  1000-9999   -> one decimal kilo (\"1.2k\", \"9.9k\") -- order-of-magnitude
  10000+      -> integer kilo (\"12k\", \"100k\")      -- coarse signal

Matches the GitHub-stars / Twitter-followers conventions; familiar
enough that no in-bar legend is needed."
  (cond
   ((<= n 999) (number-to-string n))
   ((< n 10000) (format "%.1fk" (/ n 1000.0)))
   (t (format "%dk" (/ n 1000)))))

(defun dimfort--panel-render-footer ()
  "Return the footer cells for the workspace + file coverage bar.
Always returns at least the divider + bar row so the footer is
visible regardless of payload state."
  (let* ((file-uri (dimfort--coverage-active-uri))
         (file (and file-uri (gethash file-uri dimfort--file-coverage-cache)))
         (file-text (if file
                        (format "File: %d%% (🟡 %s 🔴 %s)"
                                (plist-get file :coverage-pct)
                                (dimfort--fmt-count (plist-get file :warn))
                                (dimfort--fmt-count (plist-get file :fire)))
                      (dimfort--dim "File: –")))
         (root-tag (dimfort--root-source-tag))
         (ws-text (cond
                   (dimfort--ws-refreshing
                    (dimfort--dim
                     (concat (format "Project: %s" (dimfort--ws-spinner-glyph))
                             root-tag)))
                   ((null dimfort--ws-snapshot)
                    (dimfort--dim (concat "Project: –" root-tag)))
                   (t
                    (let ((s (concat
                              (format "Project: %d%% (🟡 %s 🔴 %s)"
                                      (plist-get dimfort--ws-snapshot :coverage-pct)
                                      (dimfort--fmt-count
                                       (plist-get dimfort--ws-snapshot :warn))
                                      (dimfort--fmt-count
                                       (plist-get dimfort--ws-snapshot :fire)))
                              root-tag)))
                      (if dimfort--ws-stale (dimfort--dim s) s))))))
    (list (dimfort--cell dimfort--panel-divider)
          (dimfort--cell (concat file-text "   " ws-text)))))

(defconst dimfort--panel-buffer "*dimfort-panel*")
(defconst dimfort--panel-divider (make-string 60 ?─))
(defconst dimfort--panel-markers
  '(("ok" . "🟢") ("assumed" . "🔵") ("warn" . "🟡") ("error" . "🔴")))
(defconst dimfort--panel-interaction-groups
  '(("declares" . "Declaration")
    ("contributes" . "Write")
    ("requires" . "Read")
    ("uses" . "Undetermined"))
  "Interaction-point kinds in display order, with their section labels.")
(defvar dimfort--panel-timer nil)
(defvar dimfort--panel-last-payload nil)
(defvar dimfort--panel-last-interactions nil)
(defvar dimfort--panel-last-actions nil)
(defvar dimfort--panel-source-buffer nil)
(defvar dimfort--panel-req-counter 0)
(defvar dimfort--scope-filter ""
  "Client-side name/unit filter for the Scope section (empty = no filter).")
(defvar dimfort--imports-filter ""
  "Client-side name/unit/module filter for the Imports section.")

;; -- field / sequence access (payload is a plist under eglot, a
;; -- hash-table under lsp-mode; arrays are vectors vs lists). --

(defun dimfort--seq (v)
  "Coerce V (a JSON array as a vector or list) to a list."
  (cond ((vectorp v) (append v nil)) ((listp v) v) (t nil)))

(defun dimfort--titlecase (s)
  "Capitalise the first letter of S."
  (if (or (null s) (string-empty-p s)) (or s "")
    (concat (upcase (substring s 0 1)) (substring s 1))))

(defun dimfort--pad (s w)
  "Left-justify S to display width W with trailing spaces."
  (concat s (make-string (max 0 (- w (string-width s))) ?\s)))

;; -- rendering (mirrors the Neovim panel so the two read identically) --
;;
;; A *cell* is (TEXT . TARGET): the display string and an optional
;; navigation target. TARGET is nil (inert), or a plist
;;   (:file F :line L :column C)        — jump (cross-file when :file set)
;; or (:action ACTION)                  — a CodeAction to apply.
;; The renderers return ordered lists of cells; `dimfort--panel-paint'
;; stamps each line with its target as a text property so RET can act.

(defun dimfort--cell (text &optional target)
  "Make a panel cell: display TEXT with an optional navigation TARGET."
  (cons text target))

(defun dimfort--dim (text)
  "Return TEXT propertized with the dimmed `shadow' face.
Used for empty-state placeholders and interaction source snippets, to
match the VSCode panel's muted styling."
  (propertize text 'face 'shadow))

(defun dimfort--base-name (path)
  "Return the last path component of PATH."
  (let ((p (or path "")))
    (if (string-match "[^/\\]+\\'" p) (match-string 0 p) p)))

(defun dimfort--panel-collect-expr (node prefix is-last is-root)
  "Return an ordered list of entry plists for expression NODE and descendants.
PREFIX is the tree-drawing prefix; IS-LAST / IS-ROOT shape the connector."
  (when node
    (let* ((connector (cond (is-root "") (is-last "└── ") (t "├── ")))
           (next-prefix (cond (is-root prefix)
                              (is-last (concat prefix "    "))
                              (t (concat prefix "│   "))))
           (expected (dimfort--field node "expected"))
           (assumed (dimfort--field node "assumed"))
           (collides (dimfort--field node "collides"))
           (marker (dimfort--field node "marker"))
           ;; Row tail: `(expected …)' on call-arg / RHS mismatch,
           ;; `(collides with …)' on H020 polymorphic-call-site
           ;; conflicts, `(assumed: <reason>)' on @unit_assume rows.
           ;; May apply together; concatenate.
           (extra (concat
                    (if expected (format " (expected %s)" expected) "")
                    (if collides (format " (collides with %s)" collides) "")
                    (if assumed (format " (assumed: %s)" assumed) "")))
           (entry (list :tree (concat prefix connector
                                      (or (dimfort--field node "label") "?"))
                        :unit (dimfort--field node "unit")
                        :mark (or (cdr (assoc marker dimfort--panel-markers)) " ")
                        :extra extra))
           (children (dimfort--seq (dimfort--field node "children")))
           (n (length children))
           (result (list entry)))
      (cl-loop for c in children for i from 1 do
               (setq result (append result
                                    (dimfort--panel-collect-expr
                                     c next-prefix (= i n) nil))))
      result)))

(defun dimfort--panel-render-expr (node)
  "Return a list of aligned cells for expression NODE."
  (let ((entries (dimfort--panel-collect-expr node "" t t))
        (tree-w 0) (unit-w 0) (rows '()))
    (dolist (e entries)
      (setq tree-w (max tree-w (string-width (plist-get e :tree))))
      (when (plist-get e :unit)
        (setq unit-w (max unit-w (string-width (plist-get e :unit))))))
    (dolist (e entries)
      (let* ((tree (plist-get e :tree))
             (tree-pad (make-string (- tree-w (string-width tree)) ?\s))
             (unit (plist-get e :unit))
             ;; Dim absence-of-information glyphs ("?" / "-") so real
             ;; units pop. Text properties propagate through concat.
             ;; ``'a = ?`` (H020 unbound polymorphic return) is a
             ;; third case — mute only the trailing ``?`` so the
             ;; unknown component reads at the same visual weight as
             ;; a bare ``?``; the bound prefix stays full-weight. The
             ;; suffix check is tight enough not to false-positive —
             ;; concrete units never end in ``= ?``.
             (unit-styled
              (cond
                ((not unit) nil)
                ((member unit '("?" "-")) (dimfort--dim unit))
                ((and (>= (length unit) 4)
                      (string= (substring unit -4) " = ?"))
                 (concat (substring unit 0 -1) (dimfort--dim "?")))
                (t unit)))
             (mid (cond
                   (unit (concat " : " unit-styled
                                 (make-string (- unit-w (string-width unit)) ?\s)))
                   ((> unit-w 0) (make-string (+ 3 unit-w) ?\s))
                   (t ""))))
        (push (dimfort--cell (concat tree tree-pad mid "  "
                                     (plist-get e :mark) (plist-get e :extra)))
              rows)))
    (nreverse rows)))

(defun dimfort--panel-status-rank (kind)
  "Return a numeric rank used by the \"status\" sort mode."
  (cond ((equal kind "error") 0)
        ((equal kind "unannotated") 1)
        (t 2)))

(defun dimfort--panel-sort-scope-vars (vars)
  "Return VARS sorted per `dimfort-panel-sort-mode'.
Returns a fresh list so the server-supplied vector stays untouched."
  (let ((out (copy-sequence (append vars nil))))
    (cond
     ((equal dimfort-panel-sort-mode "alphabetic")
      (sort out (lambda (a b)
                  (string< (downcase (or (dimfort--field a "name") ""))
                           (downcase (or (dimfort--field b "name") ""))))))
     ((equal dimfort-panel-sort-mode "status")
      (sort out (lambda (a b)
                  (let ((ra (dimfort--panel-status-rank (dimfort--field a "kind")))
                        (rb (dimfort--panel-status-rank (dimfort--field b "kind"))))
                    (if (= ra rb)
                        (< (or (dimfort--field a "line") 0)
                           (or (dimfort--field b "line") 0))
                      (< ra rb))))))
     (t  ;; "line" — the default
      (sort out (lambda (a b)
                  (< (or (dimfort--field a "line") 0)
                     (or (dimfort--field b "line") 0))))))))

(defun dimfort--panel-sort-imports-vars (vars)
  "Sort imports rows VARS within a module group per `dimfort-panel-sort-mode'.
Tie-breaks by name rather than line — Imports don't always carry a
meaningful per-row line beyond the `use' statement."
  (let ((out (copy-sequence (append vars nil))))
    (cond
     ((equal dimfort-panel-sort-mode "alphabetic")
      (sort out (lambda (a b)
                  (string< (downcase (or (dimfort--field a "name") ""))
                           (downcase (or (dimfort--field b "name") ""))))))
     ((equal dimfort-panel-sort-mode "status")
      (sort out (lambda (a b)
                  (let ((ra (if (equal (dimfort--field a "kind") "unannotated") 0 1))
                        (rb (if (equal (dimfort--field b "kind") "unannotated") 0 1)))
                    (if (= ra rb)
                        (string< (downcase (or (dimfort--field a "name") ""))
                                 (downcase (or (dimfort--field b "name") "")))
                      (< ra rb))))))
     (t  ;; "line"
      (sort out (lambda (a b)
                  (< (or (dimfort--field a "line") 0)
                     (or (dimfort--field b "line") 0))))))))

(defun dimfort--panel-shown-unit (v)
  "Return the unit string for row V per `dimfort-panel-unit-display-mode'.
Canonical falls back to the input unit when the server didn't emit a
normalised form — meaning the input is already canonical."
  (let ((src (dimfort--field v "unit"))
        (norm (dimfort--field v "unitNormalized")))
    (cond
     ((equal dimfort-panel-unit-display-mode "canonical")
      (or norm src "?"))
     (t (or src "?")))))

(defun dimfort--panel-shown-import-unit (im)
  "Return the unit string for import row IM per `dimfort-panel-unit-display-mode'.
Canonical mode falls back to input when the server has no normalised
form.  Annotated callables with no unit (subroutines) read as \"-\"."
  (let* ((src (dimfort--field im "unit"))
         (norm (dimfort--field im "unitNormalized")))
    (cond
     ((equal dimfort-panel-unit-display-mode "canonical")
      (or norm src
          (if (and (eq (dimfort--field im "callable") t)
                   (equal (dimfort--field im "kind") "annotated"))
              "-" "?")))
     (t (or src
            (if (and (eq (dimfort--field im "callable") t)
                     (equal (dimfort--field im "kind") "annotated"))
                "-" "?"))))))

(defun dimfort--panel-var-matches (v query)
  "Non-nil when var V's name or unit contains QUERY (case-insensitive)."
  (or (string-empty-p query)
      (let ((name (downcase (or (dimfort--field v "name") "")))
            (unit (downcase (or (dimfort--field v "unit") ""))))
        (or (string-search query name)
            (and (not (string-empty-p unit)) (string-search query unit))))))

(defun dimfort--panel-render-scope (scope vars depth)
  "Return cells for SCOPE and its VARS, indented by nesting DEPTH.
Each variable row carries a jump target to its declaration line."
  (let* ((pad (make-string (* 2 (or depth 0)) ?\s))
         (rows '())
         (vs (dimfort--seq vars)))
    (push (dimfort--cell
           (if scope
               (concat pad (format "%s: %s"
                                   (dimfort--titlecase (dimfort--field scope "kind"))
                                   (or (dimfort--field scope "name") "")))
             (concat pad "Scope: (file level)")))
          rows)
    (push (dimfort--cell "") rows)
    (if (null vs)
        (push (dimfort--cell (dimfort--dim (concat pad "  (no declarations)"))) rows)
      ;; Sort BEFORE width computation so column widths reflect the
      ;; rendered order. Unit-display mode also drives width: in
      ;; canonical mode the displayed string is the canonical form.
      (setq vs (dimfort--panel-sort-scope-vars vs))
      (let ((name-w 4) (unit-w 4) (norm-w 0)
            (both-p (equal dimfort-panel-unit-display-mode "both")))
        (dolist (v vs)
          (setq name-w (max name-w (string-width (or (dimfort--field v "name") ""))))
          (setq unit-w (max unit-w (string-width (dimfort--panel-shown-unit v))))
          ;; Normalized column: only meaningful in "both" mode; shown
          ;; on rows whose normalized form differs from the source.
          (when both-p
            (let ((norm (dimfort--field v "unitNormalized"))
                  (src  (dimfort--field v "unit")))
              (when (and norm (not (equal norm src)))
                (setq norm-w (max norm-w (string-width norm)))))))
        ;; Two-space gap between source-unit and normalized columns
        ;; matches the side-by-side ``<td>`` convention used by the
        ;; VSCode panel — no arrow / separator glyph (column spacing
        ;; already conveys the second cell).
        (let ((norm-block-w (if (> norm-w 0) norm-w 0)))
          (dolist (v vs)
            (let* ((unit (dimfort--panel-shown-unit v))
                   (kind (dimfort--field v "kind"))
                   (line (or (dimfort--field v "line") 0))
                   (tail (cond ((equal kind "unannotated") " 🟡")
                               ((equal kind "error") " 🔴")
                               (t " 🟢")))
                   ;; Dim absence-of-information glyphs (`?` = unknown,
                   ;; `-` = structural-no-unit) so real units pop visually.
                   (unit-padded (dimfort--pad unit unit-w))
                   (unit-cell (if (member unit '("?" "-"))
                                  (dimfort--dim unit-padded)
                                unit-padded))
                   ;; Only used in "both" mode (norm-block-w == 0 in
                   ;; input/canonical modes so the block is skipped).
                   (norm (dimfort--field v "unitNormalized"))
                   (src  (dimfort--field v "unit"))
                   (norm-block
                    (cond
                     ((zerop norm-block-w) "")
                     ((and norm (not (equal norm src)))
                      (concat "  " norm
                              (make-string (- norm-w (string-width norm)) ?\s)))
                     (t (concat "  " (make-string norm-block-w ?\s))))))
              (push (dimfort--cell
                     (concat pad "  " (dimfort--pad (number-to-string line) 4)
                             "  " (dimfort--pad (or (dimfort--field v "name") "") name-w)
                             "  " unit-cell norm-block tail)
                     (list :line line))
                    rows))))))
    (nreverse rows)))

(defun dimfort--panel-render-scope-section (payload)
  "Return the Scope section cells for PAYLOAD, with the active filter applied."
  (let* ((q (downcase (or dimfort--scope-filter "")))
         (rows '())
         (scopes (dimfort--seq (and payload (dimfort--field payload "scopes")))))
    (unless (string-empty-p q)
      (push (dimfort--cell (format "Filter: \"%s\"  (dimfort-scope-filter to change)"
                                   dimfort--scope-filter))
            rows)
      (push (dimfort--cell "") rows))
    (cond
     ((and payload scopes)
      (let ((shown nil))
        (cl-loop for sc in scopes for i from 0 do
                 (let* ((all (dimfort--seq (dimfort--field sc "vars")))
                        (kept (if (string-empty-p q) all
                                (cl-remove-if-not
                                 (lambda (v) (dimfort--panel-var-matches v q)) all))))
                   (when (or (string-empty-p q) kept)
                     (when shown (push (dimfort--cell "") rows))
                     (setq rows (append (nreverse (dimfort--panel-render-scope
                                                   sc (vconcat kept) i))
                                        rows))
                     (setq shown t))))
        (when (and (not (string-empty-p q)) (not shown))
          (push (dimfort--cell
                 (dimfort--dim
                  (format "  (no variables match \"%s\")" dimfort--scope-filter)))
                rows))))
     (payload
      (setq rows (append (nreverse (dimfort--panel-render-scope
                                    (or (dimfort--field payload "scope")
                                        (dimfort--field payload "routine"))
                                    (or (dimfort--field payload "scopeVars")
                                        (dimfort--field payload "routineVars"))
                                    0))
                         rows)))
     (t (push (dimfort--cell (dimfort--dim "Scope: (none)")) rows)))
    (nreverse rows)))

(defun dimfort--panel-render-diagnostics (payload)
  "Return Diagnostics section cells (cursor-line diagnostics) for PAYLOAD."
  (let ((diags (dimfort--seq (and payload (dimfort--field payload "diagnostics")))))
    (if (null diags)
        (list (dimfort--cell (dimfort--dim "  (none)")))
      (mapcar
       (lambda (d)
         (let* ((sev (or (dimfort--field d "severity") "info"))
                (glyph (cond ((equal sev "error") "🔴")
                             ((equal sev "warning") "🟡") (t "🔵")))
                ;; Colour the row by severity with theme-aware built-in faces,
                ;; mirroring Nvim's DiagnosticError/Warn/Info groups and the
                ;; VSCode editorError/Warning/Info colours.
                (face (cond ((equal sev "error") 'error)
                            ((equal sev "warning") 'warning)
                            (t 'shadow)))
                (code (or (dimfort--field d "code") "?"))
                (msg (or (dimfort--field d "message") "")))
           (dimfort--cell (propertize (concat "  " glyph " " code ": " msg)
                                      'face face)
                          (list :line (dimfort--field d "line")
                                :column (dimfort--field d "column")))))
       diags))))

(defun dimfort--panel-render-interactions (rep)
  "Return Interactions section cells for the interactions report REP."
  (let ((points (dimfort--seq (and rep (dimfort--field rep "points")))))
    (if (null points)
        (list (dimfort--cell (dimfort--dim "  (none)")))
      (let ((rows '()))
        (push (dimfort--cell (concat "  " (or (dimfort--field rep "symbol") "?"))) rows)
        (dolist (c (dimfort--seq (dimfort--field rep "conflicts")))
          (push (dimfort--cell
                 (propertize
                  (concat "  🔴 " (or (dimfort--field c "code") "?") ": "
                          (or (dimfort--field c "message") ""))
                  'face 'error)
                 (list :file (dimfort--field c "file")
                       :line (dimfort--field c "line")
                       :column (dimfort--field c "column")))
                rows))
        (dolist (group dimfort--panel-interaction-groups)
          (let ((kind (car group))
                (pts '()))
            (dolist (p points)
              (when (equal (dimfort--field p "kind") kind) (push p pts)))
            (setq pts (nreverse pts))
            (push (dimfort--cell (concat "  " (cdr group))) rows)
            (if (null pts)
                (push (dimfort--cell (dimfort--dim "      (none)")) rows)
              (dolist (p pts)
                (let* ((file (dimfort--field p "file"))
                       (line (dimfort--field p "line"))
                       (loc (concat (dimfort--base-name (dimfort--uri-to-file (or file "")))
                                    ":" (number-to-string (or line 0))))
                       (unit (and (not (equal kind "uses"))
                                  (dimfort--field p "unit")))
                       ;; Dim absence-of-information glyphs so real
                       ;; units pop, the same way Scope / Imports /
                       ;; Expression do.
                       (unit-styled (and unit
                                         (if (member unit '("?" "-"))
                                             (dimfort--dim unit)
                                           unit)))
                       (target (list :file file :line line
                                     :column (dimfort--field p "column")))
                       (snippet (dimfort--field p "snippet")))
                  (push (dimfort--cell
                         (concat "      " loc
                                 (if unit (concat "   " unit-styled) ""))
                         target)
                        rows)
                  (when (and snippet (not (string-empty-p snippet)))
                    (push (dimfort--cell (dimfort--dim (concat "        " snippet)) target) rows)))))))
        (nreverse rows)))))

(defun dimfort--panel-render-actions (actions)
  "Return Actions section cells for the CodeAction list ACTIONS."
  (let ((as (dimfort--seq actions)))
    (if (null as)
        (list (dimfort--cell (dimfort--dim "  (none)")))
      (mapcar
       (lambda (a)
         (let ((title (replace-regexp-in-string
                       "\\`DimFort:[ \t]*" ""
                       (or (dimfort--field a "title") "(action)"))))
           (dimfort--cell (concat "  • " title) (list :action a))))
       as))))

(defun dimfort--import-label (im)
  "Display name for import IM — a callable reads as name + its signature
\(the parenthesised argument units, e.g. \"force(kg, m)\")."
  (let ((n (or (dimfort--field im "name") "?")))
    (if (eq (dimfort--field im "callable") t)
        (concat n (or (dimfort--field im "signature") "()"))
      n)))

(defun dimfort--import-matches (im query)
  "Non-nil when import IM's name, unit, or module contains QUERY."
  (or (string-empty-p query)
      (let ((name (downcase (dimfort--import-label im)))
            (unit (downcase (or (dimfort--field im "unit") "")))
            (mod (downcase (or (dimfort--field im "module") ""))))
        (or (string-search query name)
            (and (not (string-empty-p unit)) (string-search query unit))
            (and (not (string-empty-p mod)) (string-search query mod))))))

(defun dimfort--panel-render-imports (imports)
  "Return Imports section cells, grouped by source module.
Variables and procedures (callables read as \"name(args)\"); each row
navigates cross-file to the declaration.  Has its own name/unit/module
filter (`dimfort--imports-filter', set via `dimfort-imports-filter')."
  (let* ((q (downcase (or dimfort--imports-filter "")))
         (all (dimfort--seq imports))
         (ims (if (string-empty-p q) all
                (cl-remove-if-not (lambda (im) (dimfort--import-matches im q)) all)))
         (header (unless (string-empty-p q)
                   (list (dimfort--cell
                          (format "Filter: \"%s\"  (dimfort-imports-filter to change)"
                                  dimfort--imports-filter))
                         (dimfort--cell "")))))
    (if (null ims)
        (append header
                (list (dimfort--cell
                       (if (and (not (string-empty-p q)) all)
                           (dimfort--dim
                            (format "  (no imports match \"%s\")" dimfort--imports-filter))
                         (dimfort--dim "  (none)")))))
      (let ((order '()) (groups (make-hash-table :test #'equal)) (rows '()))
        (dolist (im ims)
          (let ((m (or (dimfort--field im "module") "?")))
            (unless (gethash m groups) (push m order))
            (puthash m (cons im (gethash m groups)) groups)))
        (dolist (m (nreverse order))
          (push (dimfort--cell (concat "  from " m)) rows)
          ;; Sort within the module group; module headers stay in
          ;; source ``use``-order regardless.
          (let ((items (dimfort--panel-sort-imports-vars (nreverse (gethash m groups))))
                (name-w 4) (unit-w 4) (norm-w 0)
                (both-p (equal dimfort-panel-unit-display-mode "both")))
            (dolist (im items)
              (setq name-w (max name-w (string-width (dimfort--import-label im))))
              (setq unit-w (max unit-w (string-width (dimfort--panel-shown-import-unit im))))
              (when both-p
                (let ((norm (dimfort--field im "unitNormalized"))
                      (src  (dimfort--field im "unit")))
                  (when (and norm (not (equal norm src)))
                    (setq norm-w (max norm-w (string-width norm)))))))
            (let ((norm-block-w (if (> norm-w 0) norm-w 0)))
              (dolist (im items)
                (let* ((unit (dimfort--panel-shown-import-unit im))
                       (tail (if (equal (dimfort--field im "kind") "unannotated")
                                 " 🟡" " 🟢"))
                       ;; Dim absence-of-information glyphs so real units pop.
                       (unit-padded (dimfort--pad unit unit-w))
                       (unit-cell (if (member unit '("?" "-"))
                                      (dimfort--dim unit-padded)
                                    unit-padded))
                       (norm (dimfort--field im "unitNormalized"))
                       (src  (dimfort--field im "unit"))
                       (norm-block
                        (cond
                         ((zerop norm-block-w) "")
                         ((and norm (not (equal norm src)))
                          (concat "  " norm
                                  (make-string (- norm-w (string-width norm)) ?\s)))
                         (t (concat "  " (make-string norm-block-w ?\s)))))
                       (target (list :file (dimfort--field im "file")
                                     :line (dimfort--field im "line")
                                     :column (dimfort--field im "column"))))
                  (push (dimfort--cell
                         (concat "      "
                                 (dimfort--pad (dimfort--import-label im) name-w)
                                 "  " unit-cell norm-block tail)
                         target)
                        rows))))))
        (append header (nreverse rows))))))

(defun dimfort--panel-render (payload)
  "Return the full list of panel cells for PAYLOAD."
  (let ((rows '()))
    (cl-flet ((add (&rest cells) (setq rows (append rows cells)))
              (sec (title body)
                (setq rows (append rows
                                   (list (dimfort--cell title) (dimfort--cell ""))
                                   body
                                   (list (dimfort--cell ""))))))
      ;; Per-section visibility (0.2.6).  Each section renders
      ;; independently against its `dimfort-show-*' boolean; dividers
      ;; between sections only emit when both neighbours are visible
      ;; so toggling any one off doesn't leave a stranded separator.
      (when dimfort-show-cursor
        (let ((expr (and payload (dimfort--field payload "expression"))))
          (sec "Expression"
               (if expr (dimfort--panel-render-expr expr)
                 (list (dimfort--cell (dimfort--dim "  (none)"))))))
        (sec "Diagnostics" (dimfort--panel-render-diagnostics payload))
        (sec "Interactions"
             (dimfort--panel-render-interactions dimfort--panel-last-interactions))
        (sec "Actions"
             (dimfort--panel-render-actions dimfort--panel-last-actions)))
      (when dimfort-show-scope
        (when dimfort-show-cursor
          (add (dimfort--cell dimfort--panel-divider) (dimfort--cell "")))
        (sec "Scope" (dimfort--panel-render-scope-section payload)))
      (when dimfort-show-imports
        (when (or dimfort-show-scope dimfort-show-cursor)
          ;; Divider between Scope and Imports matches the visual
          ;; treatment around Actions/Scope and Imports/Footer, and
          ;; mirrors the per-view boundary in the multi-view VSCompanion.
          (add (dimfort--cell dimfort--panel-divider) (dimfort--cell "")))
        (sec "Imports"
             (dimfort--panel-render-imports
              (and payload (dimfort--field payload "imports")))))
      ;; Footer: coverage bar (file + workspace).  Always rendered
      ;; regardless of section visibility — the project-wide coverage
      ;; indicator is universally useful and users who hide all three
      ;; sections still benefit from seeing the live coverage stats.
      (setq rows (append rows (dimfort--panel-render-footer))))
    rows))

(defun dimfort--panel-paint (cells stale)
  "Write CELLS into the panel buffer; dim them when STALE.
Each cell's navigation target (if any) is stamped on its line as the
`dimfort-target' text property so RET can act on it.

The panel window's scroll position (`window-start') and point
(`window-point') are saved before the erase and restored after the
insert (clamped to the new `point-max'), so a scrolled view survives
the repaint that fires on every source-cursor move — otherwise the
user can never see the bottom of the panel while editing."
  (let* ((buf (get-buffer dimfort--panel-buffer))
         (win (and buf (get-buffer-window buf 'visible)))
         (saved-start (and win (window-start win)))
         (saved-point (and win (window-point win))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (dolist (cell cells)
            (let ((start (point))
                  (text (if (consp cell) (car cell) cell))
                  (target (and (consp cell) (cdr cell))))
              (insert text "\n")
              (when target
                (put-text-property start (point) 'dimfort-target target))))
          (when stale
            (add-text-properties (point-min) (point-max) '(face shadow))))
        (when win
          (let ((cap (point-max)))
            (set-window-start win (min (or saved-start 1) cap))
            (set-window-point win (min (or saved-point 1) cap))))))))

;; -- window lifecycle + LSP request --

(defvar dimfort-panel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'dimfort--panel-activate)
    (define-key map [mouse-1] #'dimfort--panel-activate)
    map)
  "Keymap for `dimfort-panel-mode'.")

(define-derived-mode dimfort-panel-mode special-mode "DimFort-Panel"
  "Major mode for the DimFort side panel."
  (setq truncate-lines t)
  (setq-local cursor-type nil)
  ;; Smooth, line-by-line scrolling — better for a sidebar than half-page
  ;; jumps, so the user can align a section header (Scope, Imports, ...)
  ;; precisely at the top without it splitting across a page boundary.
  ;; ``scroll-conservatively`` makes auto-scroll on point movement step a
  ;; single line at a time; ``scroll-margin 0`` removes the enforced top/
  ;; bottom margin so the alignment is exact. Mouse wheel and arrows then
  ;; scroll continuously; C-v / M-v stay as standard page-scroll for big
  ;; jumps. Same approach as treemacs/magit-status side buffers.
  (setq-local scroll-margin 0
              scroll-conservatively 101))

(defun dimfort--panel-goto (target)
  "Jump to TARGET's (:file :line :column) in a non-panel window."
  (let* ((file (plist-get target :file))
         (line (plist-get target :line))
         (column (plist-get target :column))
         (buf (if (and file (not (string-empty-p file)))
                  (find-file-noselect (dimfort--uri-to-file file))
                dimfort--panel-source-buffer)))
    (when (buffer-live-p buf)
      (let* ((pw (dimfort--panel-window))
             (win (or (get-buffer-window buf)
                      (seq-find (lambda (w) (not (eq w pw)))
                                (window-list nil 'no-mini)))))
        (if (window-live-p win) (select-window win)
          (setq win (display-buffer buf)))
        (when (window-live-p win)
          (select-window win)
          (switch-to-buffer buf)
          (goto-char (point-min))
          (forward-line (max 0 (1- (or line 1))))
          (move-to-column (max 0 (1- (or column 1))))
          (recenter))))))

(defun dimfort--panel-apply-action (action)
  "Apply the CodeAction ACTION — DimFort's own client commands, else defer."
  (let* ((cmd (dimfort--field action "command"))
         (name (cond ((stringp cmd) cmd)
                     (cmd (dimfort--field cmd "command")) (t nil)))
         (args (dimfort--seq
                (cond ((stringp cmd) (dimfort--field action "arguments"))
                      (cmd (dimfort--field cmd "arguments"))))))
    (cond
     ((equal name "dimfort.insertSnippet")
      (apply #'dimfort--insert-snippet args))
     ((equal name "dimfort.extractToParameter")
      (apply #'dimfort--extract-to-parameter args))
     ((and (featurep 'eglot) (fboundp 'eglot-execute) (fboundp 'eglot-current-server)
           (eglot-current-server))
      (eglot-execute (eglot-current-server) action))
     (t (message "DimFort: cannot apply this action from the panel.")))))

(defun dimfort--panel-activate ()
  "Act on the panel row at point: jump to a location, or apply an action.

Internal helper bound to RET / mouse-1 inside the panel buffer
via `dimfort-panel-mode-map'; not intended as a user command."
  (interactive)
  (let ((target (get-text-property (point) 'dimfort-target)))
    (when target
      (if (plist-get target :action)
          (dimfort--panel-apply-action (plist-get target :action))
        (dimfort--panel-goto target)))))

(defun dimfort--panel-get-buffer ()
  "Return the panel buffer, creating it in `dimfort-panel-mode' if needed."
  (or (get-buffer dimfort--panel-buffer)
      (with-current-buffer (get-buffer-create dimfort--panel-buffer)
        (dimfort-panel-mode)
        (current-buffer))))

(defun dimfort--panel-window ()
  "Return the live window showing the panel, or nil."
  (let ((buf (get-buffer dimfort--panel-buffer)))
    (and buf (get-buffer-window buf t))))

(defun dimfort--panel-display-action ()
  "Return the `display-buffer' action placing the panel on its side.

The `no-delete-other-windows' parameter keeps the panel alive through
`delete-other-windows' / `C-x 1' / the ESC-ESC-ESC quit, so it behaves
like a pinned sidebar rather than vanishing on the first quit."
  (if (eq dimfort-panel-side 'bottom)
      `((display-buffer-in-side-window) (side . bottom)
        (window-height . ,dimfort-panel-height)
        (window-parameters . ((no-delete-other-windows . t))))
    `((display-buffer-in-side-window) (side . ,dimfort-panel-side)
      (window-width . ,dimfort-panel-width)
      (window-parameters . ((no-delete-other-windows . t))))))

(defun dimfort--uri-of (buf)
  "Return the file:// URI for BUF, preferring the active client's helper."
  (cond
   ((and (featurep 'eglot) (fboundp 'eglot-path-to-uri) (buffer-file-name buf))
    (eglot-path-to-uri (buffer-file-name buf)))
   ((and (featurep 'eglot) (fboundp 'eglot--path-to-uri) (buffer-file-name buf))
    (eglot--path-to-uri (buffer-file-name buf)))
   ((and (featurep 'lsp-mode) (fboundp 'lsp--buffer-uri))
    (with-current-buffer buf (lsp--buffer-uri)))
   (t (concat "file://" (or (buffer-file-name buf) "")))))

(defun dimfort--panel-position-params (buf)
  "Build the `dimfort/panelInfo' params for the cursor position in BUF."
  (with-current-buffer buf
    (list :textDocument (list :uri (dimfort--uri-of buf))
          :position (list :line (1- (line-number-at-pos (point) t))
                          :character (- (point) (line-beginning-position))))))

(defun dimfort--panel-rpc (buf method params callback)
  "Send LSP request METHOD with PARAMS for BUF, calling CALLBACK on the result.

METHOD is the bare method string (e.g. \"dimfort/panelInfo\"). Best-effort:
on any failure CALLBACK is simply not called, so a section keeps its last
content rather than erroring. Guards against a server that is absent or
mid-restart (a debounce timer can fire while `dimfort-restart' has shut the
old process down)."
  (with-current-buffer buf
    (let ((server (and (featurep 'eglot) (fboundp 'eglot-current-server)
                       (eglot-current-server))))
      (cond
       ((and server (fboundp 'jsonrpc-async-request)
             (or (not (fboundp 'jsonrpc-running-p))
                 (jsonrpc-running-p server)))
        (ignore-errors
          (jsonrpc-async-request
           server (intern (concat ":" method)) params
           :success-fn callback
           :error-fn #'ignore
           :timeout 2)))
       ((and (featurep 'lsp-mode) (fboundp 'lsp-request-async)
             (fboundp 'lsp-workspaces) (lsp-workspaces))
        (ignore-errors
          (lsp-request-async method params callback :error-handler #'ignore)))
       (t (dimfort--panel-paint
           (list (dimfort--cell "(DimFort LSP not attached)")) nil))))))

(defun dimfort--diag-to-lsp (d)
  "Convert a panelInfo PanelDiagnostic D to an LSP Diagnostic plist.

The panel reconstructs the code-action request context from the cursor
line's diagnostics (the server keys the H010 extract action off them),
matching what VSCode's executeCodeActionProvider supplies automatically.
PanelDiagnostic spans are 1-based; LSP ranges are 0-based."
  (let ((line (or (dimfort--field d "line") 1))
        (col (or (dimfort--field d "column") 1))
        (eline (or (dimfort--field d "endLine") (dimfort--field d "line") 1))
        (ecol (or (dimfort--field d "endColumn") (dimfort--field d "column") 1))
        (sev (or (dimfort--field d "severity") "info")))
    (list :range (list :start (list :line (1- line) :character (1- col))
                       :end (list :line (1- eline) :character (1- ecol)))
          :severity (cond ((equal sev "error") 1) ((equal sev "warning") 2)
                          ((equal sev "info") 3) (t 4))
          :code (or (dimfort--field d "code") "")
          :message (or (dimfort--field d "message") ""))))

(defun dimfort--dimfort-action-p (action)
  "Non-nil when ACTION is one of DimFort's own code actions."
  (let* ((title (or (dimfort--field action "title") ""))
         (cmd (dimfort--field action "command"))
         (name (cond ((stringp cmd) cmd)
                     (cmd (dimfort--field cmd "command")) (t ""))))
    (or (string-prefix-p "dimfort." (or name ""))
        (string-match-p "[Uu]nit\\|PARAMETER" title))))

(defun dimfort--panel-refresh ()
  "Re-request panel info for the current source buffer and repaint.

Fires `dimfort/panelInfo' first; on its result also fires
`dimfort/interactions' and `textDocument/codeAction' (their results
populate the Interactions and Actions sections). Each response repaints."
  (setq dimfort--panel-timer nil)
  (when (dimfort--panel-window)
    (let ((buf dimfort--panel-source-buffer))
      (if (and buf (buffer-live-p buf))
          (let ((params (dimfort--panel-position-params buf))
                (req (cl-incf dimfort--panel-req-counter)))
            (dimfort--panel-paint (dimfort--panel-render dimfort--panel-last-payload) t)
            (dimfort--panel-rpc
             buf "dimfort/panelInfo" params
             (lambda (result)
               (when (= req dimfort--panel-req-counter)
                 (setq dimfort--panel-last-payload result)
                 (dimfort--panel-paint (dimfort--panel-render result) nil)
                 ;; Code-action context = the cursor line's diagnostics, so
                 ;; the H010 extract action is offered.
                 (let* ((diags (dimfort--seq (dimfort--field result "diagnostics")))
                        (ctx-diags (apply #'vector
                                          (mapcar #'dimfort--diag-to-lsp diags)))
                        (ca-params
                         (list :textDocument (plist-get params :textDocument)
                               :range (list :start (plist-get params :position)
                                            :end (plist-get params :position))
                               :context (list :diagnostics ctx-diags))))
                   (dimfort--panel-rpc
                    buf "textDocument/codeAction" ca-params
                    (lambda (actions)
                      (when (= req dimfort--panel-req-counter)
                        (setq dimfort--panel-last-actions
                              (apply #'vector
                                     (cl-remove-if-not #'dimfort--dimfort-action-p
                                                       (dimfort--seq actions))))
                        (dimfort--panel-paint
                         (dimfort--panel-render dimfort--panel-last-payload) nil))))))))
            (dimfort--panel-rpc
             buf "dimfort/interactions" params
             (lambda (rep)
               (when (= req dimfort--panel-req-counter)
                 (setq dimfort--panel-last-interactions rep)
                 (dimfort--panel-paint
                  (dimfort--panel-render dimfort--panel-last-payload) nil)))))
        (dimfort--panel-paint (list (dimfort--cell "(no Fortran buffer)")) nil)))))

(defun dimfort--panel-maybe-schedule ()
  "On `post-command-hook': debounce a refresh when in a managed Fortran buffer."
  (when (and (dimfort--panel-window)
             (memq major-mode dimfort-fortran-modes)
             (buffer-file-name))
    (setq dimfort--panel-source-buffer (current-buffer))
    (when (timerp dimfort--panel-timer) (cancel-timer dimfort--panel-timer))
    (setq dimfort--panel-timer
          (run-with-timer dimfort-panel-debounce nil #'dimfort--panel-refresh))))

(defun dimfort--panel-open ()
  "Open the DimFort side panel and start following the cursor.

Internal helper.  The user-facing entry point is
`dimfort-toggle-panel'; this function is exposed only so
`dimfort--panel-maybe-autoopen' and the toggle can call it."
  (interactive)
  (dimfort--panel-get-buffer)
  (display-buffer dimfort--panel-buffer (dimfort--panel-display-action))
  (add-hook 'post-command-hook #'dimfort--panel-maybe-schedule)
  (when (memq major-mode dimfort-fortran-modes)
    (setq dimfort--panel-source-buffer (current-buffer)))
  (dimfort--panel-refresh))

(defun dimfort--panel-close ()
  "Close the DimFort side panel and stop following the cursor.

Internal helper.  The user-facing entry point is
`dimfort-toggle-panel'; this function is exposed only so the
toggle can call it."
  (interactive)
  (remove-hook 'post-command-hook #'dimfort--panel-maybe-schedule)
  (when (timerp dimfort--panel-timer)
    (cancel-timer dimfort--panel-timer)
    (setq dimfort--panel-timer nil))
  (let ((win (dimfort--panel-window)))
    (when win (delete-window win))))

;;;###autoload
(defun dimfort-toggle-panel ()
  "Toggle the DimFort side panel.

Renamed from `dimfort-panel-toggle' in 0.2.6 for cross-companion
consistency (VSCompanion's `dimfort.togglePanel', Nvim's
`:DimFortTogglePanel')."
  (interactive)
  (if (dimfort--panel-window)
      (dimfort--panel-close)
    (dimfort--panel-open)))

;; Per-section visibility toggles (0.2.6).  Each one flips its
;; `dimfort-show-*' boolean via `customize-set-variable' so a
;; `customize-save-customized' will persist the choice across
;; sessions.  Mirrors VSCompanion's `dimfort.toggleCursor/Scope/
;; Imports' and Nvim's `:DimFortToggleCursor/Scope/Imports'.
(defun dimfort--toggle-section (symbol label)
  "Flip the boolean SYMBOL and message a LABEL summary; repaint."
  (customize-set-variable symbol (not (symbol-value symbol)))
  (message "DimFort: %s section %s" label
           (if (symbol-value symbol) "shown" "hidden"))
  (dimfort--panel-refresh))

;;;###autoload
(defun dimfort-toggle-cursor ()
  "Show or hide the Cursor section.
Bundles Expression / Diagnostics / Interactions / Actions."
  (interactive)
  (dimfort--toggle-section 'dimfort-show-cursor "Cursor"))

;;;###autoload
(defun dimfort-toggle-scope ()
  "Show or hide the Scope section."
  (interactive)
  (dimfort--toggle-section 'dimfort-show-scope "Scope"))

;;;###autoload
(defun dimfort-toggle-imports ()
  "Show or hide the Imports section."
  (interactive)
  (dimfort--toggle-section 'dimfort-show-imports "Imports"))

;;;###autoload
(defun dimfort-cycle-sort-mode ()
  "Cycle `dimfort-panel-sort-mode' through line → alphabetic → status.
Shared by the panel's Scope and Imports sections so the two stay in
sync (matches the VSCompanion / Nvim companions). Repaints from the
cached payload — no LSP round-trip."
  (interactive)
  (let* ((vals '("line" "alphabetic" "status"))
         (pos (or (cl-position dimfort-panel-sort-mode vals :test #'equal) -1))
         (next (nth (mod (1+ pos) (length vals)) vals)))
    (setq dimfort-panel-sort-mode next)
    (message "DimFort: sort mode → %s" next)
    (when (get-buffer dimfort--panel-buffer)
      (dimfort--panel-repaint))))

;;;###autoload
(defun dimfort-cycle-unit-display ()
  "Cycle `dimfort-panel-unit-display-mode' through input → canonical → both.
Applies to both Scope and Imports. Repaints from the cached payload."
  (interactive)
  (let* ((vals '("input" "canonical" "both"))
         (pos (or (cl-position dimfort-panel-unit-display-mode vals :test #'equal) -1))
         (next (nth (mod (1+ pos) (length vals)) vals)))
    (setq dimfort-panel-unit-display-mode next)
    (message "DimFort: unit display → %s" next)
    (when (get-buffer dimfort--panel-buffer)
      (dimfort--panel-repaint))))

(defvar dimfort--coverage-report-source-buffer nil
  "Source Fortran buffer the *DimFort Coverage* report is rendering.
Tracked so the auto-refresh hook can re-render the report when the
source's file-coverage cache updates asynchronously.")

(defun dimfort--coverage-report-render (file-uri)
  "Rebuild the *DimFort Coverage* buffer contents from current state."
  (let* ((file (and file-uri (gethash file-uri dimfort--file-coverage-cache)))
         (ws dimfort--ws-snapshot)
         (stale dimfort--ws-stale)
         (buf (get-buffer "*DimFort Coverage*")))
    (when (buffer-live-p buf)
      (cl-labels
          ((cell (scope key)
             (if scope
                 (format "%5d" (or (plist-get scope key) 0))
               "  –  "))
           (pct (scope)
             (if scope
                 (format "%4d%%" (or (plist-get scope :coverage-pct) 0))
               "  –  ")))
        (with-current-buffer buf
          (let ((inhibit-read-only t)
                (saved-point (point)))
            (erase-buffer)
            (insert "DimFort coverage\n\n")
            (insert (format "                %-10s%s\n"
                            "File"
                            (if (and ws stale) "Project (stale)" "Project")))
            (insert (make-string 38 ?─) "\n")
            ;; Coverage line gets a 3-cell prefix to match the emoji-
            ;; bearing tier rows below: the bullet column is 2 display
            ;; cells (🟢 / 🟡 / 🔴 / 🔵) + 1 trailing space, so plain
            ;; spaces here need to total 3 cells for the labels to share
            ;; a baseline. Mirrors the VSCompanion fix (4242763).
            (insert (format "   Coverage     %-10s%s\n"
                            (pct file) (pct ws)))
            (insert (format "🟢 Verified     %-10s%s\n"
                            (cell file :ok) (cell ws :ok)))
            (insert (format "🟡 Unverified   %-10s%s\n"
                            (cell file :warn) (cell ws :warn)))
            (insert (format "🔴 Violation    %-10s%s\n"
                            (cell file :fire) (cell ws :fire)))
            (insert (format "🔵 Unparsed     %-10s%s\n"
                            (cell file :unparsed) (cell ws :unparsed)))
            (cond
             ((not ws)
              (insert "\nProject coverage not yet computed.\n")
              (insert "Run M-x dimfort-check-workspace to compute.\n"))
             (stale
              (insert "\nFiles changed since last refresh.\n")
              (insert "Run M-x dimfort-check-workspace to update.\n")))
            (insert "\nPress q to close.\n")
            (goto-char (min saved-point (point-max)))))))))

(defun dimfort--coverage-report-on-change ()
  "Hook called when stats change while the coverage report is open.
Re-renders the report if its source buffer is still alive."
  (when (and (get-buffer "*DimFort Coverage*")
             (buffer-live-p dimfort--coverage-report-source-buffer))
    (let ((uri (with-current-buffer dimfort--coverage-report-source-buffer
                 (and (memq major-mode dimfort-fortran-modes)
                      (dimfort--coverage-uri)))))
      (dimfort--coverage-report-render uri))))

;;;###autoload
(defun dimfort-coverage-report ()
  "Open a buffer with the File / Project tier breakdown.
Mirrors the VSCompanion status-bar tooltip table — Verified /
Unverified / Violation / Unparsed counts for both scopes plus the
coverage %.  Press `q' to close.

The report re-renders automatically whenever the cached stats update,
so the File column populates as soon as the LSP response lands —
no race, no manual re-invocation."
  (interactive)
  ;; Track the source buffer explicitly so the async re-render hook
  ;; can find it later (current-buffer changes when we pop to the
  ;; report buffer).
  (setq dimfort--coverage-report-source-buffer (current-buffer))
  ;; Kick off a fresh file-stats request. The response will fire
  ;; dimfort--panel-repaint, which re-renders this buffer via the
  ;; dimfort--coverage-report-on-change hook installed in
  ;; dimfort--panel-repaint. No race, no sit-for, no manual reload.
  (ignore-errors (dimfort--coverage-stats-refresh-active))
  (let ((buf (get-buffer-create "*DimFort Coverage*")))
    (with-current-buffer buf
      (special-mode)
      (local-set-key (kbd "q") #'quit-window))
    ;; Render once with whatever's currently cached. The async update
    ;; will re-render as soon as the LSP response lands.
    (dimfort--coverage-report-render (dimfort--coverage-active-uri))
    (pop-to-buffer buf
                   '((display-buffer-in-side-window
                      (side . bottom)
                      (window-height . 14))))))

;;;###autoload
(defun dimfort-scope-filter (query)
  "Filter the panel's Scope section to variables matching QUERY (name/unit).

Called interactively, prompts for the query; an empty string clears the
filter. Client-side — repaints from the cached payload, no LSP round-trip."
  (interactive (list (read-string "Filter Scope (name/unit, empty to clear): "
                                   dimfort--scope-filter)))
  (setq dimfort--scope-filter (or query ""))
  (when (dimfort--panel-window)
    (dimfort--panel-paint (dimfort--panel-render dimfort--panel-last-payload) nil)))

;;;###autoload
(defun dimfort-imports-filter (query)
  "Filter the panel's Imports section to symbols matching QUERY.

Matches against the imported name, its unit, and its source module. An
empty string clears the filter.  Its own filter, independent of the
Scope one (`dimfort-scope-filter')."
  (interactive (list (read-string "Filter Imports (name/unit/module, empty to clear): "
                                   dimfort--imports-filter)))
  (setq dimfort--imports-filter (or query ""))
  (when (dimfort--panel-window)
    (dimfort--panel-paint (dimfort--panel-render dimfort--panel-last-payload) nil)))

(defun dimfort--panel-maybe-autoopen ()
  "Open the panel on attach when `dimfort-panel-enabled' is non-nil."
  (when (and dimfort-panel-enabled
             (memq major-mode dimfort-fortran-modes)
             (not (dimfort--panel-window)))
    (dimfort--panel-open)))

(provide 'dimfort)

;;; dimfort.el ends here
