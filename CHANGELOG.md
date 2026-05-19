# Changelog

All notable changes to the DimFort Emacs companion are documented
here. Format inspired by [Keep a Changelog](https://keepachangelog.com/).

This package is a thin LSP client for [DimFort](https://github.com/ArrialVictor/DimFort);
behavioural changes mostly land in the DimFort server itself. Entries
below cover client-side changes only (eglot/lsp-mode wiring, commands,
defaults, packaging).

## [Unreleased]

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
