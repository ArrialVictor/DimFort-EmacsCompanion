# Manual QA — DimFort Emacs companion (display walk)

A short visual smoke walk run **before tagging a release**. It covers
only what an LSP client test can't reach: **how Emacs renders** the
server's payloads. Server-side correctness (diagnostic codes, hover /
panel / inlay / workspace / coverage / code-action / completion
payloads) is verified by the LSP integration suite at
`DimFort/tests/lsp_integration/` — this walk does **not** re-check
those.

Each step lists the **exact** visible result; anything that differs is
a regression to file. The same fixtures are reused across surfaces, so
save all six before starting.

## Fixtures

Save these into a fresh directory. The walks below reference them by
name + line number.

### `qa.f90` — main scene

```fortran
module qa_mod
  real, parameter :: c_sound = 340.0   !< @unit{m/s}
  real :: ref_pressure                 !< @unit{Pa}
contains
  function dynamic_pressure(v) result(q)
    real, intent(in) :: v    !< @unit{m/s}
    real             :: q    !< @unit{Pa}
    real             :: rho  !< @unit{kg/m^3}
    rho = 1.225
    q = 0.5 * rho * v * v
  end function dynamic_pressure

  subroutine checks()
    real :: t          !< @unit{s}
    real :: d          !< @unit{m}
    real :: bogus      !< @unit{kg}
    real :: combo      !< @unit{m^2/s^2}
    real :: ln_p       !< @unit{LOG(Pa)}
    real :: rt_e2      !< @unit{m/s}
    real :: abs_t      !< @unit{s}
    real :: recovered  !< @unit{Pa^2}
    real :: rho_brandes !< @unit{kg/m^3}
    real :: t_celsius                  ! no annotation -> U005
    d         = c_sound * t            ! OK
    bogus     = c_sound * t            ! H001
    t_celsius = t - 273.15             ! H010
    combo     = c_sound**2 + d * d / (t * t) - c_sound * c_sound
    ln_p      = log(ref_pressure)
    rt_e2     = sqrt(c_sound * c_sound)
    abs_t     = abs(t)
    recovered   = exp(log(ref_pressure) + log(ref_pressure))
    rho_brandes = 1.e3 * 0.178 * (d * 2.0 * 1000.0)**(-0.922)   !< @unit_assume{kg/m^3 : empirical-fit Brandes2007}
    ref_pressure = dynamic_pressure(0.5 * c_sound)
    call scale_pressure(2.0 * ref_pressure)
  end subroutine checks

  subroutine scale_pressure(p)
    real, intent(in) :: p   !< @unit{Pa}
    ref_pressure = p
  end subroutine scale_pressure
end module qa_mod
```

### `scale_qa.f90` — scale-mode display

```fortran
module scale_qa
  real, parameter :: PA_PER_HPA = 100.   !< @unit{Pa/hPa}
  real :: play   !< @unit{Pa}
  real :: phpa   !< @unit{hPa}
  real :: t_k    !< @unit{K}
  real :: t_c    !< @unit{degC}
contains
  subroutine s()
    phpa = play
    phpa = play / PA_PER_HPA
    t_k  = t_c
  end subroutine s
end module scale_qa
```

### `unparsed_qa.f90` — P001 squiggle face

```fortran
subroutine unparsed_qa(press, vel)
  implicit none
  real, intent(in)  :: press   !< @unit{Pa}
  real, intent(out) :: vel     !< @unit{m/s}
  vel = press
  vel = * / +
  vel = 0.0
  vel = vel * 2.0
end subroutine unparsed_qa
```

### `imports_qa.f90` — imports panel + cross-file navigation

