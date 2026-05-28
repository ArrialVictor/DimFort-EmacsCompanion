# Contributing to the DimFort Emacs companion

Thanks for considering a contribution. This package is a **thin LSP client**
for [DimFort](https://github.com/ArrialVictor/DimFort) — behavioural changes
(diagnostics, annotation parsing, unit algebra, …) usually belong in the server
repo. The contribution surface here is the editor-side experience: the side
panel, hover surfaces, user commands, defaults, packaging.

## Reporting issues

Open an issue using the **Bug report** template. The version block (DimFort
server + Emacs + companion + OS) and the LSP traces — `M-x eglot-events-buffer`
plus the `*EGLOT … stderr*` buffer — are the most useful things to include.
Most bugs are routed to the server repo on the basis of that trace.

## Development setup

```bash
git clone https://github.com/ArrialVictor/DimFort-EmacsCompanion.git
```

Point your Emacs at the checkout:

```elisp
;; in init.el
(add-to-list 'load-path "/absolute/path/to/DimFort-EmacsCompanion")
(require 'dimfort)
(setq dimfort-executable "/absolute/path/to/DimFort/.venv/bin/dimfort")  ; local server
```

That picks up `dimfort.el` immediately — no build step needed. Re-evaluate the
buffer (`M-x eval-buffer`) after edits, or use `M-x load-file dimfort.el`.

## Byte-compile check

The fastest sanity check that the file still compiles cleanly:

```bash
emacs --batch -f batch-byte-compile dimfort.el
```

Should exit 0 with no warnings. There are no unit tests yet; the source of
truth for behavioural QA is `MANUAL_QA.md`.

## Style + scope

- Keep the package thin. Use **eglot** for the LSP plumbing; the server's
  responses are authoritative.
- Match the surface of the VSCode and Nvim companions where it makes sense
  — the three are intentionally feature-parallel. Cross-companion design notes
  live in the DimFort server repo's `docs/design/panel-info.md`.
- Panel rendering uses `string-width` for column alignment (Emacs's built-in
  display-width-aware function — unlike Lua's byte-length `#`, this Just Works
  for multi-byte unit chars like `·` and `⁻¹`).
- Internal names use the double-dash convention (`dimfort--foo` for private,
  `dimfort-foo` for public commands/customisable variables).

## Releases

Tag-based: bump the `;; Version:` header in `dimfort.el`, update CHANGELOG,
`git tag v0.X.Y && git push --tags`, then create a GitHub release. No MELPA
publish at present.
