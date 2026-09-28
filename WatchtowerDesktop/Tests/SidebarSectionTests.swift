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
        // No stored preference yet (fresh install, defaults not yet materialized
        // into the map) must not be treated as "collapsed" — only an explicit
        // `true` triggers an expand.
        XCTAssertNil(SidebarView.expandingSection(for: .digests, in: [:]))
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

    // MARK: - Next-meeting card countdown

    func testNextEventCountdownShowsWholeMinutesAboveOneMinute() {
        let now = Date()
        XCTAssertEqual(
            SidebarView.nextEventCountdownText(start: now.addingTimeInterval(34 * 60 + 7), now: now),
            "in 34 min",
            "seconds must not show — drop them rather than round the minute up or down"
        )
        XCTAssertEqual(SidebarView.nextEventCountdownText(start: now.addingTimeInterval(120), now: now), "in 2 min")
        XCTAssertEqual(SidebarView.nextEventCountdownText(start: now.addingTimeInterval(60), now: now), "in 1 min")
    }

    func testNextEventCountdownShowsSecondsInTheLastMinute() {
        let now = Date()
        XCTAssertEqual(SidebarView.nextEventCountdownText(start: now.addingTimeInterval(45), now: now), "in 45 sec")
        XCTAssertEqual(SidebarView.nextEventCountdownText(start: now.addingTimeInterval(1), now: now), "in 1 sec")
    }

    func testNextEventCountdownAtOrAfterStartReadsStartingNow() {
        let now = Date()
        XCTAssertEqual(SidebarView.nextEventCountdownText(start: now, now: now), "starting now")
        XCTAssertEqual(SidebarView.nextEventCountdownText(start: now.addingTimeInterval(-30), now: now), "starting now")
    }
}
