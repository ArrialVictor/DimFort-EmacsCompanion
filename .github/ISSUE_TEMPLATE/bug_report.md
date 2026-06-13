---
name: Bug report
about: A wrong unit verdict, a crash, a panel/hover glitch, or unexpected behaviour
title: ""
labels: bug
---

<!-- The Emacs companion is a thin LSP client (eglot-based); many bugs are
     actually in the DimFort server. The version block helps route the report. -->

**DimFort server version**: <!-- `dimfort --version` -->
**Emacs companion version**: <!-- `;; Version:` header at the top of dimfort.el -->
**Emacs version**: <!-- `M-x emacs-version` -->
**OS**: <!-- macOS 14 / Ubuntu 24.04 / … -->

**What happened**
<!-- What you saw versus what you expected — a wrong diagnostic, a hover
     popup that's wrong/missing, a panel section glitch, a crash. -->

**Minimal reproducer**
<!-- The smallest Fortran snippet (with the relevant @unit annotations)
     that shows it. A few lines is ideal. -->

```fortran

```

**LSP trace** (very helpful)
<!-- Two buffers are usually decisive:
     - `M-x eglot-events-buffer` — the JSON-RPC traffic between Emacs and
       the DimFort server.
     - `*EGLOT … stderr*` (find with `C-x b EGLOT TAB`) — the server's
       stderr (warnings, tracebacks). -->

```

```

**Additional context**
<!-- Did this work in a previous version? Project layout / dimfort.toml
     contents if relevant. -->
