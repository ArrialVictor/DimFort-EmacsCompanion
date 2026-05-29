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
| `dimfort-inlay-hints-enabled`     | `nil`       | Server emits inlay hints (off — redundant beside the panel/hover). |
| `dimfort-completion-enabled`      | `t`         | Server provides unit-name completion. |
| `dimfort-code-actions-enabled`    | `t`         | Server advertises code actions. |
| `dimfort-goto-definition-enabled` | `t`         | Server answers textDocument/definition. |
| `dimfort-hover`                   | `"short"`   | Hover verbosity: `disabled` / `short` / `detailed`. Defaults to `short` — a compact unit surface beside the panel. |
| `dimfort-cache-mode`              | `"read-write"` | Content-hash check cache (`off` / `read-only` / `read-write`). |
| `dimfort-cache-dir`               | `""`        | Cache directory (empty = server default). |
| `dimfort-scale-mode`              | `"auto"`    | Scale checking (S001/S002): `auto` defers to `.dimfort.toml`, `on`/`off` override. Cycle with `dimfort-cycle-scale`. |
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
| `M-x dimfort-cycle-scale`        | Cycle scale checking (`auto` → `on` → `off`); `auto` defers to `.dimfort.toml`. |
| `M-x dimfort-panel-toggle`       | Toggle the cursor-following side panel. |
| `M-x dimfort-panel-open` / `-close` | Open / close the side panel.                 |
| `M-x dimfort-scope-filter`       | Filter the panel's Scope section by name/unit (empty clears). |
| `M-x dimfort-imports-filter`     | Filter the panel's Imports section by name/unit/module (empty clears). |

## Side panel

`M-x dimfort-panel-toggle` opens a persistent side window that follows
the cursor. At full feature parity with the VSCode companion, it shows
six stacked sections (the volatile middle three appear in the `both`
layout):

- **Expression** — the unit-algebra tree for the expression under the
  cursor: each node with its resolved unit, the rule that produced it,
  and a 🟢 / 🟡 / 🔴 marker. The same content as the detailed hover, but
  it stays visible while you edit — handy for debugging a mismatch or
  walking through code with someone.
- **Diagnostics** — DimFort diagnostics on the cursor line, with the
  🔴 / 🟡 / 🔵 severity-circle vocabulary (info-level diagnostics such as
  P001 unparsed regions read the same as the rest).
- **Interactions** — cross-site unit constraints for the symbol under
  the cursor (the `dimfort interactions` query): the X001 conflict, if
  any, then the Declaration / Write / Read / Undetermined groups,
  each site showing its location, unit, and source snippet.
- **Actions** — the code actions available at the cursor (Add `@unit{}`
  / extract literal to a PARAMETER); press `RET` on one to apply it.
- **Scope** — the declarations of every *enclosing* scope, stacked
  outermost-first and indented by nesting (a module's declarations,
  then a contained subroutine's locals). Each variable is marked 🟢
  (annotated), 🟡 (unannotated), or 🔴 (unparseable annotation), so
  annotation gaps stand out. `M-x dimfort-scope-filter` narrows the
  list to variables whose name or unit matches.
- **Imports** — variables and procedures a `use` clause brings into scope
  (usable here but declared elsewhere), grouped by source module under a
  `from <module>` header (functions read as `name(argunits)`, showing
  their argument + return units, e.g. `force(kg)`). Rows navigate cross-file to where the imported symbol — and
  its `@unit{}` — is declared. `M-x dimfort-imports-filter` narrows it.

Press `RET` (or `mouse-1`) on any declaration, diagnostic,
interaction-site, or import row to jump to it (cross-file for interaction
sites and imports);
the file-wide diagnostic counts pin the footer.

On by default (opens on attach); set `dimfort-panel-enabled` to `nil`
to keep it closed and open it on demand. Dock side and width are set
via `dimfort-panel-side` and `dimfort-panel-width`.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ArrialVictor/DimFort/main/docs/img/panel-emacs-hero_dark.png">
  <img width="640" src="https://raw.githubusercontent.com/ArrialVictor/DimFort/main/docs/img/panel-emacs-hero_light.png" alt="DimFort side panel in Emacs — the unit-algebra tree for q = 0.5 * rho * v * v with the stacked module/function scope below">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ArrialVictor/DimFort/main/docs/img/panel-emacs-mismatch_dark.png">
  <img width="640" src="https://raw.githubusercontent.com/ArrialVictor/DimFort/main/docs/img/panel-emacs-mismatch_light.png" alt="DimFort side panel in Emacs — a kg ≠ m homogeneity violation, the assignment root marked red">
</picture>

## What you get

Same surface as the VSCode companion:

- Diagnostics (H001–H004, U001/U002/U005–U007/U010, …) in the buffer
  via `flymake` (eglot) or `flycheck`/`lsp-ui` (lsp-mode).
- Hover docs for variable units.
- Inlay hints, go-to-definition, completion, code actions
  (toggleable).
- Workspace-wide cross-file checks driven from `use` clauses.

## Notes

- `dimfort.insertSnippet` (used by the "add `@unit{}`" code action)
  inserts the snippet literally; Emacs LSP clients don't expand
  `${1:placeholder}` tab-stops, so they're flattened to default text
  and the cursor lands at the `$0` position.

## License

MIT.