```fortran
module phys_base
  real :: g0   !< @unit{m/s^2}
end module phys_base

module phys_constants
  use phys_base
  real :: play     !< @unit{Pa}
  real :: grav     !< @unit{m/s^2}
  real :: density
contains
  function gravity_at(h) result(g)
    real, intent(in) :: h   !< @unit{m}
    real             :: g   !< @unit{m/s^2}
    g = grav
  end function gravity_at
  subroutine set_play(p)
    real, intent(in) :: p   !< @unit{Pa}
    play = p
  end subroutine set_play
end module phys_constants

module solver
  use phys_constants, only: play, gravity_at, set_play, density
  real :: local_p   !< @unit{Pa}
contains
  subroutine step()
    local_p = play
    call set_play(local_p)
  end subroutine step
end module solver
```

### `delim_qa.f90` + companion `dimfort.toml` — delimiter face rendering

```fortran
subroutine delim_demo
  implicit none
  real :: ws   ! @unit{m/s}
  real :: pa   ! atmospheric pressure [Pa] at the surface
  ! mass loading [kg]
  real :: kg
  real :: a, b, c   ! [m]
  real :: g   !< wind speed [m/s] @unit{kg}
  real :: t   !< @unit_assume{K: legacy fit}
  ws = 1.0   !< @unit{m/s}
  real :: diff   !< @unit{m2/s}
end subroutine
```

```toml
[parser.unit_comments]
unit = [
  { open = "@unit{", close = "}" },
  { open = "[",      close = "]" },
]
```

### `poly_qa.f90` — polymorphic `'a` face

```fortran
module poly_qa
contains
  subroutine avg_two(x, y, mean)
    real, intent(in)  :: x     !< @unit{'a}
    real, intent(in)  :: y     !< @unit{'a}
    real, intent(out) :: mean  !< @unit{'a}
    real :: half  !< @unit{1}
    half = 0.5
    mean = half * (x + y)
  end subroutine avg_two

  subroutine caller_clean(a_in, b_in, out_mean)
    real, intent(in)  :: a_in      !< @unit{m}
    real, intent(in)  :: b_in      !< @unit{m}
    real, intent(out) :: out_mean  !< @unit{m}
    call avg_two(a_in, b_in, out_mean)
  end subroutine caller_clean
end module poly_qa
```

## Setup

Open `qa.f90` and start the server: `M-x eglot`. Give the first
workspace check a moment to finish, then walk the surfaces below.

---

## Surface 1 — Faces & fringes (flymake rendering)

In Emacs flymake, the three severities have distinct visual styles.
Confirm each one paints as expected on the qa fixtures:

- [ ] **Error** — on `qa.f90:25` (`bogus = c_sound * t`): the whole
      assignment text in **bold red**, **red `!!`** in the left fringe.
- [ ] **Warning** — on `qa.f90:23` (`real :: t_celsius`): the name
      `t_celsius` in **bold orange**, **single orange `!`** in the
      fringe.
- [ ] **Info (P001)** — on `unparsed_qa.f90:6` (`vel = * / +`): a
      **faint blue squiggle** under the line, **no fringe marker**
      (distinct from real errors above the line).
- [ ] **Info (U020)** — on `qa.f90:35` (the `@unit_assume` line):
      surfaces only as the panel's 🔵 row, no special text styling
      and no fringe marker (informational acknowledgement, not a
      problem).
- [ ] **P001 squiggle localised** — the blue underline on
      `unparsed_qa.f90` covers exactly lines 6 and 7 (the bad line and
      the swallowed `vel = 0.0`). Line 8 (`vel = vel * 2.0`) is
      **not** blue.

## Surface 2 — Eldoc / hover display

Hover defaults to **`short`**. Eldoc shows in the echo area;
`M-x eldoc-doc-buffer` opens the full tree in a separate window.

- [ ] **Echo-area short hover** — point on `c_sound` (`qa.f90:2`): the
      echo area shows the single row `c_sound : m·s⁻¹` (the unit is
      rendered with the **middle dot** `·` and **superscript minus**
      `⁻¹`, not ASCII `m/s`).
