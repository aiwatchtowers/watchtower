# Sidebar Reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the Watchtower Desktop sidebar from 16 flat main items into 3 always-visible root items plus 3 named collapsible sections, with aggregate badges on collapsed section headers.

**Architecture:** Introduce a `SidebarSection` enum as the ordering source of truth (replacing `SidebarDestination.mainItems`). `SidebarView` renders `rootItems` flat, then one `DisclosureGroup` per section whose expand/collapse state persists via `@AppStorage`. Badge data is unchanged — collapsed headers show an aggregate of existing per-item counts. No DB, query, or view-model changes.

**Tech Stack:** SwiftUI (macOS 14+), Swift 5.10, SPM. Tests via XCTest in `WatchtowerDesktopTests` target. Build: `cd WatchtowerDesktop && swift build`. Test: `swift test`.

## Global Constraints

- Swift 5.10, macOS 14+ (`Package.swift`).
- No DB / query / migration changes. `SidebarCountsViewModel` is read-only here.
- Every existing `SidebarDestination` case and its mapping in `Navigation.swift` must stay reachable from the sidebar.
- Section titles in code are English uppercase to match the existing `TOOLS` label: `TODAY`, `DELIVERY`, `ANALYTICS`.
- `@AppStorage` keys: `sidebar.section.<id>.collapsed` where `<id>` ∈ `today|delivery|analytics`.
- Default expansion: `today` expanded; `delivery` and `analytics` collapsed.
- Follow existing MVVM/SwiftUI house style; reuse the existing `sidebarButton` and badge logic — do not duplicate it.

---

### Task 1: `SidebarSection` enum + `rootItems`, model-level tests

Pure model change with no view wiring yet. Establishes the source of truth and a structural-integrity test so no destination can silently vanish from the sidebar later.

**Files:**
- Create: `WatchtowerDesktop/Sources/App/SidebarSection.swift`
- Modify: `WatchtowerDesktop/Sources/App/SidebarDestination.swift` (replace `mainItems` with `rootItems`)
- Test: `WatchtowerDesktop/Tests/SidebarSectionTests.swift`

**Interfaces:**
- Consumes: existing `SidebarDestination` cases (`.chat`, `.catchUp`, `.briefings`, `.dayPlan`, `.inbox`, `.calendar`, `.targets`, `.tracks`, `.digests`, `.people`, `.workload`, `.blockers`, `.projectMap`, `.releases`, `.statistics`, `.search`, `.boards`, `.usage`, `.training`).
- Produces:
  - `enum SidebarSection: String, CaseIterable, Identifiable` with cases `today`, `delivery`, `analytics`; properties `var id: String`, `var title: String`, `var items: [SidebarDestination]`, `var collapsedByDefault: Bool`, and `static var ordered: [SidebarSection]`.
  - `SidebarDestination.rootItems: [Self]` == `[.chat, .targets, .tracks]`.
  - `SidebarDestination.toolItems` unchanged == `[.search, .boards, .usage, .training]` (see Step 2 — `.search` joins TOOLS).

- [ ] **Step 1: Write the failing test**

Create `WatchtowerDesktop/Tests/SidebarSectionTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class SidebarSectionTests: XCTestCase {

    /// Every destination appears exactly once across root + sections + tools,
    /// and every sidebar slot maps to a real destination. Guards against a
    /// destination silently disappearing from the sidebar.
    func testEveryDestinationIsPlacedExactlyOnce() {
        var seen: [SidebarDestination] = []
        seen.append(contentsOf: SidebarDestination.rootItems)
        for section in SidebarSection.ordered {
            seen.append(contentsOf: section.items)
        }
        seen.append(contentsOf: SidebarDestination.toolItems)

        // No duplicates.
        XCTAssertEqual(Set(seen).count, seen.count, "a destination is placed in more than one slot")
        // Complete coverage.
        XCTAssertEqual(Set(seen), Set(SidebarDestination.allCases), "some destination is missing from the sidebar or unknown")
    }

    func testSectionMembership() {
        XCTAssertEqual(SidebarSection.today.items, [.catchUp, .briefings, .dayPlan, .inbox, .calendar])
        XCTAssertEqual(SidebarSection.delivery.items, [.projectMap, .releases, .blockers, .workload])
        XCTAssertEqual(SidebarSection.analytics.items, [.digests, .people, .statistics])
    }

    func testRootItems() {
        XCTAssertEqual(SidebarDestination.rootItems, [.chat, .targets, .tracks])
    }

    func testCollapsedByDefault() {
        XCTAssertFalse(SidebarSection.today.collapsedByDefault)
        XCTAssertTrue(SidebarSection.delivery.collapsedByDefault)
        XCTAssertTrue(SidebarSection.analytics.collapsedByDefault)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter SidebarSectionTests`
