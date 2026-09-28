---
type: chore
title: Collapse the Execution and Insights sidebar sections by default
status: done
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

**Resolution:** most of the collapse/persist/badge infrastructure already
existed (per-section `UserDefaults` persistence that never overrides an
explicit owner toggle, and a collapsed-header badge). The actual bug was that
`SidebarSection.collapsedByDefault` returned `true` unconditionally, so FOCUS
(the everyday section) was ALSO collapsed by default — changed to
`self != .today`, so only EXECUTION and INSIGHTS start collapsed. Added the
missing piece: navigating to a destination inside a currently-collapsed
section (deep link, notification, an action card's "Open") now expands that
section via a new pure `SidebarSection.containing(_:)` lookup and
`SidebarView.expandingSection(for:in:)`, wired through the sidebar's existing
`onChange(of: selection)`.

Tests: `SidebarSectionTests.testCollapsedByDefault` (updated to the new
per-section default), `testContainingReturnsTheOwningSection`,
`testContainingIsNilForRootAndToolItems`,
`testExpandingSectionExpandsACollapsedSection`,
`testExpandingSectionNilWhenAlreadyExpanded`,
`testExpandingSectionNilWhenDestinationHasNoSection`,
`testExpandingSectionNilWhenMapHasNoEntryForTheSection`.
