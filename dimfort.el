;;; dimfort.el --- Emacs companion for the DimFort Fortran unit checker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victor Arrial

;; Author: Victor Arrial
;; URL: https://github.com/ArrialVictor/DimFort-EmacsCompanion
;; Version: 0.2.0
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

\"auto\" (the default) defers to the project's `.dimfort.toml'
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
    ;; .dimfort.toml [scale] enabled wins; "on"/"off" send an explicit
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
;; Scale checking is tri-state: "auto" defers to the project .dimfort.toml,
;; "on"/"off" override it for the session.
(dimfort--define-cycle dimfort-cycle-scale
                       dimfort-scale-mode
                       "scale checking" '("auto" "on" "off"))

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
(defconst dimfort--panel-markers
  '(("ok" . "🟢") ("assumed" . "🔵") ("warn" . "🟡") ("error" . "🔴")))
(defconst dimfort--panel-interaction-groups
  '(("declares" . "Declaration")
    ("contributes" . "Write")
    ("requires" . "Read")
    ("uses" . "Undetermined read"))
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
           (marker (dimfort--field node "marker"))
           ;; Row tail: `(expected …)' on mismatch, `(assumed: <reason>)'
           ;; on @unit_assume rows. Both may apply; concatenate.
           (extra (concat
                    (if expected (format " (expected %s)" expected) "")
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
             (unit-styled (and unit
                               (if (member unit '("?" "-"))
                                   (dimfort--dim unit)
                                 unit)))
             (mid (cond
                   (unit (concat " : " unit-styled
                                 (make-string (- unit-w (string-width unit)) ?\s)))
                   ((> unit-w 0) (make-string (+ 3 unit-w) ?\s))
                   (t ""))))
        (push (dimfort--cell (concat tree tree-pad mid "  "
                                     (plist-get e :mark) (plist-get e :extra)))
              rows)))
    (nreverse rows)))

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
      (let ((name-w 4) (unit-w 4))
        (dolist (v vs)
          (setq name-w (max name-w (string-width (or (dimfort--field v "name") ""))))
          (setq unit-w (max unit-w (string-width (or (dimfort--field v "unit") "?")))))
        (dolist (v vs)
          (let* ((unit (or (dimfort--field v "unit") "?"))
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
                              unit-padded)))
            (push (dimfort--cell
                   (concat pad "  " (dimfort--pad (number-to-string line) 4)
                           "  " (dimfort--pad (or (dimfort--field v "name") "") name-w)
                           "  " unit-cell tail)
                   (list :line line))
                  rows)))))
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
          (let ((items (nreverse (gethash m groups))) (name-w 4) (unit-w 4))
            (dolist (im items)
              (setq name-w (max name-w (string-width (dimfort--import-label im))))
              (setq unit-w (max unit-w
                                (string-width (or (dimfort--field im "unit") "?")))))
            (dolist (im items)
              ;; A subroutine (callable, no unit, not a missing annotation)
              ;; reads as "-" (structural-no-unit) rather than "?" — it
              ;; has no return value to annotate. Unannotated declarations
              ;; get "?" (unknown).
              (let* ((unit (or (dimfort--field im "unit")
                               (if (and (eq (dimfort--field im "callable") t)
                                        (equal (dimfort--field im "kind") "annotated"))
                                   "-" "?")))
                     (tail (if (equal (dimfort--field im "kind") "unannotated")
                               " 🟡" " 🟢"))
                     ;; Dim absence-of-information glyphs so real units pop.
                     (unit-padded (dimfort--pad unit unit-w))
                     (unit-cell (if (member unit '("?" "-"))
                                    (dimfort--dim unit-padded)
                                  unit-padded))
                     (target (list :file (dimfort--field im "file")
                                   :line (dimfort--field im "line")
                                   :column (dimfort--field im "column"))))
                (push (dimfort--cell
                       (concat "      "
                               (dimfort--pad (dimfort--import-label im) name-w)
                               "  " unit-cell tail)
                       target)
                      rows)))))
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
      (when (memq dimfort-panel-layout '(both expression))
        (let ((expr (and payload (dimfort--field payload "expression"))))
          (sec "Expression"
               (if expr (dimfort--panel-render-expr expr)
                 (list (dimfort--cell (dimfort--dim "  (none)")))))))
      (when (eq dimfort-panel-layout 'both)
        (sec "Diagnostics" (dimfort--panel-render-diagnostics payload))
        (sec "Interactions"
             (dimfort--panel-render-interactions dimfort--panel-last-interactions))
        (sec "Actions"
             (dimfort--panel-render-actions dimfort--panel-last-actions))
        (add (dimfort--cell dimfort--panel-divider) (dimfort--cell "")))
      (when (memq dimfort-panel-layout '(both routine))
        (sec "Scope" (dimfort--panel-render-scope-section payload))
        (sec "Imports"
             (dimfort--panel-render-imports
              (and payload (dimfort--field payload "imports")))))
      ;; Footer: whole-file diagnostic counts.
      (when (and (eq dimfort-panel-layout 'both) payload
                 (dimfort--field payload "fileDiagnosticCounts"))
        (let ((counts (dimfort--field payload "fileDiagnosticCounts")))
          (add (dimfort--cell dimfort--panel-divider)
               (dimfort--cell
                (format "File: 🔴 %s   🟡 %s"
                        (or (dimfort--field counts "error") 0)
                        (or (dimfort--field counts "warning") 0)))))))
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
    (define-key map (kbd "RET") #'dimfort-panel-activate)
    (define-key map [mouse-1] #'dimfort-panel-activate)
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

(defun dimfort-panel-activate ()
  "Act on the panel row at point: jump to a location, or apply an action."
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
    (dimfort-panel-open)))

(provide 'dimfort)

;;; dimfort.el ends here