Expected: FAIL — compile error, `SidebarSection` / `rootItems` not found.

- [ ] **Step 3: Create `SidebarSection.swift`**

Create `WatchtowerDesktop/Sources/App/SidebarSection.swift`:

```swift
import Foundation

/// Collapsible, named groups of sidebar destinations. Source of truth for the
/// order and membership of grouped items. Root items (always visible) and tool
/// items live on `SidebarDestination` instead.
enum SidebarSection: String, CaseIterable, Identifiable {
    case today
    case delivery
    case analytics

    var id: String { rawValue }

    /// Render order of the sections.
    static var ordered: [SidebarSection] { [.today, .delivery, .analytics] }

    var title: String {
        switch self {
        case .today: "TODAY"
        case .delivery: "DELIVERY"
        case .analytics: "ANALYTICS"
        }
    }

    var items: [SidebarDestination] {
        switch self {
        case .today: [.catchUp, .briefings, .dayPlan, .inbox, .calendar]
        case .delivery: [.projectMap, .releases, .blockers, .workload]
        case .analytics: [.digests, .people, .statistics]
        }
    }

    /// Whether the section starts collapsed on first launch.
    var collapsedByDefault: Bool {
        switch self {
        case .today: false
        case .delivery, .analytics: true
        }
    }
}
```

- [ ] **Step 4: Update `SidebarDestination.swift`**

In `WatchtowerDesktop/Sources/App/SidebarDestination.swift`, replace the `mainItems` computed property (currently lines 74-80) and the `toolItems` block. Replace:

```swift
    /// Main navigation items (shown above the separator).
    static var mainItems: [Self] {
        [
            .chat, .catchUp, .briefings, .dayPlan, .inbox, .calendar, .targets, .tracks,
            .digests, .people, .workload, .blockers, .projectMap, .releases, .statistics, .search
        ]
    }

    /// Tool items (shown below the separator).
    static var toolItems: [Self] {
        [.boards, .usage, .training]
    }
```

with:

```swift
    /// Always-visible items rendered above the collapsible sections.
    static var rootItems: [Self] {
        [.chat, .targets, .tracks]
    }

    /// Tool items (shown below the separator). Search lives here too.
    static var toolItems: [Self] {
        [.search, .boards, .usage, .training]
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd WatchtowerDesktop && swift test --filter SidebarSectionTests`
Expected: PASS (4 tests). If `testEveryDestinationIsPlacedExactlyOnce` fails, a destination is mis-filed — recheck membership against the spec.

- [ ] **Step 6: Verify the package still builds**

Run: `cd WatchtowerDesktop && swift build`
Expected: FAIL — `SidebarView.swift:21` still references `SidebarDestination.mainItems`. This is expected and fixed in Task 2. (Do not edit SidebarView yet; commit the model layer first so the failure is isolated to the view.)

Note: because the build breaks until Task 2, commit here is acceptable as an intermediate model-only commit — the next task immediately restores a green build.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/App/SidebarSection.swift WatchtowerDesktop/Sources/App/SidebarDestination.swift WatchtowerDesktop/Tests/SidebarSectionTests.swift
git commit -m "feat(desktop): add SidebarSection model + rootItems

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Render sections in `SidebarView` with collapsible groups + aggregate badges

