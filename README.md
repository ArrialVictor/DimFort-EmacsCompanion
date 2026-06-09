# DimFort — Emacs companion

![preview](social_preview.png)

[![CI](https://github.com/ArrialVictor/DimFort-EmacsCompanion/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/ArrialVictor/DimFort-EmacsCompanion/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/ArrialVictor/DimFort-EmacsCompanion/blob/main/LICENSE)

Emacs companion for [DimFort](https://github.com/ArrialVictor/DimFort) —
the dimensional-homogeneity checker for Fortran. Thin LSP client +
commands; the heavy lifting is done by the `dimfort lsp` server.

Want a hands-on look first? See the [DimFort tour](https://github.com/ArrialVictor/DimFort/blob/main/demos/README.md) —
a short, self-contained Fortran file that exercises the most common
diagnostics, with a line-by-line walkthrough.

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
| `M-x dimfort-check-workspace`    | Run the workspace-wide unit check; refreshes the panel footer's `Project:` segment. |
| `M-x dimfort-restart`            | Restart the language server.                    |
| `M-x dimfort-status`             | Print current feature toggles in the echo area. |
| `M-x dimfort-toggle-inlay-hints` | Toggle inlay hints; restarts the server.        |
| `M-x dimfort-toggle-completion`  | Toggle unit-name completion; restarts.          |
| `M-x dimfort-toggle-code-actions`| Toggle code actions; restarts.                  |
| `M-x dimfort-toggle-goto-definition` | Toggle go-to-definition; restarts.          |
| `M-x dimfort-cycle-hover`        | Cycle hover verbosity (disabled → short → detailed); restarts. |
| `M-x dimfort-toggle-cache`       | Toggle the content-hash cache (off ↔ read-write); restarts. |
| `M-x dimfort-cycle-scale`        | Cycle scale checking (`auto` → `on` → `off`); `auto` defers to `.dimfort.toml`. |
| `M-x dimfort-cycle-coverage`     | Cycle coverage visualisation (`disabled` → `gutter` → `background`); companion-only, no LSP restart. |
| `M-x dimfort-panel-toggle`       | Toggle the cursor-following side panel. |
| `M-x dimfort-panel-open` / `-close` | Open / close the side panel.                 |
| `M-x dimfort-scope-filter`       | Filter the panel's Scope section by name/unit (empty clears). |
| `M-x dimfort-imports-filter`     | Filter the panel's Imports section by name/unit/module (empty clears). |

## Side panel

A cursor-following side window rendering the six DimFort sections —
Expression, Diagnostics, Interactions, Actions, Scope, Imports.
The full description of what each section shows is the canonical
[side-panel reference](https://github.com/ArrialVictor/DimFort/blob/main/docs/editor-integration/side-panel.md);
the controls below are the Emacs-specific bits.

**Toggle**: open by default on attach. `M-x dimfort-panel-toggle`
opens or closes the persistent side window.

**Settings**:

- `dimfort-panel-enabled` — set to `nil` to keep the panel closed
  on attach.
- `dimfort-panel-side` / `dimfort-panel-width` — dock side and
  width.

**Filters**:

- `M-x dimfort-scope-filter` — narrow the Scope section to
  variables whose name or unit matches.
- `M-x dimfort-imports-filter` — same for Imports.

**Navigation**: press `RET` (or `mouse-1`) on any declaration,
diagnostic, interaction-site, or import row to jump to it
(cross-file for interaction sites and imports).

**Coverage bar**: a footer below the sections shows the active
file's coverage percentage and tier counts on the left, and the
whole-workspace aggregate on the right —
`File: 78% (🟡 18 🔴 2)   Project: 12.9% (🟡 N 🔴 M)`. File-scope
updates live on every edit; workspace-scope is populated when you
run `M-x dimfort-check-workspace`. Pre-refresh the bar shows
`Project: –`; during a refresh it shows a Braille spinner; once any
buffer edits fire the Project numbers dim to signal they may no longer
reflect current state. Requires DimFort 0.2.5+.

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
- **Coverage visualisation** (requires DimFort 0.2.4+) — per-line
  status in one of two mutually-exclusive visual encodings:
  - **Gutter** — coloured fringe dot per line, in four tiers (green /
    yellow / red / blue).
  - **Background** — line tint behind the text in the same four tiers.
  Off by default; toggle with `M-x dimfort-cycle-coverage`. Customise
  the colours via the faces `dimfort-coverage-green` /
  `dimfort-coverage-yellow` / `dimfort-coverage-red` /
  `dimfort-coverage-blue` (fringe dots) and
  `dimfort-coverage-bg-*` (line tint).

## Notes

- `dimfort.insertSnippet` (used by the "add `@unit{}`" code action)
  inserts the snippet literally; Emacs LSP clients don't expand
  `${1:placeholder}` tab-stops, so they're flattened to default text
  and the cursor lands at the `$0` position.

## License

MIT.
