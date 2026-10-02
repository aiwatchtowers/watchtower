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
        seen.append(contentsOf: SidebarDestination.mainTrailingItems)
        seen.append(contentsOf: SidebarDestination.toolItems)

        // No duplicates.
        XCTAssertEqual(Set(seen).count, seen.count, "a destination is placed in more than one slot")
        // Complete coverage.
        XCTAssertEqual(Set(seen), Set(SidebarDestination.allCases), "some destination is missing from the sidebar or unknown")
    }

    func testSectionMembership() {
        XCTAssertEqual(SidebarSection.today.items, [.catchUp, .briefings, .dayPlan, .inbox, .ideas])
        XCTAssertEqual(SidebarSection.delivery.items, [.projectMap, .releases, .blockers, .workload])
        XCTAssertEqual(SidebarSection.analytics.items, [.digests, .people, .memory, .statistics])
    }

    func testRootItems() {
        XCTAssertEqual(SidebarDestination.rootItems, [.targets, .tracks, .workbench, .calendar])
    }

    /// The Workbench tab keeps the persisted raw value of the old Projects
    /// tab (spec 2026-10-02 A9): `sidebar.hiddenItems` and every stored tab id
    /// written before the rename still resolve to it.
    func testWorkbenchKeepsTheProjectsRawValue() {
        XCTAssertEqual(SidebarDestination.workbench.rawValue, "projects")
        XCTAssertEqual(SidebarDestination.workbench.id, "projects")
        XCTAssertEqual(SidebarDestination(rawValue: "projects"), .workbench)
        XCTAssertEqual(SidebarDestination.workbench.title, "Workbench")
    }

    func testChatIsTrailingMainItemNotTool() {
        XCTAssertEqual(SidebarDestination.mainTrailingItems, [.chat])
        XCTAssertFalse(SidebarDestination.toolItems.contains(.chat))
    }

    func testPartitionSplitsHiddenPreservingOrder() {
        let (visible, hidden) = SidebarSection.delivery.partition(hidden: [SidebarDestination.releases.id])
        XCTAssertEqual(visible, [.projectMap, .blockers, .workload])
        XCTAssertEqual(hidden, [.releases])
    }

    func testPartitionEmptyHiddenKeepsAllVisible() {
        let (visible, hidden) = SidebarSection.today.partition(hidden: [])
        XCTAssertEqual(visible, SidebarSection.today.items)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testCollapsedByDefault() {
        XCTAssertFalse(SidebarSection.today.collapsedByDefault, "FOCUS is an everyday section and should start expanded")
        XCTAssertTrue(SidebarSection.delivery.collapsedByDefault, "EXECUTION should start collapsed")
        XCTAssertTrue(SidebarSection.analytics.collapsedByDefault, "INSIGHTS should start collapsed")
    }

    func testContainingReturnsTheOwningSection() {
        XCTAssertEqual(SidebarSection.containing(.digests), .analytics)
        XCTAssertEqual(SidebarSection.containing(.releases), .delivery)
        XCTAssertEqual(SidebarSection.containing(.inbox), .today)
    }

    func testContainingIsNilForRootAndToolItems() {
        XCTAssertNil(SidebarSection.containing(.targets))
        XCTAssertNil(SidebarSection.containing(.calendar))
        XCTAssertNil(SidebarSection.containing(.chat))
        XCTAssertNil(SidebarSection.containing(.search))
    }

    // MARK: - Auto-expand on navigation

    func testExpandingSectionExpandsACollapsedSection() {
        let updated = SidebarView.expandingSection(for: .digests, in: [SidebarSection.analytics.id: true])
        XCTAssertEqual(updated?[SidebarSection.analytics.id], false)
    }

    func testExpandingSectionNilWhenAlreadyExpanded() {
        XCTAssertNil(SidebarView.expandingSection(for: .digests, in: [SidebarSection.analytics.id: false]))
    }

    func testExpandingSectionNilWhenDestinationHasNoSection() {
        XCTAssertNil(SidebarView.expandingSection(for: .targets, in: [SidebarSection.analytics.id: true]))
    }

    func testExpandingSectionNilWhenMapHasNoEntryForTheSection() {
        // In practice `loadCollapsedSections()` always fills every ordered
        // section's entry, so this shape shouldn't occur from real UserDefaults
        // state — this pins the pure function's own defensive contract for an
        // incomplete map (e.g. a future caller building one by hand): a
        // missing entry must not be treated as "collapsed" and trigger a
        // spurious expand, only an explicit `true` does.
        XCTAssertNil(SidebarView.expandingSection(for: .digests, in: [:]))
    }

    func testExpandingSectionHandlesInitialSelectionInsideACollapsedSection() {
        // The same pure function backs both the sidebar's `onAppear` and its
        // `onChange(of: selection)` — the initial `selection` can already sit
        // inside a collapsed section (window reopened from the tray via a
        // notification route, or the sidebar toggled off and back on with a
        // stale selection), so this must expand exactly like a live
        // navigation does.
        let updated = SidebarView.expandingSection(for: .memory, in: [SidebarSection.analytics.id: true])
        XCTAssertEqual(updated?[SidebarSection.analytics.id], false)
    }

    // MARK: - Feature-gated visibility

    func testDisabledFeatureHidesItsTabs() {
        XCTAssertFalse(SidebarDestination.ideas.isVisible(disabledFeatures: ["ideas"]))
        XCTAssertTrue(SidebarDestination.digests.isVisible(disabledFeatures: ["ideas"]))
    }

    /// .digests requires ANY of slack-digests/stream-digests/ideas: hidden
    /// only when all three are disabled, visible if any one is enabled.
    func testDigestsAnyOfRule() {
        XCTAssertFalse(SidebarDestination.digests.isVisible(disabledFeatures: ["slack-digests", "stream-digests", "ideas"]))
        XCTAssertTrue(SidebarDestination.digests.isVisible(disabledFeatures: ["slack-digests", "stream-digests"]))
        XCTAssertTrue(SidebarDestination.digests.isVisible(disabledFeatures: ["slack-digests", "ideas"]))
        XCTAssertTrue(SidebarDestination.digests.isVisible(disabledFeatures: ["stream-digests", "ideas"]))
    }

    func testCoreTabsAlwaysVisible() {
        let everythingDisabled: Set<String> = [
            "slack-digests", "stream-digests", "ideas", "memory",
            "briefing", "day-plan", "tracks", "people-cards", "secretary-inbox"
        ]
        XCTAssertTrue(SidebarDestination.inbox.isVisible(disabledFeatures: everythingDisabled))
        XCTAssertTrue(SidebarDestination.targets.isVisible(disabledFeatures: everythingDisabled))
        XCTAssertTrue(SidebarDestination.chat.isVisible(disabledFeatures: everythingDisabled))
        XCTAssertTrue(SidebarDestination.calendar.isVisible(disabledFeatures: everythingDisabled))
    }

    func testRootItemTracksFilterable() {
        XCTAssertFalse(SidebarDestination.tracks.isVisible(disabledFeatures: ["tracks"]))
    }

    // MARK: - Collapsed-section badge aggregation

    /// Fixed per-item counts for the Today section, so the sums below are
    /// arithmetic rather than a live SidebarCountsViewModel read.
    private static let todayCounts: [SidebarDestination: Int] = [
        .catchUp: 2, .briefings: 3, .dayPlan: 4, .inbox: 5, .ideas: 7
    ]

    private func todayBadge(hidden: Set<String> = [], disabled: Set<String> = []) -> Int {
        SidebarView.sectionBadgeCount(
            in: .today,
            hidden: hidden,
            disabledFeatures: disabled
        ) { Self.todayCounts[$0] ?? 0 }
    }

    func testSectionBadgeSumsEveryVisibleItem() {
        XCTAssertEqual(todayBadge(), 21)
    }

    /// A feature-disabled item's count must not reach the collapsed badge:
    /// expanding the section won't show that item, so the badge would
    /// promise a count the user cannot find anywhere.
    func testSectionBadgeExcludesFeatureDisabledItems() {
        XCTAssertEqual(todayBadge(disabled: ["ideas"]), 14, "Ideas' 7 must drop out with the feature off")
        XCTAssertEqual(todayBadge(disabled: ["ideas", "briefing"]), 11, "Briefings' 3 drops too")
        XCTAssertEqual(
            todayBadge(disabled: ["ideas", "briefing", "day-plan", "slack-digests"]),
            5,
            "only the ungated .inbox count survives"
        )
    }

    func testSectionBadgeExcludesUserHiddenItems() {
        XCTAssertEqual(todayBadge(hidden: [SidebarDestination.ideas.id]), 14)
    }

    // MARK: - Navigation fallback

    func testFallbackDestinationSwitchesAwayWhenCurrentBecomesHidden() {
        XCTAssertEqual(SidebarDestination.fallbackDestination(current: .ideas, disabled: ["ideas"]), .inbox)
    }

    func testFallbackDestinationNilWhenCurrentStillVisible() {
        XCTAssertNil(SidebarDestination.fallbackDestination(current: .targets, disabled: ["ideas"]))
    }
}
