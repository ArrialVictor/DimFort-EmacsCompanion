;;; dimfort.el --- Emacs companion for the DimFort Fortran unit checker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victor Arrial

;; Author: Victor Arrial
;; URL: https://github.com/ArrialVictor/DimFort-EmacsCompanion
;; Version: 0.1.2
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

(defun dimfort--eglot-setup ()
  "Register DimFort with eglot."
  (when (require 'eglot nil t)
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
              #'dimfort--panel-maybe-autoopen)))

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
    ;; Make sure f90/fortran modes are mapped to a known language id.
    (dolist (mode dimfort-fortran-modes)
      (add-to-list 'lsp-language-id-configuration `(,mode . "fortran")))
    ;; Open the side panel on attach when the user opted in.
    (add-hook 'lsp-managed-mode-hook #'dimfort--panel-maybe-autoopen)
    (lsp-register-client
     (make-lsp-client
      :new-connection (lsp-stdio-connection #'dimfort--command)
      :activation-fn (lsp-activate-on "fortran")
      :server-id 'dimfort
      :initialization-options #'dimfort--init-options
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
  (cond
   ((and (featurep 'lsp-mode) (fboundp 'lsp-workspace-restart)
         (fboundp 'lsp-find-workspace))
    (call-interactively 'lsp-workspace-restart))
   ((featurep 'eglot)
    (let ((server (and (fboundp 'eglot-current-server) (eglot-current-server))))
      (if server
          (progn
            (ignore-errors
              (eglot-shutdown server nil nil 'preserve-buffers))
            (eglot-ensure)
            (dimfort--schedule-inlay-refresh))
        (message "DimFort: no active eglot server in this buffer."))))
   (t (message "DimFort: neither eglot nor lsp-mode is active."))))

;;;###autoload
(defun dimfort-check-workspace ()
  "Run the workspace-wide unit check via workspace/executeCommand."
  (interactive)
  (cond
   ((and (featurep 'eglot) (fboundp 'eglot-current-server))
    (let ((server (eglot-current-server)))
      (if server
          (eglot-execute-command server "dimfort.checkWorkspace" [])
        (message "DimFort: no active eglot server."))))
   ((and (featurep 'lsp-mode) (fboundp 'lsp--send-execute-command))
    (lsp--send-execute-command "dimfort.checkWorkspace" []))
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
;; Binary cache toggle flips off <-> read-write; the middle read-only
;; mode is reachable via `M-x customize-variable RET dimfort-cache-mode'.
(dimfort--define-cycle dimfort-toggle-cache
                       dimfort-cache-mode
                       "cache" '("off" "read-write"))

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
      (format "  cache dir         : %s\n"
              (if (string-empty-p dimfort-cache-dir) "(default)" dimfort-cache-dir))
      (format "  max workset size  : %d\n" dimfort-max-workset-size)
      (format "  external modules  : %s"
              (if dimfort-external-modules
                  (mapconcat #'identity dimfort-external-modules ", ")
                "(none)"))))))

;;; Side panel

;; A cursor-following side window with two stacked sections:
;;   1. Expression — the unit-algebra tree under the cursor.
;;   2. Scope — declarations of every enclosing scope, stacked
;;      outermost-first, each variable marked 🟢 / 🟡 / 🔴.
;; Driven by the custom `dimfort/panelInfo' LSP request (see
;; DimFort/docs/design/panel-info.md). Closed by default; open it with
;; `dimfort-panel-toggle'.

(declare-function jsonrpc-async-request "jsonrpc")
(declare-function jsonrpc-running-p "jsonrpc")
(declare-function lsp-request-async "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")

(defcustom dimfort-panel-enabled t
  "Whether to open the side panel automatically when the server attaches.

On by default — set to nil to keep it closed and open it on demand
with `dimfort-panel-toggle'."
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

(defcustom dimfort-panel-layout 'both
  "Which panel sections to show."
  :type '(choice (const both) (const expression) (const routine)))

(defconst dimfort--panel-buffer "*dimfort-panel*")
(defconst dimfort--panel-divider (make-string 60 ?─))
(defconst dimfort--panel-markers '(("ok" . "🟢") ("warn" . "🟡") ("error" . "🔴")))
(defvar dimfort--panel-timer nil)
(defvar dimfort--panel-last-payload nil)
(defvar dimfort--panel-source-buffer nil)
(defvar dimfort--panel-req-counter 0)

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

(defun dimfort--panel-collect-expr (node prefix is-last is-root)
  "Return an ordered list of entry plists for expression NODE and descendants.
PREFIX is the tree-drawing prefix; IS-LAST / IS-ROOT shape the connector."
  (when node
    (let* ((connector (cond (is-root "") (is-last "└── ") (t "├── ")))
           (next-prefix (cond (is-root prefix)
                              (is-last (concat prefix "    "))
                              (t (concat prefix "│   "))))
           (rule-id (dimfort--field node "ruleId"))
           (marker (dimfort--field node "marker"))
           (entry (list :tree (concat prefix connector
                                      (or (dimfort--field node "label") "?"))
                        :unit (dimfort--field node "unit")
                        :mark (or (cdr (assoc marker dimfort--panel-markers)) " ")
                        :rule (if rule-id (format " (%s)" rule-id) "")))
           (children (dimfort--seq (dimfort--field node "children")))
           (n (length children))
           (result (list entry)))
      (cl-loop for c in children for i from 1 do
               (setq result (append result
                                    (dimfort--panel-collect-expr
                                     c next-prefix (= i n) nil))))
      result)))

(defun dimfort--panel-render-expr (node)
  "Return a list of aligned rows for expression NODE."
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
             (mid (cond
                   (unit (concat " : " unit
                                 (make-string (- unit-w (string-width unit)) ?\s)))
                   ((> unit-w 0) (make-string (+ 3 unit-w) ?\s))
                   (t ""))))
        (setq rows (append rows
                           (list (concat tree tree-pad mid "  "
                                         (plist-get e :mark) (plist-get e :rule)))))))
    rows))

(defun dimfort--panel-render-scope (scope vars depth)
  "Return rows for SCOPE and its VARS, indented by nesting DEPTH."
  (let* ((pad (make-string (* 2 (or depth 0)) ?\s))
         (rows '())
         (vs (dimfort--seq vars)))
    (setq rows
          (list (if scope
                    (concat pad (format "%s: %s"
                                        (dimfort--titlecase (dimfort--field scope "kind"))
                                        (or (dimfort--field scope "name") "")))
                  (concat pad "Scope: (file level)"))
                ""))
    (if (null vs)
        (append rows (list (concat pad "  (no declarations)")))
      (let ((name-w 4) (unit-w 4))
        (dolist (v vs)
          (setq name-w (max name-w (string-width (or (dimfort--field v "name") ""))))
          (setq unit-w (max unit-w (string-width (or (dimfort--field v "unit") "(none)")))))
        (dolist (v vs)
          (let* ((unit (or (dimfort--field v "unit") "(none)"))
                 (kind (dimfort--field v "kind"))
                 (tail (cond ((equal kind "unannotated") " 🟡")
                             ((equal kind "error") " 🔴")
                             (t " 🟢"))))
            (setq rows (append rows
                               (list (concat pad "  "
                                             (dimfort--pad
                                              (number-to-string (or (dimfort--field v "line") 0)) 4)
                                             "  " (dimfort--pad (or (dimfort--field v "name") "") name-w)
                                             "  " (dimfort--pad unit unit-w) tail))))))
        rows))))

(defun dimfort--panel-render (payload)
  "Return the full list of panel rows for PAYLOAD."
  (let ((rows '()))
    (cl-flet ((add (&rest xs) (setq rows (append rows xs))))
      (when (memq dimfort-panel-layout '(both expression))
        (add "Expression" "")
        (let ((expr (and payload (dimfort--field payload "expression"))))
          (if expr
              (setq rows (append rows (dimfort--panel-render-expr expr)))
            (add "  (no expression at cursor)")))
        (add ""))
      (when (eq dimfort-panel-layout 'both)
        (add dimfort--panel-divider ""))
      (when (memq dimfort-panel-layout '(both routine))
        (let ((scopes (dimfort--seq (and payload (dimfort--field payload "scopes")))))
          (cond
           ((and payload scopes)
            (cl-loop for sc in scopes for i from 0 do
                     (when (> i 0) (add ""))
                     (setq rows (append rows
                                        (dimfort--panel-render-scope
                                         sc (dimfort--field sc "vars") i)))))
           (payload
            (setq rows (append rows
                               (dimfort--panel-render-scope
                                (or (dimfort--field payload "scope")
                                    (dimfort--field payload "routine"))
                                (or (dimfort--field payload "scopeVars")
                                    (dimfort--field payload "routineVars"))
                                0))))
           (t (add "Scope: (none)"))))))
    rows))

(defun dimfort--panel-paint (rows stale)
  "Write ROWS into the panel buffer; dim them when STALE."
  (let ((buf (get-buffer dimfort--panel-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (mapconcat #'identity rows "\n"))
          (when stale
            (add-text-properties (point-min) (point-max) '(face shadow))))))))

;; -- window lifecycle + LSP request --

(define-derived-mode dimfort-panel-mode special-mode "DimFort-Panel"
  "Major mode for the DimFort side panel."
  (setq truncate-lines t)
  (setq-local cursor-type nil))

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

(defun dimfort--panel-request (buf params callback)
  "Send `dimfort/panelInfo' with PARAMS for BUF, calling CALLBACK on the result.

Guards against a server that is absent or mid-restart: a debounce timer
can fire while `dimfort-restart' has shut the old process down, and
issuing a request against a finished jsonrpc connection would otherwise
raise \"Process EGLOT ... not running\"."
  (with-current-buffer buf
    (let ((server (and (featurep 'eglot) (fboundp 'eglot-current-server)
                       (eglot-current-server))))
      (cond
       ((and server (fboundp 'jsonrpc-async-request)
             (or (not (fboundp 'jsonrpc-running-p))
                 (jsonrpc-running-p server)))
        (condition-case nil
            (jsonrpc-async-request
             server :dimfort/panelInfo params
             :success-fn callback
             :error-fn (lambda (_e)
                         (dimfort--panel-paint '("(DimFort panel error)") nil))
             :timeout 2)
          (error (dimfort--panel-paint '("(DimFort server restarting...)") nil))))
       ((and (featurep 'lsp-mode) (fboundp 'lsp-request-async)
             (fboundp 'lsp-workspaces) (lsp-workspaces))
        (condition-case nil
            (lsp-request-async "dimfort/panelInfo" params callback
                               :error-handler #'ignore)
          (error (dimfort--panel-paint '("(DimFort server restarting...)") nil))))
       (t (dimfort--panel-paint '("(DimFort LSP not attached)") nil))))))

(defun dimfort--panel-refresh ()
  "Re-request panel info for the current source buffer and repaint."
  (setq dimfort--panel-timer nil)
  (when (dimfort--panel-window)
    (let ((buf dimfort--panel-source-buffer))
      (if (and buf (buffer-live-p buf))
          (let ((params (dimfort--panel-position-params buf))
                (req (cl-incf dimfort--panel-req-counter)))
            (dimfort--panel-paint (dimfort--panel-render dimfort--panel-last-payload) t)
            (dimfort--panel-request
             buf params
             (lambda (result)
               (when (= req dimfort--panel-req-counter)
                 (setq dimfort--panel-last-payload result)
                 (dimfort--panel-paint (dimfort--panel-render result) nil)))))
        (dimfort--panel-paint '("(no Fortran buffer)") nil)))))

(defun dimfort--panel-maybe-schedule ()
  "On `post-command-hook': debounce a refresh when in a managed Fortran buffer."
  (when (and (dimfort--panel-window)
             (memq major-mode dimfort-fortran-modes)
             (buffer-file-name))
    (setq dimfort--panel-source-buffer (current-buffer))
    (when (timerp dimfort--panel-timer) (cancel-timer dimfort--panel-timer))
    (setq dimfort--panel-timer
          (run-with-timer dimfort-panel-debounce nil #'dimfort--panel-refresh))))

;;;###autoload
(defun dimfort-panel-open ()
  "Open the DimFort side panel and start following the cursor."
  (interactive)
  (dimfort--panel-get-buffer)
  (display-buffer dimfort--panel-buffer (dimfort--panel-display-action))
  (add-hook 'post-command-hook #'dimfort--panel-maybe-schedule)
  (when (memq major-mode dimfort-fortran-modes)
    (setq dimfort--panel-source-buffer (current-buffer)))
  (dimfort--panel-refresh))

;;;###autoload
(defun dimfort-panel-close ()
  "Close the DimFort side panel and stop following the cursor."
  (interactive)
  (remove-hook 'post-command-hook #'dimfort--panel-maybe-schedule)
  (when (timerp dimfort--panel-timer)
    (cancel-timer dimfort--panel-timer)
    (setq dimfort--panel-timer nil))
  (let ((win (dimfort--panel-window)))
    (when win (delete-window win))))

;;;###autoload
(defun dimfort-panel-toggle ()
  "Toggle the DimFort side panel."
  (interactive)
  (if (dimfort--panel-window)
      (dimfort-panel-close)
    (dimfort-panel-open)))

(defun dimfort--panel-maybe-autoopen ()
  "Open the panel on attach when `dimfort-panel-enabled' is non-nil."
  (when (and dimfort-panel-enabled
             (memq major-mode dimfort-fortran-modes)
             (not (dimfort--panel-window)))
    (dimfort-panel-open)))

(provide 'dimfort)

;;; dimfort.el ends here
