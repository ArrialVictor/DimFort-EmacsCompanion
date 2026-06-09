# Changelog

All notable changes to the DimFort Emacs companion are documented
here. Format inspired by [Keep a Changelog](https://keepachangelog.com/).

This package is a thin LSP client for [DimFort](https://github.com/ArrialVictor/DimFort);
behavioural changes mostly land in the DimFort server itself. Entries
below cover client-side changes only (eglot/lsp-mode wiring, commands,
defaults, packaging).

## [Unreleased]

### Recommended server version

Pair this companion with DimFort **0.2.5+**. The workspace bar listens
for the new server-fired `dimfort/workspaceCheckCompleted` notification
(introduced by DimFort 0.2.5's async workspace check refactor) on both
the eglot and lsp-mode paths. Earlier servers don't emit it; the bar
would stay on the spinner state forever after a refresh trigger.

### Added

- **Workspace coverage bar** — side-panel footer now renders a
  unified bar showing per-file and whole-workspace coverage stats:
  `File: 78% (🟡 18 🔴 2)   WS: 12.9% (🟡 N 🔴 M)`. File-scope
  refreshes live on every edit via `dimfort/coverageStats`;
  workspace-scope is populated by `M-x dimfort-check-workspace`
  (async since DimFort 0.2.5 — the executeCommand returns an ack
  immediately and the payload arrives via the new
  `dimfort/workspaceCheckCompleted` notification). Three WS states:
  `WS: –` (dimmed) before the first refresh, a Braille spinner
  (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, 80 ms cadence) while the server-side daemon
  worker is running, and `WS: <pct>%` after. Numbers dim once any
  buffer edit fires after the last successful refresh so the user
  knows the snapshot may be stale. Requires DimFort 0.2.5+. New
  helpers `dimfort--handle-workspace-check-completed`,
  `dimfort--ws-start-spinner`, and `dimfort--panel-render-footer`
  alongside the existing panel renderer; mirrors the VSCompanion
  `CoverageStatsProvider` and the Nvim companion `stats.lua`
  module. Replaces the previous footer that surfaced only raw
  🔴 / 🟡 diagnostic counts for the active file.

- **Coverage visualisation** — per-line status decoration driven by
  the server's `dimfort/lineStatus` LSP method (requires DimFort
  0.2.4+). Custom variable `dimfort-coverage-mode` (`"disabled"` |
  `"gutter"` | `"background"`) controls the layer; default is
  `"disabled"` (opt-in). Command `M-x dimfort-cycle-coverage`
  cycles through the three modes. `gutter` and `background` are
  mutually-exclusive visual encodings of the same per-line tier
  (green / yellow / red / blue); pick the visual weight you prefer.
  Refresh is driven by `after-change-functions` with debounce plus
  `after-save-hook`; the per-buffer debounce
  (`dimfort-coverage-debounce`, default 0.5 s) is set slightly
  longer than the server's own `didChange` debounce so the
  coverage query lands after the server's re-check completes.
  Coverage settings are companion-only — flipping the mode does
  not restart the language server.

  Customisation: the four fringe-dot faces
  (`dimfort-coverage-green` / `-yellow` / `-red` / `-blue`) and the
  four background faces (`dimfort-coverage-bg-*`) are user-
  customisable via `M-x customize-face` or `set-face-attribute`.
  The background faces are **theme-aware**: each carries separate
  `(background dark)` / `(background light)` specs so the tint reads
  as a subtle wash on either kind of theme without per-user
  customisation. Both eglot and lsp-mode backends are supported.

## [0.2.3] — 2026-06-07

### Track DimFort 0.2.3.1's polymorphism feature + in-editor UX polish

This release tracks DimFort's polymorphism feature shipped over
0.2.3 + 0.2.3.1. Recommended pairing is **server 0.2.3.1** for the
full hover/panel rendering; the package is forward-compatible with
0.2.3 servers too.

Server-side (read transparently — no client config added):
parametric polymorphism (`'a`, `'b`, …) in `@unit{}` annotations,
four new diagnostic codes (H020 polymorphic-call-site unification
failure, H021 type-variable-in-forbidden-position, H022
cannot-bind-tyvar-to-affine-unit (e.g. passing a `degC` actual into
a `'a` slot — type variables range over the multiplicative algebra
only), H023
dishonest-polymorphic-body), the 40-item pre-release audit fix
series, and the 37 in-source docstring-drift fixes. The eight
0.2.3.1 follow-up fixes (panel/hover marker propagation, H020
collides-trailer rendering, message multi-line reformat, clean-call
no-trailer convention, polymorphic-function return resolution, and
the `'a = ?` unbound-return form) are similarly server-side — they
just need the client to render the new fields exposed below. The
diagnostics surface through `flymake` (eglot) / `lsp-ui-sideline`
(lsp-mode) like every other diagnostic.

Client-side (this package):

- **`(collides with …)` row tail** on H020 polymorphic-conflict rows.
  The server's `dimfort/panelInfo` now ships a `collides` field on
  `ExpressionNode`; the panel renders it as `(collides with <X>)`
  alongside the existing `(expected …)` and `(assumed: …)` row
  tails. Forward-compatible: 0.2.3 servers omit the field and the
  trailer doesn't render.
- **Dimmed trailing `?`** on the new `'a = ?` unbound-polymorphic-return
  form. The `dimfort--dim` face applied to bare-`?` / bare-`-` cells
  is now scoped to the trailing `?` only when the unit ends in
  `= ?`; the bound prefix stays full-weight. The suffix check is
  tight enough not to false-positive — concrete units never end in
  `= ?`.
- **Polymorphism QA annex** in MANUAL_QA.md (Cases A–G + interactive
  H021 / H022 probes) — pins every behaviour the 0.2.3.1 server-
  side fixes deliver.

### Recommended server version

`dimfort >= 0.2.3.1` for the full polish. Earlier 0.2.3 servers
work — the `collides` field stays absent and the panel renders the
binding form without the trailer, the rest is unchanged.

## [0.2.2] — 2026-06-03

### Passthrough: DimFort 0.2.2's configurable comment delimiters

This release tracks DimFort 0.2.2. The package itself is
unchanged — the new `[parser]` keys
(`unit_comment_delimiters` / `unit_assume_comment_delimiters` /
`unit_affine_comment_delimiters`) are read by the server from
`.dimfort.toml`, no client config is added.

The new U021 / U023 / U002-suggested-rewrite diagnostics surface
through `flymake` (eglot) / `lsp-ui-sideline` (lsp-mode); the
U002 "Replace with `<X>`" quick-fix surfaces via
`eglot-code-actions` (it's a direct `WorkspaceEdit`, no command
delegation) so it just works.

### Min server version

`dimfort >= 0.2.2` recommended. Earlier servers still run as a
fallback, but won't expose the new toml keys.

## [0.2.1] — 2026-05-30

### Polish: render `assumed` marker (🔵) + `(assumed: <reason>)` tail on the RHS row

Tracks the new server-side `ExpressionNode.marker = "assumed"` value
and `ExpressionNode.assumed: string | null` field. When the server
flags a row as accepted via `@unit_assume{<unit> : <reason>}`, the
panel paints 🔵 and appends `(assumed: <reason>)` to the row tail
(same column as `(expected …)`; both can coexist).

The overlay lives on the **RHS row** of the assignment — the
directive's syntactic subject — not on the assignment row itself.
The companion needs no code changes for this routing (the server
sets `marker`/`assumed` on the RHS child of the assignment
payload); this entry tracks the wire-format expectation.

🔵 is a per-row overlay, NOT a severity tier — it doesn't
propagate up. The assignment row stays `marker: "ok"` (🟢) when
the homogeneity check passes; H001 still fires (🔴) if the
declared LHS unit conflicts with the asserted RHS unit. See
DimFort design/markers.md §4.6.

### Polish: dim `?` and `-` glyphs across every panel section

Absence-of-information glyphs (`?` for unknown, `-` for
structural-no-unit) now render with the `shadow` face (via
`dimfort--dim`) in **every** panel section that shows units —
Scope, Imports, Expression tree, and Interactions. Three glyphs,
three meanings, consistent visual treatment everywhere.

### Change: scope / import unannotated vars render `?`, not `(none)`

Aligns with the server-side glyph unification (see DimFort
design/markers.md §4.5): `(none)` is now reserved for empty
(sub-)section headers only (`Scope: (none)`, `Imports: (none)`).
Individual unannotated variables in the Scope and Imports sections
read `?` — the same glyph used inside the Expression tree for
unknown units. Imported subroutines (no return by design) read `-`
instead of `?` to distinguish "no unit by structure" from "we
don't know yet". (The Imports row previously used `—`; that becomes
`-` for the same reason — a single glyph across companions and
surfaces.)

### Change: panel tree drops rule IDs; renders `(expected …)` on call-arg mismatches

Tracks the server's wire-format rename `ExpressionNode.ruleId` →
`ExpressionNode.expected`. The Expression section no longer trails
rule-ID tags like `(R4.2)` on every node — debug noise that wasn't
helpful for the target audience. In their place, when a call
argument's resolved unit dimensionally differs from the callee's
formal, the row now ends with `(expected <formal>)` so the reader
sees what the call-site demanded without reading the diagnostic
text. Mismatched argument rows paint 🟡 (the new 🟡-on-`expected`
override, server-side; see DimFort design/markers.md §4.4), so a
row with `(expected …)` will never read `marker: "ok"`.

### Polish: scope/imports `unitNormalized` column + uniform scale-mode display

The Scope-var and Imports rows now render the `unitNormalized` field
as a second cell next to the source unit when they differ (e.g.
`Pa  kg·m⁻¹·s⁻²`). Server-side gating means the multiplicative
factor appears only when scale mode is on (`hPa  100×kg·m⁻¹·s⁻²`
vs `hPa  kg·m⁻¹·s⁻²`) — the panel just renders whatever the server
emits, so the same rule lands across every surface.

### Polish: module procedures show up in the Scope panel

For module/program scopes, the panel now lists the module's defined
functions / subroutines as `name(args)` rows alongside variables,
mirroring how the Imports section formats imported procedures.
Zero renderer changes — the server emits these as pre-formatted
rows in `ScopeVar` shape.

### Change: Interactions label `"Undetermined read"` → `"Undetermined"`

The panel's Interactions section header for the `uses` kind now
reads `Undetermined` (was `Undetermined read`). Matches the rename
on the server side; the underlying `kind` value is unchanged.

### Add: link to the canonical `demos/tour.f90` in the README

The README's intro now points at `demos/tour.f90` in the DimFort
repo — a short, self-contained moist-thermodynamics file that
exercises six high-impact diagnostics on a single page. Going
forward, README screenshots will be taken from this file so they
stay reproducible.

## [0.2.0] — 2026-05-28

### Added

- **Scale-checking toggle** — a new `dimfort-scale-mode` option
  (`"auto"` / `"on"` / `"off"`, default `"auto"`) and a
  `dimfort-cycle-scale` command. `"auto"` defers to the project's
  `.dimfort.toml` `[scale] enabled`; `"on"`/`"off"` force the magnitude
  layer (S001/S002) for the session, overriding the toml. Shown in
  `dimfort-status`.
- **Side panel — full feature parity with the VSCode companion.** The
  panel previously showed only the Expression and Scope sections; it now
  carries the three middle sections too (shown in the `both` layout):
  - **Diagnostics** — the cursor line's DimFort diagnostics, with the
    🔴/🟡/🔵 severity-circle vocabulary (info-level diagnostics such as
    P001 unparsed regions read the same as the rest). Each row is
    severity-coloured with the theme-aware `error` / `warning` / `shadow`
    faces, mirroring the Nvim and VSCode panels.
  - **Interactions** — cross-site unit constraints for the symbol under
    the cursor (`dimfort/interactions`): the X001 conflict, if any, then
    the Declaration / Write / Read / Undetermined-read groups, each site
    showing its location, unit, and source snippet (the snippet dimmed
    with the `shadow` face). Empty-state placeholders (`(none)` /
    `(no … match)`) across all sections are likewise dimmed, matching the
    VSCode and Nvim panels.
  - **Actions** — code actions available at the cursor (Add `@unit{}` /
    extract literal to a PARAMETER), applied in place with `RET`. The
    `textDocument/codeAction` request carries the cursor line's
    diagnostics in its context so the H010 extract action is offered.
  - **Scope filter** — `M-x dimfort-scope-filter` narrows the Scope
    section to variables whose name or unit matches a query.
  - **Imports** — variables **and procedures** a `use` clause brings into
    scope (usable here but declared elsewhere), grouped by source module
    under a `from <module>` header (functions read as `name(argunits)`,
    showing their argument + return units, e.g. `force(kg)`). `RET` navigates cross-file to where the imported
    symbol — and its `@unit{}` — is declared. Has its own name/unit/
    module filter, `dimfort-imports-filter`. Driven by the server's
    `panelInfo.imports`.
  - **Row navigation** — `RET` (or `mouse-1`) on a declaration,
    diagnostic, interaction-site, or import row jumps to it (cross-file
    for sites and imports); a file-wide diagnostic-count footer pins the
    bottom.

### Changed

- **Hover settings collapsed into one `dimfort-hover`** option
  (`disabled` / `short` / `detailed`), replacing `dimfort-trace-hover-enabled`
  and the three per-surface `dimfort-hover-*` levels. `dimfort-cycle-hover`
  replaces the old trace toggle and dial cyclers.
- **Default UX stance unified** across the VS / Nvim / Emacs companions:
  `dimfort-hover` defaults to **`short`** and the side panel stays **on** — both
  cursor-following unit surfaces. The panel is always detailed regardless of
  this setting.

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