- [ ] **Tree in eldoc-doc-buffer** — point on the product
      `c_sound * t` (`qa.f90:24`), open `M-x eldoc-doc-buffer`. The
      tree renders with **box-drawing connectors** (`├──`, `└──`),
      **column-aligned** unit and marker columns, and **emoji glyphs**
      (🟢 / 🟡 / 🔴 / 🔵) in the rightmost column. One canonical layout
      to eyeball-check:

      ```
      🟢 DimFort
      c_sound * t  :  m       🟢
      ├── c_sound  :  m·s⁻¹   🟢
      └── t        :  s       🟢
      ```

      Subsequent steps assume the same alignment pattern.
- [ ] **Cycle hover mode** — `M-x dimfort-cycle-hover` cycles
      `disabled → short → detailed`; each tick echoes
      `DimFort: hover → <mode>` and **restarts the server**
      (visible in `M-x eglot-events-buffer`). Hover content changes
      shape on the next invocation; disabled silences hover.
- [ ] **Pure-signature hover** — in `detailed`, point on the
      function-def header `dynamic_pressure` (`qa.f90:5`). Eldoc
      collapses to a single signature line, no per-arg row table.
- [ ] **`(expected …)` trailer face** — in `detailed`, point on the
      `=` of `qa.f90:25` (`bogus = c_sound * t`). The RHS row's
      trailer `(expected kg)` renders distinctly (italic / dim) from
      the row's primary text; the row's marker is 🟡 not 🟢.
- [ ] **`@unit_assume` 🔵 overlay** — in `detailed`, point on
      `qa.f90:35` (`rho_brandes`). The 🔵 glyph sits on the **RHS row
      only**, not the assignment header. Trailer reads
      `(assumed: empirical-fit Brandes2007)` and renders in the same
      dim/italic style as `(expected …)`.

## Surface 3 — Side panel rendering

Open with `M-x dimfort-toggle-panel` if not already visible (it opens
automatically on attach by default). The panel buffer is `*dimfort*`,
window placed on the right.

### Layout

- [ ] **Sections divider** — a row of `─` characters spans the panel
      width between Cursor / Scope, Scope / Imports, and Imports /
      footer. Visible dividers always sit between two visible
      neighbours.
- [ ] **Column alignment** — in the Expression tree (panel for any
      qa.f90 line), the unit column and marker column are aligned
      across rows regardless of identifier length.
- [ ] **Footer always present** — `M-x dimfort-toggle-cursor`,
      `dimfort-toggle-scope`, `dimfort-toggle-imports` all three off:
      the panel still shows the `File: …   Project: …` footer row.
- [ ] **Dividers adapt** — toggle Cursor off; the divider that sat
      between Cursor and Scope disappears (no stranded separator).
      Same on toggling Scope.

### Behavior

- [ ] **Cursor-follow debounce** — move point rapidly between
      `qa.f90:10` (function body) and `qa.f90:25` (subroutine body).
      The panel dims briefly during refresh (~0.2 s debounce), then
      re-renders with the appropriate scope.
- [ ] **Footer tracks source buffer, not current buffer** — open
      `qa.f90`, let the panel populate. `C-x b` to `*dimfort*` panel
      buffer itself: footer's `File:` cell **continues** to show
      qa.f90's stats (does not flicker to `–`). Same when current
      buffer is `*DimFort Coverage*`.
- [ ] **Prime stats on attach** — kill all buffers, revisit `qa.f90`
      from disk. Within ~1.5 s of LSP attach, the footer's `File:`
      cell populates without any manual edit.

### Workspace check display

- [ ] **`Project: –` before first check** — footer's Project segment
      reads `Project: –` dimmed.
- [ ] **Braille spinner** — run `M-x dimfort-check-workspace`. The
      Project segment becomes a spinner cycling through
      `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` for the duration of the check.
- [ ] **Settles on completion** — when
      `dimfort/workspaceCheckCompleted` arrives, the segment settles
      to `Project: <pct>% (🟡 N 🔴 M)`.
