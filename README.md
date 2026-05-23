# DimFort — Emacs companion

![preview](social_preview.png)

Emacs companion for [DimFort](https://github.com/ArrialVictor/DimFort) —
the dimensional-homogeneity checker for Fortran. Thin LSP client +
commands; the heavy lifting is done by the `dimfort lsp` server.

Works with both **eglot** (built-in since Emacs 29) and **lsp-mode**
(MELPA). Whichever you've loaded is the one DimFort registers with;
loading both is harmless.

## Requirements

- Emacs ≥ 29.1.
- DimFort installed and `dimfort lsp` reachable from `exec-path` (or
  set `dimfort-executable` to an absolute path). Install instructions:
  https://github.com/ArrialVictor/DimFort.

## Installation

Until this is on MELPA, clone and add to your `load-path`:

```bash
git clone https://github.com/ArrialVictor/DimFort-EmacsCompanion.git \
  ~/.emacs.d/site-lisp/DimFort-EmacsCompanion
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/DimFort-EmacsCompanion")
(require 'dimfort)
(dimfort-setup)
```

With `use-package`:

```elisp
(use-package dimfort
  :load-path "~/.emacs.d/site-lisp/DimFort-EmacsCompanion"
  :hook ((f90-mode . dimfort-setup)
         (fortran-mode . dimfort-setup)))
```

After this, just open a Fortran file and start your LSP client of
choice — `M-x eglot` or `M-x lsp`. DimFort attaches automatically.

## Configuration

All variables live under `M-x customize-group RET dimfort`:

| Variable                          | Default     | Effect |
|-----------------------------------|-------------|--------|
| `dimfort-executable`              | `"dimfort"` | Path to the `dimfort` binary. |
| `dimfort-inlay-hints-enabled`     | `nil`       | Server emits inlay hints (off — detailed hover is the primary surface). |
| `dimfort-completion-enabled`      | `t`         | Server provides unit-name completion. |
| `dimfort-code-actions-enabled`    | `t`         | Server advertises code actions. |
| `dimfort-goto-definition-enabled` | `t`         | Server answers textDocument/definition. |
| `dimfort-hover`                   | `"disabled"`| Hover verbosity: `disabled` / `short` / `detailed`. Off by default — the side panel is the unit surface. |
| `dimfort-cache-mode`              | `"read-write"` | Content-hash check cache (`off` / `read-only` / `read-write`). |
| `dimfort-cache-dir`               | `""`        | Cache directory (empty = server default). |
| `dimfort-max-workset-size`        | `40`        | Cap on workset size. |
| `dimfort-external-modules`        | `nil`       | Modules treated as out-of-workset (silences U007). |
| `dimfort-fortran-modes`           | `(f90-mode fortran-mode)` | Modes DimFort registers for. |
| `dimfort-panel-enabled`           | `t`         | Open the side panel automatically on attach (on — set `nil` to open on demand). |
| `dimfort-panel-side`              | `right`     | Panel dock side (`right` / `left` / `bottom`). |
| `dimfort-panel-width`             | `0.35`      | Panel width fraction (left/right docking). |
| `dimfort-panel-debounce`          | `0.2`       | Idle seconds before the panel cursor-follow refresh. |
| `dimfort-panel-layout`            | `both`      | Panel sections (`both` / `expression` / `routine`). |

## Commands

| Command                          | Effect                                          |
|----------------------------------|-------------------------------------------------|
| `M-x dimfort-check-workspace`    | Run the workspace-wide unit check.              |
| `M-x dimfort-restart`            | Restart the language server.                    |
| `M-x dimfort-status`             | Print current feature toggles in the echo area. |
| `M-x dimfort-toggle-inlay-hints` | Toggle inlay hints; restarts the server.        |
| `M-x dimfort-toggle-completion`  | Toggle unit-name completion; restarts.          |
| `M-x dimfort-toggle-code-actions`| Toggle code actions; restarts.                  |
| `M-x dimfort-toggle-goto-definition` | Toggle go-to-definition; restarts.          |
| `M-x dimfort-cycle-hover`        | Cycle hover verbosity (disabled → short → detailed); restarts. |
| `M-x dimfort-toggle-cache`       | Toggle the content-hash cache (off ↔ read-write); restarts. |
| `M-x dimfort-panel-toggle`       | Toggle the cursor-following side panel (Expression + Scope). |
| `M-x dimfort-panel-open` / `-close` | Open / close the side panel.                 |

## What you get

Same surface as the VSCode companion:

- Diagnostics (H001–H004, U001/U002/U005–U007/U010, …) in the buffer
  via `flymake` (eglot) or `flycheck`/`lsp-ui` (lsp-mode).
- Hover docs for variable units.
- Inlay hints, code lens, go-to-definition, completion, code actions
  (toggleable).
- Workspace-wide cross-file checks driven from `use` clauses.

## Notes

- `dimfort.insertSnippet` (used by the "add `@unit{}`" code action)
  inserts the snippet literally; Emacs LSP clients don't expand
  `${1:placeholder}` tab-stops, so they're flattened to default text
  and the cursor lands at the `$0` position.

## License

MIT.
