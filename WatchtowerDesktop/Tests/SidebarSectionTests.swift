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
        XCTAssertEqual(SidebarSection.today.items, [.catchUp, .briefings, .dayPlan, .inbox, .ideas, .calendar])
        XCTAssertEqual(SidebarSection.delivery.items, [.projectMap, .releases, .blockers, .workload])
        XCTAssertEqual(SidebarSection.analytics.items, [.digests, .people, .memory, .statistics])
    }

    func testRootItems() {
        XCTAssertEqual(SidebarDestination.rootItems, [.targets, .tracks])
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
        for section in SidebarSection.ordered {
            XCTAssertTrue(section.collapsedByDefault, "\(section) should start collapsed")
        }
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
        .catchUp: 2, .briefings: 3, .dayPlan: 4, .inbox: 5, .ideas: 7, .calendar: 0
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
