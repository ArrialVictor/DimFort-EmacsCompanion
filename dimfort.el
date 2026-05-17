;;; dimfort.el --- Emacs companion for the DimFort Fortran unit checker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victor Arrial

;; Author: Victor Arrial
;; URL: https://github.com/ArrialVictor/DimFort-EmacsCompanion
;; Version: 0.1.0
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

(defgroup dimfort nil
  "Emacs companion for the DimFort Fortran unit checker."
  :group 'languages
  :prefix "dimfort-")

(defcustom dimfort-executable "dimfort"
  "Path to the dimfort binary.  Override if it's not on `exec-path'."
  :type 'string)

(defcustom dimfort-inlay-hints-enabled t
  "Whether the LSP server should emit inlay hints."
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

(defcustom dimfort-code-lens-enabled t
  "Whether the LSP server should advertise code lens."
  :type 'boolean)

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
  "Return the initializationOptions table sent to the LSP server."
  `((inlayHintsEnabled . ,(if dimfort-inlay-hints-enabled t :json-false))
    (completionEnabled . ,(if dimfort-completion-enabled t :json-false))
    (codeActionsEnabled . ,(if dimfort-code-actions-enabled t :json-false))
    (gotoDefinitionEnabled . ,(if dimfort-goto-definition-enabled t :json-false))
    (codeLensEnabled . ,(if dimfort-code-lens-enabled t :json-false))
    (maxWorksetSize . ,dimfort-max-workset-size)
    (externalModules . ,(or dimfort-external-modules []))))

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


;;; eglot integration

(defvar eglot-server-programs)
(declare-function eglot-execute-command "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-reconnect "eglot")

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
    (advice-add 'eglot-execute-command :around #'dimfort--eglot-execute-advice)))

(defun dimfort--eglot-execute-advice (orig server command arguments &rest rest)
  "Intercept the DimFort-specific workspace command before eglot's generic path."
  (if (equal command "dimfort.insertSnippet")
      (apply #'dimfort--insert-snippet (append arguments nil))
    (apply orig server command arguments rest)))


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
falls back to stopping and restarting the eglot connection."
  (interactive)
  (cond
   ((and (featurep 'lsp-mode) (fboundp 'lsp-workspace-restart)
         (fboundp 'lsp-find-workspace))
    (call-interactively 'lsp-workspace-restart))
   ((and (featurep 'eglot) (fboundp 'eglot-reconnect))
    (let ((server (and (fboundp 'eglot-current-server) (eglot-current-server))))
      (if server
          (eglot-reconnect server)
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

(dimfort--define-toggle dimfort-toggle-inlay-hints
                        dimfort-inlay-hints-enabled
                        "inlay hints")
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
      (format "  max workset size  : %d\n" dimfort-max-workset-size)
      (format "  external modules  : %s"
              (if dimfort-external-modules
                  (mapconcat #'identity dimfort-external-modules ", ")
                "(none)"))))))

(provide 'dimfort)

;;; dimfort.el ends here
