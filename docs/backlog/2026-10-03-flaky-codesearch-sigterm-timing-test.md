---
type: bug
title: Flaky cmd test TestCodeSearch_SIGTERMMidRunExitsAtOnceWithNoDone (50 ms wall-clock bound)
status: done
resolution: SIGTERM bounds of the code search and code index tests relaxed to 500 ms (target ~50 ms), behavioural checks kept; the Swift query-latency test likewise to 300 ms
priority: med
tags: [ci, flaky-test, codesearch, cmd]
context: PR #152 (OWNER-01 variant A) — Go Test failed on CI although the PR touches no Go; passed on rerun
created: 2026-10-03
---

`cmd/code_test.go` `TestCodeSearch_SIGTERMMidRunExitsAtOnceWithNoDone` (from code navigation, PR #149)
asserts the `code search` process exits within 50 ms of SIGTERM. On a loaded CI runner it measured
71 ms (`exited 71.114634ms after SIGTERM, want ≤ 50ms`) and failed an unrelated PR; a rerun passed.

A tight wall-clock threshold on a shared runner will keep failing other PRs at random. Fix: keep the
behavioural assertions (exits promptly, prints no `done` line, non-zero/expected exit) but relax the
bound substantially (e.g. ≤ 500 ms) or measure relative to a baseline instead of an absolute 50 ms.

> Original note: «закидывай» (owner, 2026-10-03, after the flaky failure on PR #152)