- [ ] **Stale dim** — after a successful check, edit any Fortran
      buffer. The Project segment dims. The File segment continues to
      update live on each edit.
- [ ] **Restart resets** — `M-x dimfort-restart` reverts the footer
      to `File: –   Project: –` dimmed. Next workspace check
      re-populates.

## Surface 4 — Mode-line progress

Best verified on a real-world ~2400-file Fortran codebase (the small
qa.f90 sample completes too fast to read every phase).

- [ ] **All five phases observed** — run `M-x dimfort-check-workspace`
      on the large workspace. The mode-line progress region cycles
      through:

      ```
      [1/5] loading…
      [2/5] indexing modules…
      [3/5] checking…
      [4/5] published N/N
      [5/5] projecting coverage…
      ```

- [ ] **`[5/5]` persistence** — the `[5/5] projecting coverage…`
      string stays in the mode-line for the ~5 s post-publish
      projection window. Clears only when
      `dimfort/workspaceCheckCompleted` arrives and the panel
      footer's Project column populates.

## Surface 5 — Echo area + status command

- [ ] **`M-x dimfort-status`** prints **exactly** these 12 lines:

      ```
      DimFort status
        executable        : dimfort
        inlay hints       : off
        completion        : on
        code actions      : on
        go-to-definition  : on
        hover             : short
        cache             : read-write
        scale checking    : auto
        cache dir         : (default)
        max workset size  : 40
        external modules  : (none)
      ```

- [ ] **Cycle commands echo new mode** — each of the following
      `M-x dimfort-cycle-*` commands reports the new value in the
      echo area on every tick:
      - `dimfort-cycle-hover` → `DimFort: hover → {disabled,short,detailed}`
      - `dimfort-cycle-scale` → `DimFort: scale checking → {on,off,auto}`
      - `dimfort-cycle-cache` → `DimFort: cache → {off,read-only,read-write}`
      - `dimfort-cycle-sort-mode` → `DimFort: sort mode → {line,alphabetic,status}`
      - `dimfort-cycle-unit-display` → `DimFort: unit display → {input,canonical,both}`
      - `dimfort-cycle-coverage` → `DimFort: coverage {gutter,background,disabled}`

- [ ] **Duplicate workspace trigger** — invoke
      `M-x dimfort-check-workspace` twice in quick succession. The
      second prints `DimFort: workspace check already in progress`
      (no second worker spawns).
- [ ] **Restart echo** — `M-x dimfort-restart` echoes a reset
      confirmation; footer reverts to dim (Surface 3 cross-check).

## Surface 6 — Inlay hints display

- [ ] **Toggle visibility** — `M-x dimfort-toggle-inlay-hints` →
      `[m·s⁻¹]`-style ghost text appears after variable use sites
      (qa.f90 makes this easy to scan). Toggle again → ghost text
      disappears.
- [ ] **Polymorphic vars full-weight** — open `poly_qa.f90`, toggle
      on, point in `avg_two`'s body. Ghost text on `x`, `y`, `mean`
      reads `['a]` at the same visual weight as a concrete
      `[m]`-style ghost (no dim face — polymorphism is a real
      annotation, not unknown).
- [ ] **Concrete vars** — in `caller_clean`, the ghost text on
      `a_in`, `b_in` reads `[m]`. Same visual weight as the
      polymorphic case.

## Surface 7 — Code actions UI

`M-x eglot-code-actions` with point on the relevant fixture line.

