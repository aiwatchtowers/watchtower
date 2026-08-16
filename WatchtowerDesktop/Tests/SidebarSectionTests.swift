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

    // MARK: - Navigation fallback

    func testFallbackDestinationSwitchesAwayWhenCurrentBecomesHidden() {
        XCTAssertEqual(SidebarDestination.fallbackDestination(current: .ideas, disabled: ["ideas"]), .inbox)
    }

    func testFallbackDestinationNilWhenCurrentStillVisible() {
        XCTAssertNil(SidebarDestination.fallbackDestination(current: .targets, disabled: ["ideas"]))
    }
}
