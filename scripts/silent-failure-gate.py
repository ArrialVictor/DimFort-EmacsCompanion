#!/usr/bin/env python3
"""Silent-failure regression gate (Elisp).

Last of the four cross-language gates. Elisp's silent-failure
shapes are:

  - ``(ignore-errors ...)``           — swallows all errors
  - ``(condition-case nil ...)``      — handler is nil → swallows
  - ``(condition-case-unless-debug nil ...)`` — same shape

A `(condition-case err ... (error <handler>))` with a non-nil
handler that does something (message, signal, etc.) is NOT a
silent-failure pattern.

This gate is **diff-aware only**. Pre-audit un-annotated usages
are widespread and many are legitimately silent (cleanup paths,
teardown idempotency) — the audit didn't try to annotate them
exhaustively. Hard-banning would block CI on legacy code.

Diff-aware annotation requirement
---------------------------------
A new line containing ``(ignore-errors`` or ``(condition-case nil``
or ``(condition-case-unless-debug nil`` must carry an
``audited(0.2.X)`` annotation within ±5 lines.

Exit codes
----------
0  Gate passes.
1  One or more findings; details printed to stderr.

Usage
-----
::

    BASE_REF=origin/main python scripts/silent-failure-gate.py
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANNOTATION = re.compile(r"audited\(0\.2\.\d+\)")
WINDOW = 5  # lines of context to search for the annotation

# Silent-shape patterns to require annotation for, when newly added.
SILENT_PATTERNS = [
    (re.compile(r"\(ignore-errors\b"), "(ignore-errors ...)"),
    (
        re.compile(r"\(condition-case(?:-unless-debug)?\s+nil\b"),
        "(condition-case[-unless-debug] nil ...)",
    ),
]


def annotation_findings_in_diff(base_ref: str) -> list[tuple[Path, int, str, str]]:
    cmd = [
        "git",
        "diff",
        "--unified=0",
        "--no-color",
        f"{base_ref}...HEAD",
        "--",
        "*.el",
    ]
    try:
        diff = subprocess.check_output(cmd, cwd=ROOT, text=True)
    except subprocess.CalledProcessError as exc:
        print(f"silent-failure-gate: git diff failed ({exc})", file=sys.stderr)
        sys.exit(2)

    findings: list[tuple[Path, int, str, str]] = []
    current_path: Path | None = None
    current_line = 0
    for raw in diff.splitlines():
        if raw.startswith("+++ b/"):
            current_path = ROOT / raw[6:]
        elif raw.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", raw)
            if m:
                current_line = int(m.group(1)) - 1
        elif raw.startswith("+") and not raw.startswith("+++"):
            current_line += 1
            line = raw[1:]
            for pat, desc in SILENT_PATTERNS:
                if pat.search(line):
                    if current_path is None or not current_path.exists():
                        continue
                    text = current_path.read_text(encoding="utf-8")
                    lines = text.splitlines()
                    lo = max(0, current_line - 1 - WINDOW)
                    hi = min(len(lines), current_line + WINDOW)
                    window = "\n".join(lines[lo:hi])
                    if not ANNOTATION.search(window):
                        findings.append(
                            (current_path, current_line, desc, line.strip())
                        )
        elif raw.startswith(" "):
            current_line += 1

    return findings


def main() -> int:
    base_ref = os.environ.get("BASE_REF")
    if not base_ref:
        # No base ref — push-to-main or local invocation without
        # diff context. Gate has nothing to check; exit clean.
        print("silent-failure-gate: OK (no BASE_REF; diff-aware only)")
        return 0

    failures = annotation_findings_in_diff(base_ref)
    if not failures:
        print("silent-failure-gate: OK")
        return 0

    print(
        "silent-failure-gate: FAILED — the following patterns regress the "
        "0.2.7 silent-failure audit:",
        file=sys.stderr,
    )
    for path, lineno, desc, content in failures:
        rel = path.relative_to(ROOT)
        truncated = content if len(content) <= 100 else content[:97] + "..."
        print(f"  {rel}:{lineno}  [new {desc} without `audited(0.2.X)` "
              f"annotation within ±5 lines]", file=sys.stderr)
        print(f"    {truncated}", file=sys.stderr)
    print(
        "\nFix: either (a) replace the silent shape with a "
        "`(condition-case err ...)` that handles the error (logs, "
        "surfaces via `display-warning`, etc.), or (b) document why "
        "the failure is silent-OK with `audited(0.2.X): silent-OK — "
        "<reason>` in a comment near the form.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
