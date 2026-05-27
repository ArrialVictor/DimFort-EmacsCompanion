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
    real :: t_celsius                  ! no annotation -> U005
    d         = c_sound * t            ! OK:   m = (m/s)*s
    bogus     = c_sound * t            ! H001: kg = m  (mismatch)
    t_celsius = t - 273.15             ! H010: bare 273.15 literal
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

- [ ] **Line 17** — `t_celsius` (no annotation) → **U005 warning**: the
      name `t_celsius` in bold orange, orange `!` in the fringe.
- [ ] **Line 19** — `bogus = c_sound * t` → **H001 error** `kg ≠ m`: the
      whole assignment in bold red, red `!!` in the fringe.
- [ ] **Line 20** — `t_celsius = t - 273.15` → **H010 warning** on the
      `273.15` literal (suggests extracting it to a named PARAMETER).
- [ ] Lines 18 and 21 are **clean** — no diagnostic (the assignments are
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

- [ ] **Short (default)** — on **`c_sound`**:

      ```
      🟢 DimFort
      c_sound : m/s
      ```

      and on the product `c_sound * t` (line 18), one compact line:

      ```
      🟢 DimFort
      c_sound * t : m
      ```

- [ ] **Detailed** — cycle once more to `detailed`. The same product now
      breaks down across lines:

      ```
      🟢 DimFort
      c_sound * t : m
        🟢  c_sound : m/s
        🟢  t       : s
      ```

      and the **call** `dynamic_pressure` (line 21) gains a sub-tree under
      its computed argument (`0.5 * c_sound`) — the difference from Short,
      which lists only the formal-vs-actual pairing:

      ```
      🟢 DimFort
      dynamic_pressure : Pa
        🟢  v : m/s   ◂   0.5 * c_sound : m/s
              0.5     : 1
              c_sound : m/s
      ```

      (On Short the same call shows just the `v : m/s ◂ 0.5 * c_sound : m/s`
      row, no sub-tree.)

- [ ] **Subroutine call** — still in `detailed`, hover the call name
      `scale_pressure` (line 22). Same formal-vs-actual layout as a
      function call, **but no return unit in the header** (subroutines
      don't return): `p : Pa ◂ 2.0 * ref_pressure : Pa`, with the argument
      sub-tree beneath.

- [ ] Cycle once more → back to `disabled`; hovers go silent again.

## Inlay hints

- [ ] `M-x dimfort-toggle-inlay-hints` → `[m/s]`-style ghost text appears
      after variable uses. Run it again → the ghost text disappears.

## Code actions

`M-x eglot-code-actions` with point on the relevant line.

- [ ] On `t_celsius` (line 17) → **"add `@unit{}`"**. Applying inserts
      `!< @unit{}` and leaves point **between the braces**.
- [ ] On the `273.15` (line 20) → **"extract literal to PARAMETER"**.
      Applying prompts for a name, then inserts a typed `real, parameter`
      declaration and replaces the `273.15` with the new name.

## Navigation & completion

- [ ] `M-.` (`xref-find-definitions`) on a `c_sound` use → jumps to its
      declaration on line 2.
- [ ] Type a new `!< @unit{` and invoke completion (`C-M-i`) → unit names
      are offered.

## Side panel

`M-x dimfort-panel-toggle` opens it on the right. The panel follows the
cursor (≈0.2 s debounce) and dims briefly while it refreshes.

- [ ] **Assignment with a mismatch** — put point on the **`=`** in line 19
      (`bogus = c_sound * t`). The whole assignment renders, marked 🔴
      because `kg ≠ m`:

      ```
      Expression

      bogus = c_sound * t        🔴
      ├── bogus           : kg   🟢
      └── c_sound * t     : m    🟢 (R4.2)
          ├── c_sound     : m/s  🟢
          └── t           : s    🟢
      ```

- [ ] **Multiplication chain** — point on the **`=`** in line 10
      (`q = 0.5 * rho * v * v`). The product nests, each step tagged with
      its rule:

      ```
      q = 0.5 * rho * v * v              🟢
      ├── q                 : kg/(m×s²)  🟢
      └── 0.5 * rho * v * v : kg/(m×s²)  🟢 (R4.2)
          ├── 0.5 * rho * v : kg/(m²×s)  🟢 (R4.2)
          │   ├── 0.5 * rho : kg/m³      🟢 (R4.2)
          │   │   ├── 0.5   : 1          🟢
          │   │   └── rho   : kg/m³      🟢
          │   └── v         : m/s        🟢
          └── v             : m/s        🟢
      ```

- [ ] **Function call with arguments** — point on the call name
      `dynamic_pressure` in line 21. The call resolves to its result unit,
      and the computed argument breaks down beneath it:

      ```
      dynamic_pressure(0.5 * c_sound) : kg/(m×s²)  🟢
      └── 0.5 * c_sound               : m/s        🟢 (R4.2)
          ├── 0.5                     : 1          🟢
          └── c_sound                 : m/s        🟢
      ```

- [ ] **Subroutine call** — point on the call name `scale_pressure` in
      line 22. A subroutine has no return unit, so the root carries none
      (🟡), but the computed argument still expands beneath it:

      ```
      call scale_pressure(2.0 * ref_pressure)              🟡
      └── 2.0 * ref_pressure                  : kg/(m×s²)  🟢 (R4.2)
          ├── 2.0                             : 1          🟢
          └── ref_pressure                    : kg/(m×s²)  🟢
      ```

- [ ] **Stacked scopes** — with point in line 10 (inside the function),
      the Scope section stacks the module over the function, indented by
      nesting (no column header — the row is `line · name · unit · mark`):

      ```
      Module: qa_mod

        2     c_sound       m/s  🟢
        3     ref_pressure  Pa   🟢

        Function: dynamic_pressure

          6     v     m/s    🟢
          7     q     Pa     🟢
          8     rho   kg/m^3 🟢
      ```

- [ ] **Markers** — in `checks` (e.g. point in line 19), `t_celsius` shows
      🟡 (unannotated). With a `@unit{??}` somewhere in scope, that
      variable shows 🔴 (annotated but unparseable).

- [ ] **Cursor-follow** — move point between line 10 (function) and line 19
      (subroutine); the Scope section switches between `Function:
      dynamic_pressure` and `Subroutine: checks` accordingly.

### Panel — Diagnostics / Interactions / Actions (the `both` layout)

These three sections sit between Expression and Scope. Each is always
present, showing `(none)` when nothing applies, so they don't pop in and
out as point moves.

- [ ] **Diagnostics** — point on line 19 (`bogus = c_sound * t`); the
      Diagnostics section shows **🔴 H001: …**. On line 17 (`t_celsius`) it
      shows **🟡 U005: …**. On a clean line (18) it shows `(none)`. `RET`
      on a diagnostic row jumps to that span.
- [ ] **Interactions** — point on a `c_sound` use (line 18). The
      Interactions section shows the symbol `c_sound`, then the
      **Declaration** group (line 2) and **Read** group (its use sites),
      each row `file:line   unit` with the snippet beneath. `RET` on a site
      jumps there (cross-file when the site is elsewhere). Because
      `c_sound` is read as `m/s` at lines 18/21 but `kg/s` at line 19, a
      **🔴 X001** conflict row sits at the top.
- [ ] **Actions** — point on `t_celsius` (line 17) → the Actions section
      lists **• Add @unit{} to t_celsius**; `RET` on it inserts `!< @unit{}`
      with point between the braces. Point anywhere on line 20 (the H010
      line) → **• Extract literal '273.15' into a named PARAMETER (s)**;
      `RET` prompts for a name and applies the refactor.
- [ ] **Footer** — the panel's last line reads `File: 🔴 N   🟡 N`.

### Panel — Scope filter

- [ ] `M-x dimfort-panel-filter RET Pa RET` → the Scope section keeps only
      variables whose name or unit matches `Pa` (e.g. `ref_pressure`, `q`),
      with a `Filter: "Pa"` header; scopes with no surviving variables are
      hidden. `M-x dimfort-panel-filter RET RET` (empty) clears it.

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
  real :: grav   !< @unit{m/s^2}
end module phys_constants

module solver
  use phys_constants, only: play
  real :: local_p   !< @unit{Pa}
contains
  subroutine step()
    local_p = play
  end subroutine step
end module solver
```

- [ ] **Lists the import** — point on `local_p = play` (line 11): the
      **Imports** section shows a `use phys_constants` header with one row,
      `play  kg/(m×s²) 🟢`.
- [ ] **Cross-file navigation** — `RET` on the `play` row jumps to its
      declaration in `phys_constants` (line 2; same file here, the source
      module's file in a real project).
- [ ] **Scoped + shadowed** — `grav` is **not** listed (the `only:` list
      excludes it). Add `real :: play !< @unit{Pa}` as a local in `step`
      and `play` drops from Imports (the local shadows it; it shows under
      Scope instead).
- [ ] **Empty case** — point in `phys_constants` (imports nothing): the
      Imports section shows `(none)`.