Wire the model into the view: root items flat on top, a `DisclosureGroup` per section with persisted expansion, and an aggregate badge on collapsed headers. Restores a green build.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift`

**Interfaces:**
- Consumes: `SidebarDestination.rootItems`, `SidebarSection.ordered`, `section.items`, `section.title`, `section.collapsedByDefault`, `SidebarDestination.toolItems` (from Task 1). Existing `sidebarButton(_:)` and `SidebarCountsViewModel` count properties.
- Produces: refactored `badgeCount(for:)` that delegates to a new `count(for: SidebarDestination) -> Int` helper; new helpers `sectionBadgeCount(_:) -> Int`, `sectionBadgeColor(_:) -> Color`, and a `sectionView(_:) -> some View`.

- [ ] **Step 1: Extract the per-item count into a reusable helper**

In `SidebarView.swift`, the count switch currently lives inline inside `badgeCount(for:)` (lines 140-151). Pull it out so the header badge can reuse it. Add this method (place it right after `badgeCount(for:)`):

```swift
    /// The numeric badge value for a single destination (0 = no badge).
    /// Shared by the per-item badge and the collapsed-section aggregate badge.
    private func count(for item: SidebarDestination) -> Int {
        switch item {
        case .catchUp: catchUpTotalCount
        case .briefings: unreadBriefingCount
        case .inbox: inboxPendingCount
        case .targets: overdueTaskCount > 0 ? overdueTaskCount : activeTaskCount
        case .tracks: updatedTrackCount
        case .digests: unreadDigestCount
        case .statistics: recommendationCount
        default: 0
        }
    }
```

Then change the body of `badgeCount(for:)` so its `else` branch uses the helper. Replace the closure assigned to `count` (lines 140-151):

```swift
            let count: Int = {
                switch item {
                case .catchUp: return catchUpTotalCount
                case .briefings: return unreadBriefingCount
                case .inbox: return inboxPendingCount
                case .targets: return overdueTaskCount > 0 ? overdueTaskCount : activeTaskCount
                case .tracks: return updatedTrackCount
                case .digests: return unreadDigestCount
                case .statistics: return recommendationCount
                default: return 0
                }
            }()
```

with:

```swift
            let count = self.count(for: item)
```

(Leave the rest of `badgeCount(for:)` — the `if count > 0` rendering and color logic — unchanged.)

- [ ] **Step 2: Add section aggregate badge helpers**

Add these two methods to `SidebarView` (after the `count(for:)` helper):

```swift
    /// Sum of all child badge counts in a section (drives the collapsed-header badge).
    private func sectionBadgeCount(_ section: SidebarSection) -> Int {
        section.items.reduce(0) { $0 + count(for: $1) }
    }

    /// Color of the collapsed-header badge: the loudest child wins.
    /// red (any item already red) > orange (tracks) > blue (targets/inbox) > red default.
    private func sectionBadgeColor(_ section: SidebarSection) -> Color {
        // Tracks is the only orange source; inbox-high and overdue-targets are red;
        // inbox-normal and active-targets are blue. Mirror badgeCount(for:)'s coloring.
        if section.items.contains(.inbox), inboxHighPriorityCount > 0 { return .red }
        if section.items.contains(.targets), overdueTaskCount > 0 { return .red }
        if section.items.contains(.digests), unreadDigestCount > 0 { return .red }
        if section.items.contains(.briefings), unreadBriefingCount > 0 { return .red }
        if section.items.contains(.statistics), recommendationCount > 0 { return .red }
        if section.items.contains(.catchUp), catchUpTotalCount > 0 { return .red }
        if section.items.contains(.tracks), updatedTrackCount > 0 { return .orange }
        return .blue
    }
