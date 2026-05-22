;;; dimfort.el --- Emacs companion for the DimFort Fortran unit checker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victor Arrial

;; Author: Victor Arrial
;; URL: https://github.com/ArrialVictor/DimFort-EmacsCompanion
;; Version: 0.1.1
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

(defcustom dimfort-code-lens-enabled nil
  "Whether the LSP server should advertise code lens."
  :type 'boolean)

(defcustom dimfort-trace-hover-enabled t
  "Whether hovers default to the full unit-algebra trace (Detailed).

When on, every hover surface is upgraded to the detailed
rule-chain tree; the per-surface levels below still apply when
this master switch is off."
  :type 'boolean)

(defcustom dimfort-hover-function-calls "short"
  "Hover detail level for function calls: \"short\" or \"detailed\"."
  :type '(choice (const "short") (const "detailed")))

(defcustom dimfort-hover-subroutine-calls "short"
  "Hover detail level for subroutine calls: \"short\" or \"detailed\"."
  :type '(choice (const "short") (const "detailed")))

(defcustom dimfort-hover-expressions "short"
  "Hover detail level for expressions: \"short\" or \"detailed\"."
  :type '(choice (const "short") (const "detailed")))

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
           (codeLensEnabled . ,(if dimfort-code-lens-enabled t :json-false))
           (traceHoverEnabled . ,(if dimfort-trace-hover-enabled t :json-false))
           (hoverFunctionCalls . ,dimfort-hover-function-calls)
           (hoverSubroutineCalls . ,dimfort-hover-subroutine-calls)
           (hoverExpressions . ,dimfort-hover-expressions)
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
      (save-excursion
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
              (goto-char (+ insert-start cursor-mark)))))))
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
         (name (read-string
                (format "Parameter name for %s (%s): " literal-text target-unit)
                nil nil default-name)))
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
    ;; Handle the `dimfort.insertSnippet' workspace command. eglot
    ;; calls `eglot-execute-command' on every server-initiated
    ;; workspace/executeCommand; intercept ours via :around advice.
    (advice-add 'eglot-execute-command :around #'dimfort--eglot-execute-advice)
    ;; eglot 1.17 (Emacs 30) ignores `workspace/inlayHint/refresh',
    ;; so after every fresh attach we schedule our own re-request
    ;; once the server's initial workspace check has had time to
    ;; finish.  Without this, the first inlay request races and
    ;; loses, and the buffer renders no hints until the user edits.
    (add-hook 'eglot-managed-mode-hook
              #'dimfort--schedule-inlay-refresh)))

(defun dimfort--eglot-execute-advice (orig server command arguments &rest rest)
  "Intercept the DimFort-specific workspace commands before eglot's generic path."
  (cond
   ((equal command "dimfort.insertSnippet")
    (apply #'dimfort--insert-snippet (append arguments nil)))
   ((equal command "dimfort.extractToParameter")
    (apply #'dimfort--extract-to-parameter (append arguments nil)))
   (t (apply orig server command arguments rest))))


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
(dimfort--define-toggle dimfort-toggle-code-lens
                        dimfort-code-lens-enabled
                        "code lens")
(dimfort--define-toggle dimfort-toggle-trace
                        dimfort-trace-hover-enabled
                        "full unit trace")

;; Cycle an enum-valued setting through VALUES and restart. Used for
;; the per-surface hover Short <-> Detailed and the cache off <->
;; read-write toggles.
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

(dimfort--define-cycle dimfort-cycle-hover-function-calls
                       dimfort-hover-function-calls
                       "hover (function calls)" '("short" "detailed"))
(dimfort--define-cycle dimfort-cycle-hover-subroutine-calls
                       dimfort-hover-subroutine-calls
                       "hover (subroutine calls)" '("short" "detailed"))
(dimfort--define-cycle dimfort-cycle-hover-expressions
                       dimfort-hover-expressions
                       "hover (expressions)" '("short" "detailed"))
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
      (format "  code lens         : %s\n" (flag dimfort-code-lens-enabled))
      (format "  full unit trace   : %s\n" (flag dimfort-trace-hover-enabled))
      (format "  hover (functions) : %s\n" dimfort-hover-function-calls)
      (format "  hover (subs)      : %s\n" dimfort-hover-subroutine-calls)
      (format "  hover (exprs)     : %s\n" dimfort-hover-expressions)
      (format "  cache             : %s\n" dimfort-cache-mode)
      (format "  cache dir         : %s\n"
              (if (string-empty-p dimfort-cache-dir) "(default)" dimfort-cache-dir))
      (format "  max workset size  : %d\n" dimfort-max-workset-size)
      (format "  external modules  : %s"
              (if dimfort-external-modules
                  (mapconcat #'identity dimfort-external-modules ", ")
                "(none)"))))))

(provide 'dimfort)

;;; dimfort.el ends here
