# Manual QA — DimFort Emacs companion

A precise visual smoke test to run **before tagging a release**. It
checks the parts only a human can see in the editor; the server's
verdicts are unit-tested upstream, so this deliberately does *not*
re-verify them. The Neovim and VSCode companions carry the same
checklist with their own commands — running all three confirms the
companions stay in parity.

Every step lists the **exact** expected result. Anything that differs
is a regression to file.

## Scene

Save this as `qa.f90` and open it. It is self-contained (one module,
no cross-file `use`) and fires exactly one of each interesting
diagnostic.

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
    d         = c_sound * t            ! OK:   m = (m·s⁻¹)*s
    bogus     = c_sound * t            ! H001: kg = m  (mismatch)
    t_celsius = t - 273.15             ! H010: bare 273.15 literal
    combo     = c_sound**2 + d * d / (t * t) - c_sound * c_sound
                                           !       (exercises +, -, *, /, **; all m²/s²)
    ln_p      = log(ref_pressure)            ! intrinsic: LOG-wrap (Pa → LOG(Pa))
    rt_e2     = sqrt(c_sound * c_sound)      ! intrinsic: sqrt halves (m²/s² → m/s)
    abs_t     = abs(t)                       ! intrinsic: preserves (s → s)
    recovered   = exp(log(ref_pressure) + log(ref_pressure))
                                             ! LOG/EXP algebra: homomorphism + cancellation
                                             !   exp(LOG(Pa) + LOG(Pa)) → exp(LOG(Pa²)) → Pa²
    rho_brandes = 1.e3 * 0.178 * (d * 2.0 * 1000.0)**(-0.922)   !< @unit_assume{kg/m^3 : empirical-fit Brandes2007}
                                             ! Non-rational power on a length — not algebraically derivable;
                                             ! @unit_assume asserts the result and fires U020 INFO.
    ref_pressure = dynamic_pressure(0.5 * c_sound)
    call scale_pressure(2.0 * ref_pressure)        ! subroutine call
  end subroutine checks

  subroutine scale_pressure(p)
    real, intent(in) :: p   !< @unit{Pa}
    ref_pressure = p
  end subroutine scale_pressure
