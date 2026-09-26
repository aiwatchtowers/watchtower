# Sidebar Reorganization — Design

**Date:** 2026-06-27
**Component:** WatchtowerDesktop — `SidebarView` / `SidebarDestination`
**Goal:** The sidebar has grown to 16 flat main items (+3 in TOOLS), reading as a wall of icons. Reorganize into a smaller set of always-visible root items plus collapsible, named sections so the default view shows ~8 entries instead of 16.

## Problem

`SidebarDestination.mainItems` renders all 16 destinations flat, top to bottom. Frequent destinations (Targets, Tracks) sit visually equal to rarely-opened analytical views (Project Map, Releases, Workload, Digests). Nothing is grouped, nothing collapses.

## Approach (chosen)

Hybrid: **group + reduce visible surface**.

- A few high-frequency destinations stay at the **root** (always visible, ungrouped).
- The rest move into **named, collapsible sections** (`DisclosureGroup`), with the low-frequency sections collapsed by default.
- No destinations are removed and no screens are merged — every existing `SidebarDestination` case and its view mapping in `Navigation.swift` stay intact.

### Target layout

```
  AI Chat            (root)
  Targets    13      (root)
  Tracks      6      (root)

  ▾ TODAY                         (expanded by default)
      Catch Up · Briefings · Day Plan · Inbox · Calendar
  ▸ DELIVERY        (badge)       (collapsed by default)
      Project Map · Releases · Blockers · Workload
  ▸ ANALYTICS       1310          (collapsed by default)
      Digests · People · Statistics

  ─── TOOLS ───                   (unchanged, flat)
      Search · Boards · Usage · Training
```

Section titles in code are English (`TODAY`, `DELIVERY`, `ANALYTICS`) to match existing `TOOLS`.

## Components

### 1. `SidebarSection` (new)

New enum describing the collapsible groups and their membership. Becomes the source of truth for ordering; `SidebarDestination.mainItems` is removed.

```swift
enum SidebarSection: String, CaseIterable, Identifiable {
    case today
    case delivery
    case analytics

    var id: String { rawValue }
    var title: String { ... }                 // "TODAY" / "DELIVERY" / "ANALYTICS"
    var items: [SidebarDestination] { ... }
    var collapsedByDefault: Bool { ... }      // today: false; delivery/analytics: true
}
```

- `today.items` = `[.catchUp, .briefings, .dayPlan, .inbox, .calendar]`
- `delivery.items` = `[.projectMap, .releases, .blockers, .workload]`
- `analytics.items` = `[.digests, .people, .statistics]`

### 2. Root items (new constant on `SidebarDestination`)

```swift
static var rootItems: [Self] { [.chat, .targets, .tracks] }
```

Rendered above the sections, always visible, using the existing `sidebarButton`.

### 3. `SidebarDestination` changes

- Remove `static var mainItems`.
- Add `static var rootItems`.
- `toolItems` unchanged (`.boards`, `.usage`, `.training`). `.search` stays in TOOLS as today.
- `title` / `icon` cases unchanged.

### 4. `SidebarView` changes

- Render `rootItems` first (loop over `sidebarButton`).
- For each `SidebarSection`, render a `DisclosureGroup`:
  - Label = section header (uppercase caption style matching current `TOOLS` label) + collapsed-state badge.
  - Content = `ForEach(section.items)` of `sidebarButton`.
  - `isExpanded` bound to `@AppStorage("sidebar.section.<id>.collapsed")` (inverted), so expand/collapse survives relaunch. Initial value from `section.collapsedByDefault`.
- TOOLS section, calendar/Jira/update indicators, and `SidebarProgressView` stay as-is.
- `sidebarButton` and `badgeCount(for:)` are unchanged — only their placement (inside disclosure content) changes.

### 5. Collapsed-section header badge

Helper on `SidebarView`:

```swift
private func sectionBadgeCount(_ section: SidebarSection) -> Int   // sum of item badge counts
private func sectionBadgeColor(_ section: SidebarSection) -> Color // loudest child: red > orange > blue
```

- Reuses the same per-item count switch already in `badgeCount(for:)` (extract a small `count(for:)` Int helper so header and item share one source).
- Header badge shown **only when the section is collapsed** and the sum > 0. When expanded, individual item badges are visible instead.
- Color precedence mirrors existing item coloring: any red child → red; else orange (tracks) → orange; else blue → blue; else red default. (In practice Delivery has no badged items today → no badge; Analytics → red, dominated by Digests.)

## Data flow

No DB or query changes. All badge data continues to flow from `SidebarCountsViewModel` (unchanged). The header badge is a pure aggregation of values the view model already exposes.

## State / persistence

- Per-section collapsed state in `@AppStorage`, keyed `sidebar.section.today.collapsed`, etc.
- Defaults applied via the `collapsedByDefault` seed on first launch (AppStorage default value = `collapsedByDefault`).
- Selection model (`@Binding var selection: SidebarDestination`) unchanged. Selecting an item inside a collapsed section is still possible via search/keyboard; default UX is the user expands the section first. (No auto-expand-on-select in v1 — YAGNI; revisit if it feels wrong.)

## Error handling

None new — pure view-layer reshaping over existing data. Missing/zero counts already render as "no badge".

## Testing

The sidebar is view-layer SwiftUI with no existing unit tests for layout. Add lightweight model-level tests:

- `SidebarSectionTests`: every `SidebarDestination` (except `rootItems` + `toolItems`) belongs to exactly one section; union of `rootItems + section.items (all) + toolItems` == `SidebarDestination.allCases` with no duplicates. This guards against a destination silently disappearing from the sidebar.
- `collapsedByDefault` returns the expected flags.

Manual verification: launch app, confirm Today expanded / Delivery+Analytics collapsed on first run, collapse state persists across relaunch, collapsed headers show aggregate badges with correct color, all destinations reachable.

## Out of scope (YAGNI)

- Merging the 4 Delivery views into one tabbed screen (considered, rejected — keep as 4 items in a collapsed section).
- Drag-to-reorder / user-customizable sections.
- Auto-expanding a section when one of its items is selected programmatically.
