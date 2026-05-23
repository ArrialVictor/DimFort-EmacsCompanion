# Changelog

All notable changes to the DimFort Emacs companion are documented
here. Format inspired by [Keep a Changelog](https://keepachangelog.com/).

This package is a thin LSP client for [DimFort](https://github.com/ArrialVictor/DimFort);
behavioural changes mostly land in the DimFort server itself. Entries
below cover client-side changes only (eglot/lsp-mode wiring, commands,
defaults, packaging).

## [Unreleased]

### Changed

- **Hover settings collapsed into one `dimfort-hover`** option
  (`disabled` / `short` / `detailed`), replacing `dimfort-trace-hover-enabled`
  and the three per-surface `dimfort-hover-*` levels. `dimfort-cycle-hover`
  replaces the old trace toggle and dial cyclers. Defaults to `disabled`:
  the side panel (on by default) is the unit surface, so hovers are off
  until you opt in. The panel is always detailed regardless of this setting.

## [0.1.2] — 2026-05-22

### Added

- **Side panel** — a cursor-following side window (`dimfort-panel-toggle`)
  fed by the `dimfort/panelInfo` LSP request, with two stacked sections:
  - **Expression** — the unit-algebra tree for the expression under the
    cursor, units and 🟢/🟡/🔴 markers aligned in columns.
  - **Scope** — declarations of every enclosing scope (subroutine /
    function / module / program), stacked outermost-first and indented
    by nesting, each variable marked 🟢 (annotated) / 🟡 (unannotated) /
    🔴 (annotation present but unparseable).
  - Options: `dimfort-panel-enabled` (default `t` — opens on attach; set
    `nil` to open on demand), `dimfort-panel-side`, `dimfort-panel-width`,
    `dimfort-panel-height`, `dimfort-panel-debounce`, `dimfort-panel-layout`.
  - Commands: `dimfort-panel-toggle` / `-open` / `-close`. Works under
    both eglot (`jsonrpc-async-request`) and lsp-mode (`lsp-request-async`).

### Changed

- **Code lens removed** — the feature carried no real value in any
  editor; the `dimfort-code-lens-enabled` option and `dimfort-toggle-code-lens`
  command are gone.

### Fixed

- **`add @unit{}` cursor placement** — point now lands between the braces
  (`@unit{|}`). A `save-excursion` around the insertion was restoring the
  prior point and undoing the snippet's `$0` placement.
- **Code actions on Emacs 30+** — `add @unit{}` and extract-to-PARAMETER
  were forwarded to the server as `workspace/executeCommand` and rejected
  (`Command 'dimfort.insertSnippet' is not defined`). Emacs 30 dispatches
  code actions through `eglot-execute`, not the obsolete
  `eglot-execute-command` we advised; now intercepted on both paths.
- **Side panel** survives `delete-other-windows` / `C-x 1` / the
  ESC-ESC-ESC quit (marked `no-delete-other-windows`).
- **Panel refresh** no longer errors when the server is mid-restart
  (a debounce timer firing against a finished jsonrpc connection).

## [0.1.1] — 2026-05-22

Feature-parity catch-up with the VSCode and Neovim companions. All
new options forward through `initializationOptions`, so the server
sees an identical surface across the three clients.

### Added

- **Content-hash cache** — `dimfort-cache-mode` (default `read-write`;
  also `off` / `read-only`) and `dimfort-cache-dir`. Toggle off ↔
  read-write with `dimfort-toggle-cache`.
- **Per-surface hover detail + trace** — `dimfort-trace-hover-enabled`
  (default on; master switch to Detailed) plus
  `dimfort-hover-function-calls` / `-subroutine-calls` / `-expressions`
  (`short` / `detailed`). Commands: `dimfort-toggle-trace` and the
  `dimfort-cycle-hover-*` cyclers.
- **Extract-literal-to-PARAMETER** — handles `dimfort.extractToParameter`
  behind the H010 quick-fix: prompts for a name, validates it as a
  Fortran identifier, and applies the two-edit refactor.

### Changed

- Defaults aligned with the other companions: **inlay hints off** and
  **code lens off** by default (detailed hover is the primary surface).
- `dimfort-status` now reports trace, per-surface hover, and cache state.

## [0.1.0] — 2026-05-19

First public release. The `dimfort.el` header has carried
`Version: 0.1.0` since initial commit; this release tags it.

Install via straight.el / use-package or clone-and-`require`.
Requires Emacs ≥ 29.1 and DimFort itself on PATH
(`pipx install 'dimfort[lsp]'`). Works with both eglot (built-in
since Emacs 29) and lsp-mode (MELPA).

```elisp
(use-package dimfort
  :straight (:host github :repo "ArrialVictor/DimFort-EmacsCompanion")
  :hook (f90-mode . dimfort-ensure))
```

### 2026-05-18

- **Workarounds for eglot 1.17 quirks**:
  - `eglot-reconnect` reuses stale `initargs` captured at first
    connect, so a per-feature toggle wasn't reaching the server.
    Replaced with `eglot-shutdown` + `eglot-ensure` so the new init
    options always reach a fresh connect.
  - eglot 1.17 doesn't implement a `workspace/inlayHint/refresh`
    handler. After a toggle / check, we schedule a deferred
    `eglot--update-hints-1` call so inlays redraw without requiring
    a buffer edit.
  - Off-toggles now clear inlay overlays immediately rather than
    waiting for the next buffer change.

### 2026-05-17

- **`M-x dimfort-status`**: at-a-glance feature-flag panel showing
  which features are enabled, server status, eglot/lsp-mode in use,
  and active workspace.
- **Branding**: ship `icon.png`, `icon_alt.png`, and `social_preview.png`.

### Earlier

Initial release. eglot + lsp-mode dual registration — whichever
client is loaded first is the one DimFort registers with. Spawns
`dimfort lsp` over stdio. Diagnostics, hover, inlay hints, completion,
and code actions all flow through the chosen client's standard
handlers. Provides toggle commands and a Check-Workspace wrapper.