```

- [ ] **Step 3: Add the section view builder**

Add this `@ViewBuilder` method to `SidebarView`:

```swift
    @ViewBuilder
    private func sectionView(_ section: SidebarSection) -> some View {
        // Persist expansion per section; default seeded from collapsedByDefault.
        let storageKey = "sidebar.section.\(section.id).collapsed"
        let collapsedBinding = AppStorageBool(key: storageKey, defaultValue: section.collapsedByDefault)
        let isExpanded = Binding(
            get: { !collapsedBinding.value },
            set: { collapsedBinding.value = !$0 }
        )

        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(section.items) { item in
                sidebarButton(item)
            }
        } label: {
            HStack(spacing: 4) {
                Text(section.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                let badge = sectionBadgeCount(section)
                if !isExpanded.wrappedValue, badge > 0 {
                    Text("\(badge)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(sectionBadgeColor(section), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(.automatic)
    }
```

- [ ] **Step 4: Add the `AppStorageBool` storage shim**

`@AppStorage` cannot be created with a dynamic key inside a method, so add a tiny `UserDefaults`-backed helper. Add this small struct at the bottom of `SidebarView.swift`, outside the `SidebarView` struct:

```swift
/// Lightweight UserDefaults-backed bool for dynamic, per-section storage keys.
/// (`@AppStorage` requires a compile-time key, which section iteration can't provide.)
private struct AppStorageBool {
    let key: String
    let defaultValue: Bool

    var value: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
```

- [ ] **Step 5: Rewrite the `body` top section to use root items + sections**

In `body`, replace the current main-items loop (lines 20-23):

```swift
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarDestination.mainItems) { item in
                sidebarButton(item)
            }

            Spacer()
```

with:

```swift
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarDestination.rootItems) { item in
                sidebarButton(item)
            }

            ForEach(SidebarSection.ordered) { section in
                sectionView(section)
            }

            Spacer()
```

(The TOOLS block, indicators, and `SidebarProgressView` below the `Spacer()` are unchanged. `toolItems` now includes `.search`, so Search automatically renders under TOOLS — no further edit needed there.)

- [ ] **Step 6: Build**

Run: `cd WatchtowerDesktop && swift build`
Expected: PASS (no more `mainItems` reference).

- [ ] **Step 7: Run the full test suite**

Run: `cd WatchtowerDesktop && swift test`
Expected: PASS — existing tests plus `SidebarSectionTests` green. The view change has no unit tests (view-layer); structural coverage comes from Task 1.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift
git commit -m "feat(desktop): collapsible sidebar sections with aggregate badges

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Manual verification

No code. Confirm the real app behaves per spec before declaring done.

**Files:** none.

- [ ] **Step 1: Launch and inspect first-run layout**

Build and run the Desktop app (or `swift run` / open in Xcode). Confirm:
- `AI Chat`, `Targets`, `Tracks` render flat at the top.
- `TODAY` section is expanded; `DELIVERY` and `ANALYTICS` are collapsed.
- Collapsed `ANALYTICS` header shows an aggregate badge (Digests + Statistics) in red; `DELIVERY` shows no badge (its items have no counts).

- [ ] **Step 2: Verify persistence**

Expand `DELIVERY`, quit and relaunch the app. Confirm `DELIVERY` is still expanded (state persisted via UserDefaults).

- [ ] **Step 3: Verify reachability**

Click into every destination across root items, all three sections, and TOOLS (including `Search`). Confirm each opens its correct view (cross-check against `Navigation.swift`).

- [ ] **Step 4: Report results**

Summarize what was observed vs. expected. If any item is unreachable or a badge color is wrong, file it as a follow-up against Task 1/Task 2.

---

## Self-Review

**Spec coverage:**
- `SidebarSection` enum + membership + `collapsedByDefault` → Task 1.
- `rootItems` + removal of `mainItems` → Task 1.
- `toolItems` keeps Search → Task 1 (Step 4), rendered in Task 2 (Step 5 note).
- `DisclosureGroup` + `@AppStorage`-equivalent persistence → Task 2 (Steps 3-5).
- Collapsed-header aggregate badge + color precedence → Task 2 (Steps 2-3).
- `sidebarButton`/`badgeCount` reuse (no duplication) → Task 2 (Step 1 extracts shared `count(for:)`).
- Structural-integrity test → Task 1 (Step 1).
- No DB/query/view-model changes → honored throughout.
- Manual verification → Task 3.

**Placeholder scan:** none — every code step shows full code; commands have expected output.

**Type consistency:** `count(for:)`, `sectionBadgeCount(_:)`, `sectionBadgeColor(_:)`, `sectionView(_:)`, `AppStorageBool`, `SidebarSection.ordered`, `SidebarDestination.rootItems` are used with identical signatures across tasks. `toolItems` redefined once (Task 1) and consumed unchanged.

**Note on `@AppStorage`:** The spec described `@AppStorage`; dynamic per-section keys can't use the property wrapper inside a loop, so Task 2 uses a `UserDefaults`-backed `AppStorageBool` shim with identical semantics (same keys, same persistence). This is an implementation detail, not a behavior change.