end module qa_mod
```

Start the server: `M-x eglot`. Give the first workspace check a moment
to finish, then walk the sections below.

## Defaults (fresh config)

- [ ] No `[unit]` inlay ghost text anywhere — inlays are off by default.
- [ ] The **side panel opens automatically** on the right once the server
      attaches — it's on by default.
- [ ] `M-x dimfort-status` prints **exactly** this:

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

## Diagnostics

In Emacs (flymake), an **error** renders the offending text in **bold
red** with red `!!` in the left fringe; a **warning** renders in **bold
orange** with a single orange `!`. On a fresh open, confirm exactly:

- [ ] **Line 23** — `t_celsius` (no annotation) → **U005 warning**: the
      name `t_celsius` in bold orange, orange `!` in the fringe.
- [ ] **Line 25** — `bogus = c_sound * t` → **H001 error** `kg ≠ m`: the
      whole assignment in bold red, red `!!` in the fringe.
- [ ] **Line 26** — `t_celsius = t - 273.15` → **H010 warning** on the
      `273.15` literal (suggests extracting it to a named PARAMETER).
- [ ] Lines 24, 27, 29, 30, 31, 32, and 38 are **clean**; line 35 fires a **U020 INFO** acknowledging the `@unit_assume` (informational, not a problem) — no diagnostic (the assignments are
      unit-consistent).

**Interactive — U002 (unparseable annotation):** change line 14's
`!< @unit{s}` to `!< @unit{??}` and save (`C-x C-s`). Confirm **two**
diagnostics on line 14, then undo (`C-/`):

- [ ] A **U002 error** underlining the `@unit{??}` token itself (not the
      start of the line).
- [ ] A **U005 warning** on `t` itself — because an unparseable annotation
      makes `t` count as unannotated. (In the panel, `t` flips to 🔴.)

## Hover

Hover defaults to **`short`** (a compact unit surface beside the panel).
`M-x dimfort-cycle-hover` cycles `disabled → short → detailed`, restarting the
server each time. Point at the symbol; eldoc shows in the echo area (or open a
window with `M-x eldoc-doc-buffer`).

- [ ] **Short (default)** — on **`c_sound`** → single row
      `c_sound : m·s⁻¹`. On the product `c_sound * t` (line 24) → the
      tree shape used by every short hover:

      ```
      🟢 DimFort
      c_sound * t  :  m       🟢
      ├── c_sound  :  m·s⁻¹   🟢
      └── t        :  s       🟢
      ```

- [ ] **Binary operators** — on **line 27** (the `combo = …`
      assignment), hover each of `+`, `-`, `*`, `/`, `**` in turn. Each
      renders the same tree shape (root sub-expression + immediate
      operand rows); every row is 🟢; the topmost `**` shows
      `c_sound**2 : m²·s⁻²` over its operand rows. One fixture
      exercises every binary operator.

- [ ] **Detailed** — cycle once more to `detailed`. For bare-identifier
      operands like `c_sound * t` the layout is unchanged from short
      (nothing to expand). For the **call** `dynamic_pressure`
      (line 38), Detailed adds a sub-tree under the computed
      argument row — the difference from Short:

      ```
      🟢 DimFort
      dynamic_pressure(0.5 * c_sound) : kg·m⁻¹·s⁻²  🟢
      └── 0.5 * c_sound               : m·s⁻¹       🟢
          ├── 0.5                     : 1           🟢
          └── c_sound                 : m·s⁻¹       🟢
      ```

      (Short shows root + the `0.5 * c_sound` argument row only, no
      sub-tree.)

- [ ] **Subroutine call** — still in `detailed`, hover the call name
      `scale_pressure` (line 39). Same tree layout as a function call,
      **but the root has no return unit** so it reads
      `call scale_pressure(…) : -  🟢`. Argument row
      `2.0 * ref_pressure : kg·m⁻¹·s⁻² 🟢` with the sub-tree beneath.

- [ ] **Intrinsics — same tree as user calls.** Still in `detailed`:
      - Point on `log` (line 29): root row `log(ref_pressure) :
        LOG(Pa)` + child row `ref_pressure : Pa 🟢`. Intrinsic call
        hovers now use the same tree renderer as user calls — no more
        bare-identifier-fallback one-liner.
      - Point on `sqrt` (line 30): root row `sqrt(c_sound * c_sound)
        : m·s⁻¹` + computed-arg row (with operand sub-tree in
        Detailed). Sqrt halves the unit (m²/s² → m/s).
      - Point on `abs` (line 31): root row `abs(t) : s` + `t : s`
        child row. Abs preserves the operand's unit.
      Intrinsics have no `(expected …)` annotation on args — we don't
      track formal-arg units for them — but the structural tree is
      identical.

- [ ] **LOG / EXP computational tricks** — the idiom physicists use
      to do multiplicative work in log space:
      `recovered = exp(log(p) + log(p))`. One line exercises BOTH
      rules:
      - **Homomorphism** (inside): `log(p) + log(p) → LOG(p²)`.
      - **Cancellation** (outside): `exp(log(q)) → q`.

      On **line 32**, point on the outermost `exp` (Detailed): root
      row `exp(log(ref_pressure) + log(ref_pressure)) : Pa²  🟢`
      over the child `log(ref_pressure) + log(ref_pressure) :
      LOG(Pa²) 🟢`, and the sub-tree under that shows two
      `log(ref_pressure) : LOG(Pa) 🟢` rows. DimFort follows the
      algebra symbolically — no opacity, no approximation — so the
      round-trip `exp ∘ (sum of logs)` recovers the product unit
      cleanly. Strong showcase for atmospheric-science audiences.

- [ ] **`@unit_assume` escape hatch** — empirical fits with
      non-derivable units. On **line 35**, point on the assignment
      (`rho_brandes = 1.e3 * 0.178 * (d * 2.0 * 1000.0)**(-0.922)`):
      the line carries `!< @unit_assume{kg/m^3 : empirical-fit
      Brandes2007}`. Because the RHS contains a length raised to a
      non-rational power, the unit isn't derivable from first
      principles — DimFort would normally emit `D1.4`. The
      `@unit_assume` directive asserts the result's unit and
      suppresses `D1.4`; in its place a **U020 INFO** appears,
      acknowledging the assumption (informational, not a problem).
      The hover reads:

      ```
      🟢 DimFort
      rho_brandes = … : -                          🟢
      ├── rho_brandes                : kg·m⁻³     🟢
      └── 1.e3 * 0.178 * (d * 2.0 * 1000.0)**(-0.922)
                                     : kg·m⁻³     🔵  (assumed: empirical-fit Brandes2007)
          ├── …                        (RHS sub-tree with 🟡 leaves
          └── …                         from the unresolved (-0.922))
      ```

      The 🔵 is a **per-row overlay** (NOT a severity tier — see
      DimFort design/markers.md §4.6) painted on the RHS row, the
      directive's syntactic subject. The RHS row's unit column shows
      the **asserted** unit `kg·m⁻³`, not the computed `?`. The
      assignment row stays **🟢** because the homogeneity check
      passes (LHS `kg·m⁻³` matches the asserted RHS `kg·m⁻³`); the
      hover header is `🟢 DimFort`. The 🔵 surfaces only in the
      body, where the assertion lives. The RHS sub-tree still shows
      its underlying algebra (with 🟡 on the `(-0.922)` unresolved
      leaf) for transparency, but doesn't propagate up to the
      assignment row.
      Common in physics: Tetens (saturation vapour pressure),
      Magnus, Buck, parameterised turbulence closures, etc.

- [ ] **Assignment-mismatch `(expected …)` annotation.** On line 25
      (`bogus = c_sound * t`), point on the `=`. The root row paints
      🔴 from `H001` owning the assignment; the RHS child row reads
      `c_sound * t : m  🟡  (expected kg)`. The 🟡 is the
      🟡-on-`expected` override — the RHS expression resolved cleanly
      to `m`, but its consumer (the LHS) demanded `kg`.

- [ ] **Pure-signature hover** (point on a function/subroutine
      *definition* header — no call site). Point on `dynamic_pressure`
      in **line 5** (the function definition itself). The hover
      collapses to a single line:

      ```
      🟢 DimFort

      dynamic_pressure(m·s⁻¹) : kg·m⁻¹·s⁻²
      ```

      Just the dimensional signature. No per-arg row table — the
      header alone carries the formal interface. Unannotated formal
      slots and unannotated returns render as `?` and flip the
      header marker to 🟡.

- [ ] Cycle once more → back to `disabled`; hovers go silent again.

## Inlay hints

- [ ] `M-x dimfort-toggle-inlay-hints` → `[m·s⁻¹]`-style ghost text appears
      after variable uses. Run it again → the ghost text disappears.

## Code actions

`M-x eglot-code-actions` with point on the relevant line.

- [ ] On `t_celsius` (line 23) → **"add `@unit{}`"**. Applying inserts
      `!< @unit{}` and leaves point **between the braces**.
- [ ] On the `273.15` (line 26) → **"extract literal to PARAMETER"**.
      Applying prompts for a name, then inserts a typed `real, parameter`
      declaration and replaces the `273.15` with the new name.

## Navigation & completion

- [ ] `M-.` (`xref-find-definitions`) on a `c_sound` use → jumps to its
      declaration on line 2.
- [ ] Type a new `!< @unit{` and invoke completion (`C-M-i`) → unit names
      are offered. **Tip — if your terminal sends a literal `9;6u`** when
      you press `C-M-i` (the CSI u keyboard protocol that terminal Emacs
      doesn't decode), use **`ESC TAB`** instead — the universal substitute
      for `C-M-i` (`ESC` is Meta, `TAB` is `C-i`). GUI Emacs avoids the
      whole issue.

## Side panel

`M-x dimfort-panel-toggle` opens it on the right. The panel follows the
cursor (≈0.2 s debounce) and dims briefly while it refreshes.

- [ ] **Assignment with a mismatch** — put point on the **`=`** in line 25
      (`bogus = c_sound * t`). The whole assignment renders, marked 🔴
      because `kg ≠ m`:

      ```
      Expression

      bogus = c_sound * t : -      🔴
      ├── bogus           : kg     🟢
      └── c_sound * t     : m      🟡  (expected kg)
          ├── c_sound     : m·s⁻¹  🟢
          └── t           : s      🟢
      ```

      The root row reads `: -` (structural-no-unit — an assignment has
      no own unit) and 🔴 because H001 owns it. The RHS row demotes
      🟢 → 🟡 with `(expected kg)` appended: the expression
      `c_sound * t` resolved cleanly to `m`, but its consumer (the LHS)
      demanded `kg`. (Rule IDs like `(R4.2)` are no longer rendered on
      tree rows.)

- [ ] **Multiplication chain** — point on the **`=`** in line 10
      (`q = 0.5 * rho * v * v`). The product nests, every step 🟢, the
      root resolving to `kg·m⁻¹·s⁻²`:

      ```
      q = 0.5 * rho * v * v : -            🟢
      ├── q                 : kg·m⁻¹·s⁻²  🟢
      └── 0.5 * rho * v * v : kg·m⁻¹·s⁻²  🟢
          ├── 0.5 * rho * v : kg·m⁻²·s⁻¹  🟢
          │   ├── 0.5 * rho : kg·m⁻³      🟢
          │   │   ├── 0.5   : 1           🟢
          │   │   └── rho   : kg·m⁻³      🟢
          │   └── v         : m·s⁻¹       🟢
          └── v             : m·s⁻¹       🟢
      ```

- [ ] **Function call with arguments** — point on the call name
      `dynamic_pressure` in line 38. The call resolves to its result unit,
      and the computed argument breaks down beneath it:

      ```
      dynamic_pressure(0.5 * c_sound) : kg·m⁻¹·s⁻²  🟢
      └── 0.5 * c_sound               : m·s⁻¹       🟢
          ├── 0.5                     : 1           🟢
          └── c_sound                 : m·s⁻¹       🟢
      ```

- [ ] **Subroutine call** — point on the call name `scale_pressure` in
      line 39. A subroutine has no return unit, so the root shows `-`
      in the unit column and 🟢 (no diagnostic owns it). The computed
      argument still expands beneath it:

      ```
      call scale_pressure(2.0 * ref_pressure) : -           🟢
      └── 2.0 * ref_pressure                  : kg·m⁻¹·s⁻²  🟢
          ├── 2.0                             : 1           🟢
          └── ref_pressure                    : kg·m⁻¹·s⁻²  🟢
      ```

- [ ] **Call-arg expected on mismatch** — temporarily edit line 38 to
      `ref_pressure = dynamic_pressure(c_sound * t)`. The Expression
      tree's argument row now shows
      `c_sound * t : m 🟡 (expected m·s⁻¹)` — the 🟡 is the
      expected-override (the expression resolved cleanly, but the call
      disagrees with the formal); the 🔴 sits on the enclosing call
      via H004. Revert the edit when done.

- [ ] **Stacked scopes** — with point in line 10 (inside the function),
      the Scope section stacks the module over the function, indented by
      nesting (no column header — the row is `line · name · unit · mark`):

      ```
      Module: qa_mod

        2     c_sound                              m·s⁻¹       🟢
        3     ref_pressure                         Pa          🟢
        5     dynamic_pressure(m·s⁻¹)              kg·m⁻¹·s⁻²  🟢
       24     scale_pressure(kg·m⁻¹·s⁻²)           -           🟢

        Function: dynamic_pressure

          6     v    m·s⁻¹  🟢
          7     q    Pa     🟢
          8     rho  kg/m^3 🟢
      ```

      The two procedure rows under `Module: qa_mod` are the module's own
      defined functions/subroutines — visible from anywhere within the
      module (Fortran host association), mirroring how imported
      procedures show in the Imports section. Subroutines render `-` in
      the unit column (no return *by design*).

- [ ] **Markers** — in `checks` (e.g. point in line 25), `t_celsius` shows
      🟡 (unannotated). With a `@unit{??}` somewhere in scope, that
      variable shows 🔴 (annotated but unparseable).

- [ ] **Cursor-follow** — move point between line 10 (function) and line 25
      (subroutine); the Scope section switches between `Function:
      dynamic_pressure` and `Subroutine: checks` accordingly.

### Panel — Diagnostics / Interactions / Actions (the `both` layout)

These three sections sit between Expression and Scope. Each is always
present, showing `(none)` when nothing applies, so they don't pop in and
out as point moves.

- [ ] **Diagnostics** — point on line 25 (`bogus = c_sound * t`); the
      Diagnostics section shows **🔴 H001: …**. On line 23 (`t_celsius`) it
      shows **🟡 U005: …**. On a clean line (18) it shows `(none)`. `RET`
      on a diagnostic row jumps to that span.
- [ ] **Interactions** — point on a `c_sound` use (line 24). The
      Interactions section shows the symbol `c_sound`, then the
      **Declaration** group (line 2) and **Read** group (its use sites),
      each row `file:line   unit` with the snippet beneath. `RET` on a site
      jumps there (cross-file when the site is elsewhere). Because
      `c_sound` is read as `m·s⁻¹` at lines 18/21 but `kg/s` at line 25, a
      **🔴 X001** conflict row sits at the top.
- [ ] **Actions** — point on `t_celsius` (line 23) → the Actions section
      lists **• Add @unit{} to t_celsius**; `RET` on it inserts `!< @unit{}`
      with point between the braces. Point anywhere on line 26 (the H010
      line) → **• Extract literal '273.15' into a named PARAMETER (s)**;
      `RET` prompts for a name and applies the refactor.
- [ ] **Footer (coverage bar)** — the panel's last line reads
      `File: <pct>% (🟡 N 🔴 M)   WS: …` with the active file's
      coverage on the left and the whole-workspace aggregate on
      the right.
- [ ] **WS pre-refresh state** — before the first manual
      workspace check, the WS segment reads `WS: –` (dimmed).
- [ ] **Workspace check** — run `M-x dimfort-check-workspace`.
      The WS segment becomes a Braille spinner
      (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) for the duration of the server-side
      check, then settles to `WS: <pct>% (🟡 N 🔴 M)` when the
      `dimfort/workspaceCheckCompleted` notification arrives.
- [ ] **WS stale state** — after a successful check, edit any
      Fortran buffer. The WS segment dims (the snapshot may no
      longer reflect current state). The File segment updates
      live.
- [ ] **Duplicate trigger** — run `M-x dimfort-check-workspace`
      twice in quick succession. The second invocation prints
      "DimFort: workspace check already in progress" to the echo
      area instead of spawning a second worker.
- [ ] **Restart clears state** — `M-x dimfort-restart` resets
      the bar back to `File: –   WS: –` (dimmed) and clears the
      file-coverage cache; the next workspace check re-populates.

### Panel — Scope filter

- [ ] `M-x dimfort-scope-filter RET Pa RET` → the Scope section keeps only
      variables whose name or unit matches `Pa` (e.g. `ref_pressure`, `q`),
      with a `Filter: "Pa"` header; scopes with no surviving variables are
      hidden. `M-x dimfort-scope-filter RET RET` (empty) clears it.

## Scale checking (S001 / S002)

Save this `scale_qa.f90` and open it (no `.dimfort.toml` needed — the
editor toggle drives it):

```fortran
module scale_qa
  real, parameter :: PA_PER_HPA = 100.   !< @unit{Pa/hPa}
  real :: play   !< @unit{Pa}
  real :: phpa   !< @unit{hPa}
  real :: t_k    !< @unit{K}
  real :: t_c    !< @unit{degC}
contains
  subroutine s()
    phpa = play                  ! S001: hPa vs Pa (×100 multiplicative scale)
    phpa = play / PA_PER_HPA     ! clean: the typed factor cancels the mismatch
    t_k  = t_c                   ! S002: K vs degC (affine offset)
  end subroutine s
end module scale_qa
```

- [ ] **Auto (default)** — with `dimfort-scale-mode` = `"auto"` and no
      `.dimfort.toml`, the file is **clean** (no S001/S002).
- [ ] **On** — `M-x dimfort-cycle-scale` until the echo area says
      `scale checking -> on` (the server restarts): `phpa = play` →
      **S001** and `t_k = t_c` → **S002** (yellow), the panel circles 🟡.
- [ ] **Scale factor surfaces uniformly in scale mode** — with scale on,
      point on the `=` of `phpa = play` (or look at the Panel's
      Expression section). The LHS row reads `phpa : 100×kg·m⁻¹·s⁻²` 🟢
      and the RHS row reads `play : kg·m⁻¹·s⁻²` 🟢 — the ×100 ratio
      matches the diagnostic's `×100`. The same factor appears wherever
      a unit is rendered (scope/imports normalized columns, etc.). With
      scale off, factors are hidden everywhere — both sides of the
      assignment render to the bare `kg·m⁻¹·s⁻²`. Single rule: displays
      match what the checker is reasoning about.
- [ ] **Typed conversion silences it** — the second assignment in `s()`,
      `phpa = play / PA_PER_HPA`, is **clean** (no S001). The typed
      `Pa/hPa` parameter carries the multiplicative factor explicitly,
      so the assignment's units balance and the scale check passes.
- [ ] **Off / Auto** — cycle again to `off` (forced clean even if a toml
      enabled it), once more to `auto` (back to deferring to the toml).

## Unparsed regions (P001)

`P001` marks lines tree-sitter couldn't parse — DimFort makes no unit
guarantee there. It's an **info** diagnostic, so it renders as a faint
**blue** squiggle, distinct from real (red) violations.

Save this `unparsed_qa.f90` and open it:

```fortran
subroutine unparsed_qa(press, vel)
  implicit none
  real, intent(in)  :: press   !< @unit{Pa}
  real, intent(out) :: vel     !< @unit{m/s}
  vel = press        ! H001 (red): m·s⁻¹ vs Pa
  vel = * / +        ! P001 (blue): unparseable line
  vel = 0.0          ! swallowed by line-6 error region — blue too
  vel = vel * 2.0    ! CLEAN — proves the blue stops here
end subroutine unparsed_qa
```

> Why two trailing statements: `vel = 0.0` gets swallowed by tree-sitter's
> error recovery on line 6 (its assignment_statement is consumed into the
> ERROR region, so the Expression panel is degraded there). `vel = vel * 2.0`
> is the first fully-clean statement after the bad line — present to
> demonstrate that the P001 squiggle *stops* at line 7 and does NOT bleed
> further. A trailing valid statement is also required for tree-sitter to
> find the subroutine boundary; without one, the **whole** routine wraps in
> an error region and the Scope panel blanks (known panel-robustness gap).

- [ ] **Blue squiggle** — `vel = * / +` gets a **blue (info)** underline;
      point on it (and `M-x dimfort-show-diagnostic`) shows
      **`P001` … "could not parse this region — DimFort makes no unit
      guarantee here"** at *Information* severity. With point on that
      line, the panel's **Diagnostics** section lists the P001 with a
      **🔵** glyph (matching 🔴 error / 🟡 warning).
- [ ] **Distinct from a real error** — `vel = press` carries a **red**
      `H001` on the line above, so blue (FYI) and red (violation) are
      visibly different.
- [ ] **Localized, not the whole routine** — the blue squiggle covers
      **exactly two lines**: `vel = * / +` (the bad line) and the
      immediately-following `vel = 0.0` (whose assignment_statement
      tree-sitter swallows into the error recovery region). The next
      line `vel = vel * 2.0` is **not blue** — proving the squiggle stops
      at the right boundary. The Expression panel is correctly empty on
      lines 6-7 (no trustworthy tree there) and populates normally on
      line 8 (clean autocast → `m·s⁻¹`).
- [ ] **Doesn't mask real checks** — the `H001` still fires; P001 only marks
      what it *couldn't* read, it doesn't suppress checking elsewhere.
- [ ] **Suppressible** — add a workspace `.dimfort.toml` with
      `[diagnostics]` `P001 = "off"`, save; the blue squiggle disappears
      (no manual restart), the red `H001` stays.

## Imports section

Save this `imports_qa.f90` and open it (one file, two modules — the
second `use`s the first):

```fortran
! `phys_base` exists to test TRANSITIVE re-export: phys_constants
! `use`s it, and `solver` uses phys_constants — see whether `g0`
! surfaces in solver's Imports section.
module phys_base
  real :: g0   !< @unit{m/s^2}
end module phys_base

module phys_constants
  use phys_base                          ! transitive: re-exports g0 by default
  real :: play     !< @unit{Pa}
  real :: grav     !< @unit{m/s^2}
  real :: density                        ! NO annotation → unannotated 🟡
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

- [ ] **Lists vars + procedures + subroutines + unannotated** — point
      on `local_p = play` (inside `step`): the **Imports** section
      shows a `from phys_constants` header with four indented rows:
      - `play         kg·m⁻¹·s⁻²  🟢` (annotated variable)
      - `gravity_at(m)  m·s⁻²     🟢` (callable, arg unit in parens,
        return unit in the column)
      - `set_play(Pa)  -          🟢` (subroutine — structural-no-unit
        glyph, dimmed; distinct from `(none)`)
      - `density       ?          🟡` (unannotated variable — the `?`
        glyph appears dimmed, distinguishing it from a real unit)
- [ ] **Cross-file navigation** — `RET` on `play` jumps to its
      declaration; `RET` on `gravity_at(m)` jumps to the function;
      `RET` on `set_play(Pa)` jumps to the subroutine. Same file
      here; another file in a real project.
- [ ] **Scoped + shadowed** — `grav` is **not** listed (the `only:`
      list excludes it). Add `real :: play !< @unit{Pa}` as a local
      in `step` and `play` drops from Imports (the local shadows it;
      it shows under Scope instead).
- [ ] **Transitive imports** — drop the `, only: …` filter on `solver`'s
      `use phys_constants` line so it becomes plain `use phys_constants`.
      `phys_constants` itself `use`s `phys_base`, which declares `g0`.
      Default Fortran semantics re-export `g0` through `phys_constants`.
      Point inside `step`: a **second** group header appears, `from
      phys_base` (tagged `via phys_constants`), with a single row:
      - `g0` → `m·s⁻²` 🟢 — `RET` on it **jumps cross-file** to
        `phys_base`'s declaration site (`imports_qa.f90:2`).
      The existing `from phys_constants` group still lists `play`,
      `grav`, `density`, `gravity_at`, `set_play` — transitive
      re-export only adds the `phys_base` group, never removes a row.
- [ ] **Imports filter** — `M-x dimfort-imports-filter RET gravity RET`
      narrows the Imports section to `gravity_at(m)`; `play` narrows
      to `play` + `set_play(Pa)`; empty clears it. Independent of
      `dimfort-scope-filter` (Scope).
- [ ] **Empty case** — point in `phys_base` (which imports nothing):
      the Imports section shows `(none)`.

## Configurable comment delimiters (0.2.2)

Save this `delim_qa.f90` in a fresh folder alongside the toml
just below it:

```fortran
subroutine delim_demo
  implicit none

  ! §10 — bare ! @unit{} is now eligible at a decl. Hover → m/s.
  real :: ws   ! @unit{m/s}

  ! §2 — bracket pattern (configured below). Hover → Pa.
  real :: pa   ! atmospheric pressure [Pa] at the surface

  ! §3.2 — standalone above a decl, plain `!`. Hover → kg.
  ! mass loading [kg]
  real :: kg

  ! §6 — any pattern on a multi-var attaches to all names.
  real :: a, b, c   ! [m]

  ! §8.2 — two patterns disagree → U021. First-listed (`@unit{}`)
  ! wins, so hover `g` → kg.
  real :: g   !< wind speed [m/s] @unit{kg}

  ! §8.3 — @unit_assume on a declaration → U023.
  real :: t   !< @unit_assume{K: legacy fit}

  ! §8.3 — @unit{} on an assignment → U023.
  ws = 1.0   !< @unit{m/s}

  ! §12 — unparseable unit → U002 with suggested rewrite.
  real :: diff   !< @unit{m2/s}
end subroutine
```

Save this `.dimfort.toml` next to it:

```toml
[parser]
unit_comment_delimiters = [
  { open = "@unit{", close = "}" },
  { open = "[",      close = "]" },
]
```

- [ ] **Bracket pattern recognised** — `eldoc` / `eglot` hover
      on `pa`, `a`/`b`/`c`, or `kg` (above) shows the
      bracket-captured unit.
- [ ] **Plain `!` eligibility (§10)** — `ws` on line 4 has the
      `! @unit{m/s}` form (no Doxygen marker). Hover shows `m/s`.
- [ ] **U021 fires** — line with `[m/s] @unit{kg}` shows a
      `flymake` warning indicator; the message names both
      captures; hover `g` shows `kg` (the first-listed pattern's
      capture).
- [ ] **U023 fires** — `@unit_assume{K: legacy fit}` on the
      `real :: t` decl shows a warning; message says "did you
      mean @unit?". Same for `@unit{m/s}` on `ws = 1.0` — the
      message suggests `@unit_assume` or
      `@unit_affine_conversion`.
- [ ] **U002 quick-fix** — `@unit{m2/s}` shows a `flymake` error
      indicator; message includes "did you mean 'm^2/s'?".
      `M-x eglot-code-actions` offers **DimFort: Replace with
      'm^2/s'** as the preferred fix; accepting it edits
      `m2/s` → `m^2/s` and clears the diagnostic.
- [ ] **Pattern config invalidates cache** — comment out
      `{ open = "@unit{", close = "}" }` in the toml, save, then
      `M-x dimfort-restart`. The `@unit{m/s}` hover on `ws`
      should now show no unit (the canonical form is no longer
      configured in this project). Uncomment to restore.

## Polymorphism (0.2.3)

Save this as `poly_qa.f90` in a fresh folder (no `.dimfort.toml`
needed — defaults are fine). The scene covers four cases: clean
polymorphic body, dishonest body, caller mismatch, clean caller.

```fortran
module poly_qa
contains

  ! Case A — cleanly polymorphic body. No fires expected.
  subroutine avg_two(x, y, mean)
    real, intent(in)  :: x     !< @unit{'a}
    real, intent(in)  :: y     !< @unit{'a}
    real, intent(out) :: mean  !< @unit{'a}
    real :: half  !< @unit{1}
    half = 0.5
    mean = half * (x + y)
  end subroutine avg_two

  ! Case B — dishonest body: signature claims 'a but body adds {kg}.
  subroutine biased_avg(x, y, mean)
    real, intent(in)  :: x        !< @unit{'a}
    real, intent(in)  :: y        !< @unit{'a}
    real, intent(out) :: mean     !< @unit{'a}
    real, parameter   :: bias_kg = 1.0  !< @unit{kg}
    real :: half  !< @unit{1}
    half = 0.5
    mean = half * (x + y) + bias_kg
  end subroutine biased_avg

  ! Case C — caller passes kg into one 'a slot and m into another.
  subroutine caller_mismatch(m_in, l_in, out_mean)
    real, intent(in)  :: m_in      !< @unit{kg}
    real, intent(in)  :: l_in      !< @unit{m}
    real, intent(out) :: out_mean  !< @unit{kg}
    call avg_two(m_in, l_in, out_mean)
  end subroutine caller_mismatch

  ! Case D — caller passes consistent {m} to both slots.
  subroutine caller_clean(a_in, b_in, out_mean)
    real, intent(in)  :: a_in      !< @unit{m}
    real, intent(in)  :: b_in      !< @unit{m}
    real, intent(out) :: out_mean  !< @unit{m}
    call avg_two(a_in, b_in, out_mean)
  end subroutine caller_clean

  ! ------------------------------------------------------------------
  ! Function variants — same shape as Cases A-D but on a polymorphic
  ! FUNCTION. The call lives in an assignment RHS (call_expression
  ! node), and the function returns 'a too — exercises the return-
  ! side rendering, distinct from the subroutine_call path above.
  ! ------------------------------------------------------------------

  ! Case E — polymorphic function (clean body, no fires).
  function avg_two_f(x, y) result(out)
    real, intent(in) :: x    !< @unit{'a}
    real, intent(in) :: y    !< @unit{'a}
    real             :: out  !< @unit{'a}
    out = 0.5 * (x + y)
  end function avg_two_f

  ! Case F — clean caller of the function. No fires expected; mirrors
  ! Case D for the function path.
  subroutine caller_func_clean(a_in, b_in, r)
    real, intent(in)  :: a_in   !< @unit{m}
    real, intent(in)  :: b_in   !< @unit{m}
    real, intent(out) :: r      !< @unit{m}
    r = avg_two_f(a_in, b_in)
  end subroutine caller_func_clean

  ! Case G — H020 caller of the function. arg 1 (kg) and arg 2 (m)
  ! force 'a to inconsistent units; mirrors Case C for the function
  ! path.
  subroutine caller_func_mismatch(m_in, l_in, r)
    real, intent(in)  :: m_in   !< @unit{kg}
    real, intent(in)  :: l_in   !< @unit{m}
    real, intent(out) :: r      !< @unit{kg}
    r = avg_two_f(m_in, l_in)
  end subroutine caller_func_mismatch

end module poly_qa
```

### Diagnostics

On a fresh open, confirm exactly the following diagnostics in
`flymake-show-buffer-diagnostics` (eglot) or `lsp-treemacs-errors-list`
(lsp-mode). Anything else is a regression.

- [ ] **Case A — no diagnostics anywhere** on lines 5–12.
- [ ] **Case B — H023 error** on the assignment expression line
      `mean = half * (x + y) + bias_kg` (line 23). Message names
      the offending term (`bias_kg : kg`) and explains the body
      would force `'a = kg`.
- [ ] **Case C — H020 error** on the call site `call avg_two(m_in,
      l_in, out_mean)` (line 31). Message includes the **symmetric
      `(collides with arg N (name))` trailer** — both arg 1 and arg
      2 are named (no "first arg wins" asymmetry). The unit each
      slot implied (`kg` and `m`) is rendered.
- [ ] **Case D — no diagnostics** on lines 36–41.
- [ ] **Case E — no diagnostics anywhere** in the `avg_two_f`
      function body. Mirrors Case A's clean polymorphism, this time
      on a `function`.
- [ ] **Case F — no diagnostics** in `caller_func_clean`. The
      `r = avg_two_f(a_in, b_in)` assignment is clean — function
      return `'a` binds to `m`, RHS unit = LHS unit (`m`). Mirrors
      Case D for the function path.
- [ ] **Case G — H020 error** on the call_expression inside the
      assignment `r = avg_two_f(m_in, l_in)`. Same shape as Case C
      (symmetric `collides with` trailer, two-way conflict between
      arg 1 = kg and arg 2 = m), just on a `call_expression` node
      instead of `subroutine_call`. There should be NO additional
      H001 / H004 / S001 on the assignment row — H020 alone owns
      the failure.
- [ ] **Diagnostic list** shows exactly **three** entries
      (H023 + H020 + H020), nothing else.

### Hover

Hover with `eldoc-doc-buffer` (eglot) or `lsp-ui-doc-show`
(lsp-mode), or `M-x dimfort-hover-at-point`.

- [ ] **Hover on a tyvar in a signature** — cursor on the `'a` in
      `@unit{'a}` on line 7 (Case A's `x`). Hover shows the
      polymorphic marker — exact rendering TBD per the spec; should
      indicate `'a` is a free type variable, not a concrete unit.
- [ ] **Hover on a clean call site (Case D)** — cursor on
      `call avg_two(...)` on line 41. Hover renders the
      **σ-binding panel**: `'a = m` (the unifier's solution at this
      call). Every slot row is 🟢.
- [ ] **Hover on the failed call site (Case C)** — cursor on
      `call avg_two(...)` on line 31. Hover surfaces the conflicting
      contributions per slot (`x → kg`, `y → m`, `mean → kg`); no
      single `σ` panel because unification failed.
- [ ] **Hover on `mean` in Case B body** — cursor on `mean` on
      line 23. The expression tree shows `'a` for `mean`, `kg` for
      `bias_kg`, the conflict row marked 🔴.
- [ ] **Hover on Case F's call assignment** — cursor on
      `r = avg_two_f(a_in, b_in)`. Tree root is the assignment;
      RHS row is the call_expression. Arg rows render bare `m` 🟢
      (no `(expected 'a)` trailer, no demote — same as Case D's
      subroutine_call path). RHS row's unit is `m` (the bound
      return), matching LHS `r : m` cleanly.
- [ ] **Hover on Case G's call assignment** — cursor on
      `r = avg_two_f(m_in, l_in)`. Arg rows render the spec form:
      `m_in : 'a = kg 🔴 (collides with arg 2)` and
      `l_in : 'a = m 🔴 (collides with arg 1)`. The call_expression
      RHS row shows 🔴 from the H020 propagation. Assignment row
      inherits 🔴. No spurious `(expected ...)` trailers on any arg
      row.
- [ ] **Hover on a polymorphic var usage** — cursor on `x` inside
      Case A's body (`mean = half * (x + y)`). Short hover shows the
      same row shape as a concrete-var hover — `x : 'a` 🟢, no
      trailer. Same on `y`. (Polymorphism shows in the unit column
      via the `'a` tyvar text; otherwise reads as any normal
      identifier hover.)

### Side panel

Cursor in each routine's body in turn (toggle the panel with
`M-x dimfort-panel-toggle` if not already visible). The Scope
section should list the routine's locals + formals; the polymorphic
ones render with `'a` in the unit column.

