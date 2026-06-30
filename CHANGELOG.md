# Changelog

All notable changes to the DimFort Emacs companion are documented
here. Format inspired by [Keep a Changelog](https://keepachangelog.com/).

This package is a thin LSP client for [DimFort](https://github.com/ArrialVictor/DimFort);
behavioural changes mostly land in the DimFort server itself. Entries
below cover client-side changes only (eglot/lsp-mode wiring, commands,
defaults, packaging).

## [Unreleased]

### Added

- **Unexpected LSP-server-exit surfacing (eglot).** The companion now
  wraps the eglot server's underlying process sentinel via
  `eglot-managed-mode-hook`. If the server exits abnormally (`exited
  abnormally with code N`, `killed by signal 9`, etc.) the user sees
  a `message` naming the event, pointing at `*EGLOT events*` /
  `*Messages*` for details, with common causes listed (missing
  `[lsp]` extra, Python crash mid-handler). Clean exits and graceful
  user-initiated kills (SIGTERM / SIGINT) are skipped. Per-(name,
  event) deduped via `dimfort--warned-server-exits`. Closes the gap
  surfaced during [DimFort#112](https://github.com/ArrialVictor/DimFort/pull/112)'s
  review — server-side friendly error reached terminal users but
  not companion-using ones who only saw "DimFort LSP not attached."
  Wraps each server process once via a weak-key `eq` memo so
  per-buffer hook firings stay idempotent. (lsp-mode users go through
  a different LSP-error UX — lsp-mode has its own server-died
  indicators; not implemented since lsp-mode adoption is small.)

### Fixed

- **`workspace/executeCommand` error response now surfaces.** Both
  the eglot and lsp-mode workspace-check command paths previously
  `condition-case nil`-wrapped the `eglot-execute-command` /
  `lsp--send-execute-command` call and silently cleared the spinner
  on any wire-level error. The user clicked `M-x
  dimfort-check-workspace`, saw nothing happen, no signal anything
  was wrong. Both paths now `message` the actual error text on
  failure. The documented `started: false` server-refusal cases
  (already in progress / index not ready / no files) stay silent on
  the companion side — eglot routes the server's
  `window/showMessage` toast to `*Messages*`, so the user already
  sees the explanation; double-warning would be noise. Annotated
  with `audited(0.2.7)` to document the intentional silence.

### Added

- **Custom `project-find-functions` entry preferring `dimfort.toml`.**
  When opening a Fortran file, the companion now walks upward from
  the file looking for a `dimfort.toml` and returns a `transient`
  project rooted there. This matches the cross-companion unification
  work in 0.2.7 — `dimfort.toml` is DimFort's project marker and
  the three companions now agree on its priority. Falls through to
  project.el's existing chain (`project-try-vc` etc.) when no
  `dimfort.toml` is upstream, so projects without a `dimfort.toml`
  keep working exactly as before.

- **Root-source tag in the panel `Project:` line.** The footer now
  appends `(dimfort.toml)` when our project-finder anchored the
  workspace — a glance reveals which marker the LSP is using. No
  tag appears when project.el's default chain handled the
  resolution (vc-based detection, etc.) since the companion
  doesn't own that path. Matches the equivalent tags added to
  the Nvim and VSCompanion companions this cycle, with the
  Emacs-specific scoping note that we only report on
  `dimfort.toml`-anchored roots.

- **Nested-`dimfort.toml` warning.** When the upward walk
  encounters a second `dimfort.toml` above the chosen one, the
  companion emits a one-time `message' surfacing the drift
  (typically an unintended sub-project or configuration overlap).
  Per-root deduped — same root never warns twice in one session.
  Only fires for `dimfort.toml` specifically.

### Changed

- **`MANUAL_QA.md` reorganised around display surfaces.** The walk
  now covers only what an LSP client can't reach: face rendering,
  fringe glyphs, eldoc / panel ASCII layout, mode-line progress,
  echo-area messages, divider rendering, sort/display-mode visual
  changes, command-rename verification, code-action snippet
  placeholder behaviour. Server-side correctness (diagnostic codes,
  hover / panel / inlay / workspace / coverage / code-action /
  completion payloads) is now verified by the DimFort LSP integration
  test suite that landed this cycle, so the manual walk no longer
  re-checks them. Reorganised by display surface (Faces, Eldoc,
  Side panel, Mode-line, etc.) rather than by feature, with the
  fixtures kept up front and each step referencing them by name +
  line. Net effect: roughly half the line count of the previous
  walk, every step a pure display invariant. A closing pointer maps
  the dropped checks back to the specific LSP test file that
  covers them, so a regression triage finds the wire-test
  counterpart fast.

## [0.2.6] — 2026-06-13

### Highlight

Cross-companion parity + post-restart panel-population fix release.
Three threads:

1. **Sort + unit-display modes on the side panel** — feature parity
   with VSCompanion and Nvim. Scope and Imports sections now carry
   per-section sort mode (`line` / `alphabetic` / `status`) and
   per-section unit-display mode (`input` / `canonical` / `both`),
   cycled via new `M-x dimfort-cycle-…` commands.

2. **`M-x dimfort-coverage-report` and `M-x dimfort-open-config`** —
   matching the new commands in VSCompanion and Nvim. Same surface,
   same UX, same sub-pick behaviour for the missing-config case.

3. **Post-restart panel population.** Two layered fixes for an
   eglot-specific race that left the side panel showing empty
   sections after `M-x dimfort-cycle-*` commands, until the user
   moved the cursor several times: (a) wait for the eglot
   `initialize` handshake to complete before firing the post-
   restart refresh; (b) probe `textDocument/documentSymbol` after
   that, to ensure the server has processed the `textDocument/
   didOpen` for the source buffer before asking for panel content.
   Born from in-editor smoke testing during the 0.2.6 cycle; both
   PRs (#25 + #26 in this repo) target Emacs specifically — Nvim
   doesn't see the race because `vim.lsp.buf_request` queues
   requests until the server is ready.

### Recommended server version

Pair this companion with DimFort **0.2.6+**. The workspace-check
wire-protocol command renamed from `dimfort.checkWorkspace` (dot)
to `dimfort/checkWorkspace` (slash) server-side; this companion now
sends the slash form on both the eglot and lsp-mode paths. Earlier
servers (0.2.5 and below) accept both for one release as a soft-
migration window, but pairing with 0.2.6+ gets you the new
workspace-less / index-not-ready toasts and the `[N/5]`
workspace-check progress phase counter — neither of which is
client-side.

### Added

- **`M-x dimfort-open-config`** — opens the project `dimfort.toml`
  if present, the project units file if present, or pops a sub-pick
  for the missing-file case (Empty file / Reference template).
  Matches `DimFort: Open Config…` (VSCode) and `:DimFortOpenConfig`
  (Nvim) exactly.

- **`M-x dimfort-coverage-report`** — buffer with the per-tier
  coverage breakdown (Verified / Unverified / Violation / Unparsed,
  for both file and project scope). Same content as VSCompanion's
  status-bar tooltip and Nvim's floating window. Press `q` to
  close.

- **Sort + unit-display modes on the panel.** Both Scope and Imports
  sections now respond to `M-x dimfort-cycle-sort-mode` (line /
  alphabetic / status) and `M-x dimfort-cycle-unit-display` (input
  / canonical / both). Defaults: sort = `line`, unit-display =
  `canonical`. Mirrors VSCompanion's title-bar controls and Nvim's
  `:DimFort…` commands.

- **MANUAL_QA additions** — extra QA fixtures covering the new
  panel surfaces (sort modes, unit-display modes, coverage report)
  plus the cross-companion command audit set.

### Changed

- **Wire-protocol command** — `M-x dimfort-check-workspace` now
  sends `dimfort/checkWorkspace` (slash) instead of
  `dimfort.checkWorkspace` (dot) on both the eglot and lsp-mode
  paths. Cosmetic on the client. Requires DimFort 0.2.5+ to receive.

- **`dimfort-panel-open` / `dimfort-panel-close` / `dimfort-panel-
  activate` demoted to internal helpers** (`dimfort--panel-open` /
  `dimfort--panel-close` / `dimfort--panel-activate`). The
  user-facing entry point is `M-x dimfort-toggle-panel`, per the
  canonical commands table; the three helpers were exposed as
  public commands but never documented as such. The toggle still
  delegates to them; the demotion just removes the
  `;;;###autoload` markers so they don't pollute `M-x` completion
  for users. Any custom keybindings calling the old names continue
  to work (the functions themselves remain `interactive`); rebinding
  to the new `dimfort--…` names is recommended but not required.

### Fixed

- **Post-restart panel-population race (PR #25).** The pre-fix
  `dimfort--restart-have-server-p` predicate returned truthy as
  soon as `eglot-current-server` returned the server object —
  which happens at process spawn, before the LSP `initialize`
  handshake completes. The single post-restart refresh fired in
  that window, the request was silently swallowed by our
  `ignore-errors` wrapper, and the panel stayed at the dimmed
  pre-restart cache until the next cursor motion. Probe
  capabilities (`eglot-server-capable`) before firing the
  refresh — capabilities only appear after the initialize
  handshake completes. Fall back to internal
  `eglot--server-capable` on older eglot.

- **Post-restart panel-population race, layer 2 (PR #26).** Even
  after initialize completes, eglot still has to send
  `textDocument/didOpen` for every managed buffer before the
  server has the document content. A `dimfort/panelInfo` request
  in that gap returns a valid-but-empty payload — the panel
  renders every section but each shows `(none)`. Probe
  `textDocument/documentSymbol` as a gate (LSP guarantees
  in-order per-stream processing, so when documentSymbol
  returns, didOpen has landed); then fire the real refresh.

- **Coverage footer alignment in `M-x dimfort-coverage-report`.**
  The `Coverage` label sat one display cell to the left of the
  bulleted tier labels (🟢 Verified / 🟡 Unverified / 🔴
  Violation / 🔵 Unparsed) — fixed by reserving a 3-cell bullet
  column so all five labels share a baseline.

- **Footer flash on empty response.** Pre-fix, the file-coverage
  cache was cleared on empty `dimfort/coverageStats` responses,
  causing a brief "Footer: –" flash before the real numbers
  arrived. Now the cache is preserved across empty responses;
  only legitimate cache invalidations clear it.

- **Footer File-stats primed on attach, not on first coverage-
  mode toggle.** Pre-fix, the file-stats refresh was bound to
  `dimfort-coverage-mode != disabled` — users with the default
  `disabled` setting never saw their file-stats populate. Now
  primed at attach time independent of coverage-mode.

### Docs

- **Pre-release docs audit** caught: `.dimfort.toml` → `dimfort.toml`
  rename straggler in the bug-report template HTML comment.

## [0.2.5] — 2026-06-09

### Recommended server version

Pair this companion with DimFort **0.2.5+**. The workspace bar listens
for the new server-fired `dimfort/workspaceCheckCompleted` notification
(introduced by DimFort 0.2.5's async workspace check refactor) on both
the eglot and lsp-mode paths. Earlier servers don't emit it; the bar
would stay on the spinner state forever after a refresh trigger.

### Added

- **Workspace coverage bar** — side-panel footer now renders a
  unified bar showing per-file and whole-workspace coverage stats:
  `File: 78% (🟡 18 🔴 2)   Project: 12.9% (🟡 N 🔴 M)`. File-scope
  refreshes live on every edit via `dimfort/coverageStats`;
  workspace-scope is populated by `M-x dimfort-check-workspace`
  (async since DimFort 0.2.5 — the executeCommand returns an ack
  immediately and the payload arrives via the new
  `dimfort/workspaceCheckCompleted` notification). Three WS states:
  `Project: –` (dimmed) before the first refresh, a Braille spinner
  (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, 80 ms cadence) while the server-side daemon
  worker is running, and `Project: <pct>%` after. Numbers dim once any
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