- [ ] **Add `@unit{}`** — point on `t_celsius` (`qa.f90:23`). Menu
      surfaces **"add `@unit{}`"**. Applying inserts `!< @unit{}` and
      **leaves point between the braces** (the `$0` snippet placeholder
      target works under Emacs's snippet apply path).
- [ ] **Extract literal** — point on `273.15` (`qa.f90:26`). Menu
      surfaces **"extract literal to PARAMETER"**. Applying prompts
      in the minibuffer for a name, then inserts a typed
      `real, parameter` declaration and replaces the literal with the
      new name.
- [ ] **U002 preferred fix** — point on `@unit{m2/s}`
      (`delim_qa.f90:18` or qa.f90 with a temporary edit). Menu
      surfaces **"DimFort: Replace with 'm^2/s'"** as the **preferred**
      action (annotated as such in the menu). Applying edits
      `m2/s` → `m^2/s` and clears the diagnostic.

## Surface 8 — Navigation & completion

- [ ] **`M-.` lands at decl** — `M-.` (`xref-find-definitions`) on a
      `c_sound` use → point lands on `qa.f90:2` (the declaration
      line).
- [ ] **Cross-file `RET`** — open `imports_qa.f90`, panel visible,
      point in `step`. In the Imports section, `RET` on `play`
      navigates to its declaration (same file). Drop the `, only: …`
      filter on `solver`'s `use phys_constants` to expose the
      transitive `g0` row; `RET` on it **jumps cross-file** to
      `phys_base`'s declaration line. Same-buffer or cross-buffer
      depending on the row.
- [ ] **Completion in `@unit{`** — type a new `!< @unit{` and invoke
      completion (`C-M-i`); unit names are offered in the candidates
      popup.
- [ ] **Terminal `C-M-i` quirk** — if your terminal sends a literal
      `9;6u` instead of `C-M-i` (CSI u keyboard protocol that terminal
      Emacs doesn't decode), use **`ESC TAB`** instead (`ESC` is
      Meta, `TAB` is `C-i`). GUI Emacs avoids the whole issue.

## Surface 9 — Filter commands

- [ ] **Scope filter** — `M-x dimfort-scope-filter RET Pa RET`
      narrows the Scope section to vars whose name or unit matches
      `Pa`. Panel header reads `Filter: "Pa"`. Scopes with no
      surviving variables are hidden. Empty input clears.
- [ ] **Imports filter** — `M-x dimfort-imports-filter RET gravity
      RET` narrows the Imports section to `gravity_at(m)`. **Does
      not** affect Scope (independent of the Scope filter).

## Surface 10 — Coverage visualization

- [ ] **Three-mode cycle** — `M-x dimfort-cycle-coverage` cycles
      `gutter → background → disabled`. Echo area reports each tick.
      Visual states:
      - **gutter**: red / yellow / green fringe dots on in-scope
        lines; out-of-scope lines (module/contains/blank/comment)
        carry **no** fringe decoration.
      - **background**: low-alpha tint on each in-scope line in the
        matching tier colour; fringe dots **gone**. The two modes
        are **mutually exclusive**.
      - **disabled**: all coverage decorations clear.
- [ ] **No LSP restart on mode flip** — note the active server in
      `M-x eglot-events-buffer`. Cycle the coverage mode three times.
      The same server stays active. Contrast with
      `M-x dimfort-cycle-hover` which **does** restart the server —
      the restart-or-not difference is the verification.
- [ ] **Face customization repaints** —
      `M-x customize-face RET dimfort-coverage-green` → change
      `:foreground` to a new colour. Save. Green fringe dots repaint
      on next refresh. Same path for `dimfort-coverage-bg-green` in
      background mode.

## Surface 11 — `M-x dimfort-coverage-report` buffer

- [ ] **Cold-open populates** — fresh session, visit `qa.f90`,
      immediately run `M-x dimfort-coverage-report`. A
      `*DimFort Coverage*` buffer opens at the bottom (height ~14)
      with a File / Project table. File column populates within
      ~1–2 s of opening; no need to re-invoke.
- [ ] **Project column dim until checked** — before
      `M-x dimfort-check-workspace`, Project column reads `–` glyphs;
      footer text reads `Project coverage not yet computed.` /
      `Run M-x dimfort-check-workspace to compute.`. After a check
      completes, the Project column populates asynchronously
      (notification-driven, not return-value-driven).
- [ ] **Stale marker on edits** — after a workspace check, edit any
      buffer. Project column header switches to `Project (stale)`;
      footer text invites re-running the workspace command.
- [ ] **`q` closes** — `q` in the report buffer buries the window
      via `quit-window`.

## Surface 12 — Panel sort & unit-display modes (0.2.6)

- [ ] **Sort cycle** — `M-x dimfort-cycle-sort-mode` cycles
      `line → alphabetic → status`. Both Scope and Imports rows
      re-sort in the **same repaint** (no LSP round-trip — panel
      repaints from cached payload).
- [ ] **Sort persistence** — pick `alphabetic` via
      `M-x customize-variable RET dimfort-panel-sort-mode RET`, save
      for future sessions. Restart Emacs, reopen file: both sections
      come back in alphabetic order.
- [ ] **Unit-display cycle** — `M-x dimfort-cycle-unit-display`
      cycles `input → canonical → both`. Column layout changes per
      mode in **both** Scope and Imports together:
      - `input`: one column, annotation as written (`m/s`).
      - `canonical` (default): one column, base-SI form (`m·s⁻¹`).
      - `both`: two columns side-by-side — `input` then `canonical`,
        no arrow / separator glyph between (column spacing conveys
        the relationship; matches the VSCode panel's `<td>`
        convention).
- [ ] **Unit-display persistence** — same `customize-variable` path
      for `dimfort-panel-unit-display-mode`.

## Surface 13 — Config-file commands

These need a **fresh project folder** with no `dimfort.toml` and no
`units.toml`. `M-x cd` into an empty directory (verify
`default-directory`) before each subsection.

### `dimfort.toml`

- [ ] **Empty cold-create** — `M-x dimfort-open-config` → pick
      `Project configuration file (dimfort.toml)`. The
      `completing-read` shows `Empty template` and
      `Reference template (all sections commented out)`. Pick
      `Empty file`. A new `dimfort.toml` appears at the project root,
      opens, contains just the minimal header. Echo area:
      `DimFort: created <path>/dimfort.toml`.
- [ ] **Reference cold-create** — same as above, pick
      `Reference template …`. The file's `[units]` / `[parser]` /
      `[diagnostics]` / `[scale]` / `[project]` section headers are
      all present but each line is prefixed with `# `.
- [ ] **Warm-open** — run again, pick `Project configuration file`.
      Opens existing file with **no sub-pick** and **no
      modification**. No "created" echo.

### `units.toml`

- [ ] **Empty cold-create** — `M-x dimfort-open-config` → pick
      `Project units file (units.toml)`. `completing-read` shows
      `Empty template` and `Defaults as reference (all commented out)`.
      Pick `Empty file`. A new `units.toml` appears alongside the
      empty stub. A new `dimfort.toml` is auto-created with
      `[units]\nfile = "units.toml"`. Echo:
      `DimFort: created units.toml + wired into dimfort.toml`.
- [ ] **Reference cold-create** — pick `Reference template …`. The
      `[base]` / `[prefixes]` / `[derived]` sections are all present
      with `# `-prefixed lines.
- [ ] **Auto-wire appends to existing toml** — pre-create a
      `dimfort.toml` with only `[diagnostics]\nH001 = "off"\n`. Run
      command, pick units file. Existing `dimfort.toml` is **appended
      with** `[units]\nfile = "units.toml"`; original sections
      preserved.
- [ ] **Existing `[units]` declines** — pre-create a `dimfort.toml`
      containing `[units]\nother_key = "value"\n`. Run command, pick
      units file. Echo: `DimFort: created units.toml. Your dimfort.toml
      already has a [units] section — add 'file = "units.toml"' under
      it to enable the new file.`. The `dimfort.toml` is **not**
      modified.

## Surface 14 — Server-restart behaviour on cycle commands

- [ ] **Restarting cycles** —
      `M-x dimfort-cycle-{hover,scale,cache}` each **restart the
      server** on every tick (visible in `M-x eglot-events-buffer`).
      Echo area still reports the new mode; mode persists across
      restart.
- [ ] **Non-restarting cycles** —
      `M-x dimfort-cycle-{coverage,sort-mode,unit-display}` each
      do **not** restart the server (client-side rendering modes
      only).
- [ ] **`dimfort-clear-cache`** — `M-x dimfort-clear-cache` deletes
      `.dimfort-cache/` under the workspace root and restarts the
      server. Echo: `DimFort: cache cleared (…)`. When the cache
      directory does not exist, echo: `DimFort: cache directory does
      not exist (already clean).`.

## Surface 15 — Command-name parity

- [ ] **`M-x dimfort-toggle-panel`** is the canonical name
      (renamed from `dimfort-panel-toggle` in 0.2.6 for
      cross-companion consistency). `M-x dimfort-panel-toggle` is
      **not** offered as a command (the old name is gone, beta-period
      rename per release-cycle convention).

## Surface 16 — Polymorphic `'a` rendering

(Open `poly_qa.f90`.)

- [ ] **Scope rows** — point in `avg_two`'s body. Scope lists `x`,
      `y`, `mean` each with unit cell `'a` and `half` with `1`. The
      `'a` cells render at **full weight** (no dim face) — same
      visual weight as concrete units like `m` in `caller_clean`'s
      Scope (also point inside it to compare).
- [ ] **Inlay full weight** — covered under Surface 6 (cross-check
      that polymorphic ghost text matches concrete ghost-text weight).
- [ ] **`dimfort--dim` face scope** — confirm the dim face fires
      only on bare `?` / bare `-` / trailing `= ?`. A plain `'a` is
      **never** dimmed.

## Surface 17 — Delimiter-config face rendering

(Open `delim_qa.f90` with the companion `dimfort.toml` saved next to
it.)

- [ ] **Bracket-pattern hover** — eldoc on `pa`, `a`/`b`/`c`, or
      `kg` shows the bracket-captured unit (the toml configures `[…]`
      as a unit delimiter pattern alongside `@unit{…}`).
- [ ] **Plain `!` eligibility** — eldoc on `ws` (line 4) shows
      `m/s`; the `! @unit{m/s}` form has no Doxygen marker but still
      surfaces the unit.
- [ ] **Quick-fix on U002** — `M-x eglot-code-actions` on the
      `@unit{m2/s}` line surfaces **DimFort: Replace with 'm^2/s'**;
      applying clears the diagnostic. (Same UX as Surface 7's U002
      step — verified here against the delimiter scene.)
- [ ] **Cache invalidation on pattern change** — comment out
      `{ open = "@unit{", close = "}" }` in the toml, save, then
      `M-x dimfort-restart`. Eldoc on `ws` should now show no unit
      (canonical form no longer configured). Uncomment to restore.

---

Notes on out-of-scope checks: every step that asked for a specific
diagnostic code / line / message / payload shape in the previous
manual-QA shape has been removed in favour of the LSP integration
suite, which now exercises:

- diagnostics firing on the qa fixture
  (`tests/lsp_integration/test_diagnostics.py`)
- hover payload structure (`test_hover.py`)
- inlay & panel payload (`test_inlay_and_panel.py`)
- workspace check + `workspaceCheckCompleted` notification
  (`test_workspace.py`)
- coverage `lineStatus` tier classifications + U005 propagation
  (`test_coverage.py`)
- code-action data + completion candidates
  (`test_actions_completion.py`)
- lifecycle / `initialize` / cancellation (`test_lifecycle.py`)

If a regression suggests the wire payload changed shape, **start
there**; if everything in this walk passes but the suite fails,
suspect a server-side change.
