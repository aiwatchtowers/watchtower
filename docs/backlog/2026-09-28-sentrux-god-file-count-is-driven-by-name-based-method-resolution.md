---
type: chore
title: Sentrux god-file count is driven by name-based method resolution
status: open
priority: med
tags: [ci, sentrux, quality-gate, false-positive]
context: PR #6 (fix/backlog-desktop-wave1) — Sentrux Quality Gate failed after merging main (god files 76 -> 96)
created: 2026-09-28
---

`sentrux gate`'s god-file count (fan-out > 15) is not a property of the file
being measured. Sentrux resolves an unresolved method call by its bare name to
whichever file declares a method of that name, so every `array.append(...)` or
`x.flush()` in the Desktop tree becomes a dependency edge on some file that
happens to declare `func append` / `func flush`.

Measured on PR #6 merged with main (commit 5f43477f):
- PR #6 alone: 73; main alone: 76; the merge: 96.
- Bisecting the PR's 42 changed Swift files, only reverting
  `WatchtowerDesktop/Sources/App/OnboardingView.swift` moves the count
  (96 -> 78). The PR deleted a private `LineBuffer` class there (moved to the
  shared `ProcessPipes` helper) that declared `append(_:)`, `flush()` and
  `allText`.
- Appending a dummy private class with just those three members back to that
  file restores 78; `append` alone gives 81, `flush` alone 94.

So OnboardingView was acting as an accidental "sink" for every generic
`append`/`flush` call; once it's gone, those calls resolve to the files the
chat redesign added (`ChatSessionClient`, `NDJSONLineSplitter`,
`ChatSearchQueries`, `ProjectDetailViewModel`…) and ~20 unrelated files
(e.g. `OCRRecognizer.swift`, `CodeHighlighter.swift`) cross the threshold
without a single edit. A PR that removes duplicated code is punished; one that
adds a `func append` somewhere can silently "fix" the count.

Options:
- Make the blocking gate ignore the global god-file count and rely on
  `scripts/god-files.sh` (source roster at fan-out > 30) — still the same
  resolver, but far less sensitive at that threshold.
- Check whether sentrux can exclude generic member names / stdlib-shadowing
  names from call resolution, or count only import/type edges for fan-out.
- At minimum document in `scripts/god-files.sh`'s header that a count jump
  caused by removing a definition is resolver noise, with this bisect recipe,
  so a re-snapshot can be justified with evidence rather than by default.

> Original note: owner asked to investigate why merging PR #6 inflates the god-file count by 20 instead of re-snapshotting the baseline («3»).