- [ ] **Case A — `avg_two`** — Scope lists `x`, `y`, `mean` each
      with unit `'a`, and `half` with unit `1`. All rows 🟢.
- [ ] **Case B — `biased_avg`** — Scope lists `x`, `y`, `mean` with
      `'a`, `bias_kg` with `kg`, `half` with `1`. The dishonest body
      assignment shows a 🔴 on `mean` (or a flag/marker that the
      body conflicts with the signature — exact UX TBD).
- [ ] **Case C — `caller_mismatch`** — Scope lists `m_in : kg`,
      `l_in : m`, `out_mean : kg`. Side panel surfaces the call-site
      σ failure somewhere (a dedicated row, marker, or callout —
      exact rendering to verify).
- [ ] **Case D — `caller_clean`** — Scope lists three rows in `m`.
      No σ markers; the call site is uneventful.
- [ ] **Case E — `avg_two_f`** — Scope lists `x`, `y`, `out` each
      with unit `'a`. All rows 🟢 (clean function body).
- [ ] **Case F — `caller_func_clean`** — Scope lists `a_in : m`,
      `b_in : m`, `r : m`. All 🟢. The Expression section (with
      cursor in the assignment) shows the call_expression RHS
      resolving to `m` cleanly.
- [ ] **Case G — `caller_func_mismatch`** — Scope lists `m_in : kg`,
      `l_in : m`, `r : kg`. The Expression section surfaces the
      H020 conflict on the call_expression child of the assignment
      (same UX as Case C's subroutine_call).
- [ ] **Polymorphic vars render full-weight in the unit column** —
      across Cases A / B / E, the `'a` cells are rendered the same
      visual weight as concrete units like `m` or `kg` on Cases C / D
      / F / G. The `dimfort--dim` face only fires on bare `?` / bare
      `-` / trailing `= ?`; a plain `'a` is a real annotation and
      stays full-weight.

### Interactive — inlay hints

- [ ] **Cursor in Case A's body** (any line 18–20). Run
      `M-x dimfort-toggle-inlay-hints` — `[unit]`-style ghost text
      appears after each variable use. Polymorphic vars (`x`, `y`,
      `mean`) show `['a]`; the local `half` shows `[1]`. The `'a`
      ghost text renders full-weight (no dim face — polymorphism is
      a real annotation, not unknown).
- [ ] **Cursor in Case F's body** (`r = avg_two_f(a_in, b_in)`). With
      inlays still on, `a_in`, `b_in`, `r` show `[m]` (concrete);
      same visual weight as the polymorphic case above.
- [ ] **Disable when done** — re-run `M-x dimfort-toggle-inlay-hints`.
      The QA's earlier sections assume the default (off).

### Interactive — H021 / H022 probes

- [ ] **H021 (tyvar in forbidden position)** — add a module-level
      declaration at the top of `poly_qa`:
      `real :: bad_global !< @unit{'a}`. Save. Expect an **H021
      error** on that line: type variables aren't allowed in module-
      level scope (only in routine arg lists / locals). Undo.
- [ ] **H022 probe (cannot bind tyvar to affine unit)** — change
      Case D's `a_in` annotation to `!< @unit{degC}`. Save. Expect
      an **H022 error** on the `call avg_two(a_in, b_in, out_mean)`
      site (Case D's call) stating that `'a` cannot bind to an
      affine unit and offering a fix hint to convert to the base
      unit (`K`) or pass as a delta. Type variables range over the
      multiplicative algebra only; affine units (degC, degF) inhabit
      a separate layer. Undo.

### Known gaps in this annex

- **Quick-fix coverage** — there's no Polymorphism-specific code
  action today. The existing U002 / U023 / "Add @unit{}" actions
  still apply normally on this file via `eglot-code-actions` /
  `lsp-execute-code-action`; re-run those steps from the main
  Configurable-delimiters section if needed.
- **Inlay hints** — inlay hints (eglot 1.16+/lsp-mode `lsp-inlay-hint-enable`)
  are off by default; polymorphic vars under inlays render as `'a`.
  Toggle on and walk Case D to confirm if you care about that
  surface today.
- **Cross-file polymorphism** — this scene is single-file. Add a
  separate `caller.f90` + `lib.f90` pair if cross-file lookup of a
  polymorphic signature needs verifying.

## Coverage visualisation (0.2.4)

Coverage requires the DimFort server with the `dimfort/lineStatus`
method (server PR #53 merged). The companion mode is `"disabled"` by
default; the tests below set it manually.

### Three-mode cycle

With `qa.f90` open:

- [ ] Run `M-x dimfort-cycle-coverage` once → the echo area shows
      `DimFort: coverage gutter`. Confirm:
      - **Green fringe dots** on annotated-declaration lines
        (`real :: c_sound  !< @unit{m/s}` etc.) and on clean
        expression lines (`d = c_sound * t`, `q = 0.5 * rho * v * v`,
        the `combo`, `ln_p`, `rt_e2` calculations).
      - **Yellow fringe dots** on `t_celsius`'s declaration (U005)
        and on the `t_celsius = t - 273.15` line (H010 D1.5). With
        U005 propagation (server PR #55), every other line
        referencing `t_celsius` also paints yellow.
      - **Red fringe dot** on the `bogus = c_sound * t` line (H001).
      - Out-of-scope lines (`module`, `contains`, `end function`,
        `end subroutine`, `end module`, blank lines, comment-only
        lines) carry no fringe decoration.
- [ ] Run `M-x dimfort-cycle-coverage` again → echo area shows
      `DimFort: coverage background`. Confirm:
      - The fringe dots are gone.
      - Each in-scope line carries a low-alpha background tint in
        the matching tier colour. `gutter` and `background` are
        mutually exclusive — pick the visual weight you prefer.
- [ ] Run `M-x dimfort-cycle-coverage` a third time → echo area
      shows `DimFort: coverage disabled`. All coverage decorations
      clear.

### U005 propagation regression (PR #55)

- [ ] In `gutter` mode, delete `@unit{s}` from the `t` declaration
      line. Save the buffer. Wait for the post-save refresh
      (~500 ms after the server's check). Confirm:
      - The `bogus = c_sound * t` line goes red → **yellow** (must
        NOT turn green — `t` is now unannotated and propagates
        yellow to every use site).
      - The `d = c_sound * t` line also paints yellow.
      - Restore the annotation; the lines should revert to red /
        green respectively.

### No LSP restart on mode flip

- [ ] Note the active server (`M-x eglot-events-buffer` shows the
      server name and id; or `M-x lsp-describe-session` for
      lsp-mode).
- [ ] Cycle the coverage mode three times.
- [ ] Re-check the server view — the same server should be active
      (no restart). Cycling other settings such as hover via
      `M-x dimfort-cycle-hover` DOES restart the server; this
      contrast is the verification.

### Face customisation

- [ ] After cycling to `gutter` mode, override one of the tier
      colours:
      `M-x customize-face RET dimfort-coverage-green` →
      change `:foreground` to a new colour. Save. The green fringe
      dots should repaint on the next refresh.
- [ ] Same for background: cycle to `background` mode and
      customise `dimfort-coverage-bg-green`'s `:background`. The
      tint should refresh after the next edit.
