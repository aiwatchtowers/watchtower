---
type: chore
title: Collapse the Execution and Insights sidebar sections by default
status: open
priority: low
tags: [desktop, sidebar, navigation, defaults]
context: fix/settings-storage-size-off-main — owner screenshot of the main sidebar
created: 2026-09-28
---

The main sidebar's EXECUTION (Project Map, Releases, Blockers, Workload) and
INSIGHTS (Digests, People, Memory, Statistics) sections are expanded by
default. Make both start collapsed, keeping the everyday sections expanded.

Details to respect:
- Default only: once the owner expands or collapses a section, remember that
  choice across launches (per-viewer UI state, e.g. `@AppStorage`), and do not
  override it on upgrade for someone who already toggled it.
- A collapsed section should still surface its badges (Digests / Statistics
  counts) on the section header, so unread counts stay visible.
- Navigating to a tab inside a collapsed section (deep link, notification,
  "Open" from an action card) should expand that section or at least show the
  selection.

> Original note: «эксекьюшин и инсайты по умолчанию сворачивать»
