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
    real :: t_celsius                  ! no annotation -> U005
    d         = c_sound * t            ! OK:   m = (m·s⁻¹)*s
    bogus     = c_sound * t            ! H001: kg = m  (mismatch)
    t_celsius = t - 273.15             ! H010: bare 273.15 literal
    combo     = c_sound**2 + d * d / (t * t) - c_sound * c_sound
                                           !       (exercises +, -, *, /, **; all m²/s²)
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

- [ ] **Line 18** — `t_celsius` (no annotation) → **U005 warning**: the
      name `t_celsius` in bold orange, orange `!` in the fringe.
- [ ] **Line 20** — `bogus = c_sound * t` → **H001 error** `kg ≠ m`: the
      whole assignment in bold red, red `!!` in the fringe.
- [ ] **Line 21** — `t_celsius = t - 273.15` → **H010 warning** on the
      `273.15` literal (suggests extracting it to a named PARAMETER).
- [ ] Lines 19, 22, and 24 are **clean** — no diagnostic (the assignments are
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
      `c_sound : m·s⁻¹`. On the product `c_sound * t` (line 19) → the
      tree shape used by every short hover:

      ```
      🟢 DimFort
      c_sound * t  :  m       🟢
      ├── c_sound  :  m·s⁻¹   🟢
      └── t        :  s       🟢
      ```

- [ ] **Binary operators** — on **line 22** (the `combo = …`
      assignment), hover each of `+`, `-`, `*`, `/`, `**` in turn. Each
      renders the same tree shape (root sub-expression + immediate
      operand rows); every row is 🟢; the topmost `**` shows
      `c_sound**2 : m²·s⁻²` over its operand rows. One fixture
      exercises every binary operator.

- [ ] **Detailed** — cycle once more to `detailed`. For bare-identifier
      operands like `c_sound * t` the layout is unchanged from short
      (nothing to expand). For the **call** `dynamic_pressure`
      (line 24), Detailed adds a sub-tree under the computed
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
      `scale_pressure` (line 25). Same tree layout as a function call,
      **but the root has no return unit** so it reads
      `call scale_pressure(…) : ? 🟡`. Argument row
      `2.0 * ref_pressure : kg·m⁻¹·s⁻² 🟢` with the sub-tree beneath.

- [ ] Cycle once more → back to `disabled`; hovers go silent again.

## Inlay hints

- [ ] `M-x dimfort-toggle-inlay-hints` → `[m·s⁻¹]`-style ghost text appears
      after variable uses. Run it again → the ghost text disappears.

## Code actions

`M-x eglot-code-actions` with point on the relevant line.

- [ ] On `t_celsius` (line 18) → **"add `@unit{}`"**. Applying inserts
      `!< @unit{}` and leaves point **between the braces**.
- [ ] On the `273.15` (line 21) → **"extract literal to PARAMETER"**.
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

- [ ] **Assignment with a mismatch** — put point on the **`=`** in line 20
      (`bogus = c_sound * t`). The whole assignment renders, marked 🔴
      because `kg ≠ m`:

      ```
      Expression

      bogus = c_sound * t      🔴
      ├── bogus       : kg     🟢
      └── c_sound * t : m      🟢
          ├── c_sound : m·s⁻¹  🟢
          └── t       : s      🟢
      ```

      (Rule IDs like `(R4.2)` are no longer rendered on tree rows.)

- [ ] **Multiplication chain** — point on the **`=`** in line 10
      (`q = 0.5 * rho * v * v`). The product nests, every step 🟢, the
      root resolving to `kg·m⁻¹·s⁻²`:

      ```
      q = 0.5 * rho * v * v               🟢
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
      `dynamic_pressure` in line 24. The call resolves to its result unit,
      and the computed argument breaks down beneath it:

      ```
      dynamic_pressure(0.5 * c_sound) : kg·m⁻¹·s⁻²  🟢
      └── 0.5 * c_sound               : m·s⁻¹       🟢
          ├── 0.5                     : 1           🟢
          └── c_sound                 : m·s⁻¹       🟢
      ```

- [ ] **Subroutine call** — point on the call name `scale_pressure` in
      line 25. A subroutine has no return unit, so the root carries none
      (🟡), but the computed argument still expands beneath it:

      ```
      call scale_pressure(2.0 * ref_pressure)              🟡
      └── 2.0 * ref_pressure                  : kg·m⁻¹·s⁻²  🟢
          ├── 2.0                             : 1           🟢
          └── ref_pressure                    : kg·m⁻¹·s⁻²  🟢
      ```

- [ ] **Call-arg expected on mismatch** — temporarily edit line 24 to
      `ref_pressure = dynamic_pressure(c_sound * t)`. The Expression
      tree's argument row now shows
      `c_sound * t : m 🔴 (expected m·s⁻¹)`, surfacing the formal unit the
      call-site demanded. Revert the edit when done.

- [ ] **Stacked scopes** — with point in line 10 (inside the function),
      the Scope section stacks the module over the function, indented by
      nesting (no column header — the row is `line · name · unit · mark`):

      ```
      Module: qa_mod

        2     c_sound       m·s⁻¹ 🟢
        3     ref_pressure  Pa    🟢

        Function: dynamic_pressure

          6     v    m·s⁻¹  🟢
          7     q    Pa     🟢
          8     rho  kg/m^3 🟢
      ```

- [ ] **Markers** — in `checks` (e.g. point in line 20), `t_celsius` shows
      🟡 (unannotated). With a `@unit{??}` somewhere in scope, that
      variable shows 🔴 (annotated but unparseable).

- [ ] **Cursor-follow** — move point between line 10 (function) and line 20
      (subroutine); the Scope section switches between `Function:
      dynamic_pressure` and `Subroutine: checks` accordingly.

### Panel — Diagnostics / Interactions / Actions (the `both` layout)

These three sections sit between Expression and Scope. Each is always
present, showing `(none)` when nothing applies, so they don't pop in and
out as point moves.

- [ ] **Diagnostics** — point on line 20 (`bogus = c_sound * t`); the
      Diagnostics section shows **🔴 H001: …**. On line 18 (`t_celsius`) it
      shows **🟡 U005: …**. On a clean line (18) it shows `(none)`. `RET`
      on a diagnostic row jumps to that span.
- [ ] **Interactions** — point on a `c_sound` use (line 19). The
      Interactions section shows the symbol `c_sound`, then the
      **Declaration** group (line 2) and **Read** group (its use sites),
      each row `file:line   unit` with the snippet beneath. `RET` on a site
      jumps there (cross-file when the site is elsewhere). Because
      `c_sound` is read as `m·s⁻¹` at lines 18/21 but `kg/s` at line 20, a
      **🔴 X001** conflict row sits at the top.
- [ ] **Actions** — point on `t_celsius` (line 18) → the Actions section
      lists **• Add @unit{} to t_celsius**; `RET` on it inserts `!< @unit{}`
      with point between the braces. Point anywhere on line 21 (the H010
      line) → **• Extract literal '273.15' into a named PARAMETER (s)**;
      `RET` prompts for a name and applies the refactor.
- [ ] **Footer** — the panel's last line reads `File: 🔴 N   🟡 N`.

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
  real :: play   !< @unit{Pa}
  real :: phpa   !< @unit{hPa}
  real :: t_k    !< @unit{K}
  real :: t_c    !< @unit{degC}
contains
  subroutine s()
    phpa = play        ! S001: hPa vs Pa (×100 multiplicative scale)
    t_k  = t_c         ! S002: K vs degC (affine offset)
  end subroutine s
end module scale_qa
```

- [ ] **Auto (default)** — with `dimfort-scale-mode` = `"auto"` and no
      `.dimfort.toml`, the file is **clean** (no S001/S002).
- [ ] **On** — `M-x dimfort-cycle-scale` until the echo area says
      `scale checking -> on` (the server restarts): `phpa = play` →
      **S001** and `t_k = t_c` → **S002** (yellow), the panel circles 🟡.
- [ ] **Off / Auto** — cycle again to `off` (forced clean even if a toml
      enabled it), once more to `auto` (back to deferring to the toml).

## Imports section

Save this `imports_qa.f90` and open it (one file, two modules — the
second `use`s the first):

```fortran
module phys_constants
  real :: play   !< @unit{Pa}
  real :: grav   !< @unit{m·s⁻¹^2}
contains
  function gravity_at(h) result(g)
    real, intent(in) :: h   !< @unit{m}
    real             :: g   !< @unit{m·s⁻¹^2}
    g = grav
  end function gravity_at
end module phys_constants

module solver
  use phys_constants, only: play, gravity_at
  real :: local_p   !< @unit{Pa}
contains
  subroutine step()
    local_p = play
  end subroutine step
end module solver
```

- [ ] **Lists vars + procedures** — point on `local_p = play` (inside
      `step`): the **Imports** section shows a `from phys_constants` header
      with two indented rows — `play  kg·m⁻¹·s⁻² 🟢` and
      `gravity_at(m)  m·s⁻² 🟢` (its `(m)` argument unit in the parens, its
      `m·s⁻²` return unit in the column).
- [ ] **Cross-file navigation** — `RET` on `play` jumps to its declaration
      (line 2); `RET` on `gravity_at(m)` jumps to the function definition
      (line 5). Same file here; the source module's file in a real project.
- [ ] **Scoped + shadowed** — `grav` is **not** listed (the `only:` list
      excludes it). Add `real :: play !< @unit{Pa}` as a local in `step`
      and `play` drops from Imports (the local shadows it; it shows under
      Scope instead).
- [ ] **Imports filter** — `M-x dimfort-imports-filter RET gravity RET`
      narrows the Imports section to `gravity_at(m)`; `play` to `play`;
      empty clears it. Independent of `dimfort-scope-filter` (Scope).
- [ ] **Empty case** — point in `phys_constants` (imports nothing): the
      Imports section shows `(none)`.
