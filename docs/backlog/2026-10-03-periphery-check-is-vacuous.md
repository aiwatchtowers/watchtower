---
type: bug
title: make periphery-check passes without checking anything
status: open
priority: med
tags: [build, periphery, release-check, makefile]
context: main — noticed in the make release-check run for v0.14.0
created: 2026-10-03
---

`make periphery-check` (part of `make release-check`) is vacuous. The count is
taken with `grep -cE "warning:" || echo 0`: on zero matches `grep -c` prints `0`
and exits 1, so `|| echo 0` appends a second `0`. `current` becomes "0\n0", the
`[ "$current" -gt "$baseline" ]` test fails with "integer expression expected",
and the recipe falls into the pass branch (`✓ Periphery: 0 ≤ baseline 340`).

The zero itself is suspicious against a baseline of 340: `periphery scan
--skip-build` most likely fails outright, and its stderr is discarded
(`2>/dev/null`), so the failure is invisible.

Fix: drop `|| echo 0` (use `|| true`), fail the recipe when the scan exits
non-zero, and stop swallowing its stderr. `periphery-baseline` has the same
pattern and would write a bogus baseline the same way.

> Original note: periphery printed `integer expression expected` and `✓ Periphery: 0 ≤ baseline 340` during release-check for v0.14.0.
