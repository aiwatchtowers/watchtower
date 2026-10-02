import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

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
        XCTAssertFalse(SidebarDestination.ideas.isVisible(disabledFeatures: ["ideas"], connected: .all))
        XCTAssertTrue(SidebarDestination.digests.isVisible(disabledFeatures: ["ideas"], connected: .all))
    }

    /// .digests requires ANY of slack-digests/stream-digests/ideas: hidden
    /// only when all three are disabled, visible if any one is enabled.
    func testDigestsAnyOfRule() {
        XCTAssertFalse(SidebarDestination.digests.isVisible(disabledFeatures: ["slack-digests", "stream-digests", "ideas"], connected: .all))
        XCTAssertTrue(SidebarDestination.digests.isVisible(disabledFeatures: ["slack-digests", "stream-digests"], connected: .all))
        XCTAssertTrue(SidebarDestination.digests.isVisible(disabledFeatures: ["slack-digests", "ideas"], connected: .all))
        XCTAssertTrue(SidebarDestination.digests.isVisible(disabledFeatures: ["stream-digests", "ideas"], connected: .all))
    }

    func testCoreTabsAlwaysVisible() {
        let everythingDisabled: Set<String> = [
            "slack-digests", "stream-digests", "ideas", "memory",
            "briefing", "day-plan", "tracks", "people-cards", "secretary-inbox"
        ]
        XCTAssertTrue(SidebarDestination.inbox.isVisible(disabledFeatures: everythingDisabled, connected: .all))
        XCTAssertTrue(SidebarDestination.targets.isVisible(disabledFeatures: everythingDisabled, connected: .all))
        XCTAssertTrue(SidebarDestination.chat.isVisible(disabledFeatures: everythingDisabled, connected: .all))
        XCTAssertTrue(SidebarDestination.calendar.isVisible(disabledFeatures: everythingDisabled, connected: .all))
    }

    func testRootItemTracksFilterable() {
        XCTAssertFalse(SidebarDestination.tracks.isVisible(disabledFeatures: ["tracks"], connected: .all))
    }

    // MARK: - Source-gated visibility

    /// Every feature onboarding switches off for "only Development"
    /// (`OnboardingFeaturePlan`): all managed ids but Knowledge search.
    private static let devOnlyDisabled = OnboardingFeaturePlan.managedFeatureIDs
        .subtracting(OnboardingFeaturePlan.enabledFeatureIDs(for: [.development]))

    func testDevOnlyInstallSeesExactlyTheUngatedTabs() {
        let visible = SidebarDestination.allCases.filter {
            $0.isVisible(disabledFeatures: Self.devOnlyDisabled, connected: .none)
        }
        XCTAssertEqual(Set(visible), [.workbench, .chat, .targets, .search, .usage, .mcpServer])
    }

    func testDevOnlyFallbackIsWorkbench() {
        XCTAssertEqual(
            SidebarDestination.fallbackDestination(current: .inbox, disabled: Self.devOnlyDisabled, connected: .none),
            .workbench
        )
        XCTAssertNil(SidebarDestination.fallbackDestination(current: .targets, disabled: Self.devOnlyDisabled, connected: .none))
    }

    func testFallbackPrefersInboxWhenItShows() {
        XCTAssertEqual(
            SidebarDestination.fallbackDestination(current: .boards, disabled: [], connected: ConnectedSources(slack: true)),
            .inbox
        )
    }

    /// Catch-Up is fed by Attention detection: Slack Digests off no longer
    /// hides it, Attention detection off does.
    func testCatchUpFollowsAttentionDetectionNotSlackDigests() {
        let slack = ConnectedSources(slack: true)
        XCTAssertTrue(SidebarDestination.catchUp.isVisible(disabledFeatures: ["slack-digests"], connected: slack))
        XCTAssertFalse(SidebarDestination.catchUp.isVisible(disabledFeatures: ["secretary-inbox"], connected: slack))
        XCTAssertFalse(SidebarDestination.catchUp.isVisible(disabledFeatures: [], connected: .none))
    }

    /// Feature × source for every source-gated tab: each needs its source,
    /// and Catch-Up needs its feature too.
    func testSourceMatrix() {
        let cases: [(SidebarDestination, ConnectedSources, Bool)] = [
            (.calendar, ConnectedSources(calendar: true), true),
            (.calendar, ConnectedSources(slack: true, mail: true, jira: true), false),
            (.inbox, ConnectedSources(slack: true), true),
            (.inbox, ConnectedSources(mail: true), true),
            (.inbox, ConnectedSources(calendar: true, jira: true), false),
            (.statistics, ConnectedSources(mail: true), true),
            (.statistics, ConnectedSources(jira: true), false),
            (.catchUp, ConnectedSources(mail: true), true),
            (.catchUp, ConnectedSources(calendar: true), false)
        ]
        for (tab, connected, expected) in cases {
            XCTAssertEqual(tab.isVisible(disabledFeatures: [], connected: connected), expected, "\(tab) with \(connected)")
        }
        for tab in [SidebarDestination.boards, .workload, .blockers, .projectMap, .releases] {
            XCTAssertTrue(tab.isVisible(disabledFeatures: [], connected: ConnectedSources(jira: true)), "\(tab)")
            XCTAssertFalse(tab.isVisible(disabledFeatures: [], connected: ConnectedSources(slack: true, mail: true, calendar: true)), "\(tab)")
        }
        // Both axes: a source alone does not resurrect a disabled feature's tab.
        XCTAssertFalse(SidebarDestination.tracks.isVisible(disabledFeatures: ["tracks"], connected: .all))
    }

    // MARK: - Collapsed-section badge aggregation

    /// Fixed per-item counts for the Today section, so the sums below are
    /// arithmetic rather than a live SidebarCountsViewModel read.
    private static let todayCounts: [SidebarDestination: Int] = [
        .catchUp: 2, .briefings: 3, .dayPlan: 4, .inbox: 5, .ideas: 7
    ]

    private func todayBadge(
        hidden: Set<String> = [], disabled: Set<String> = [], connected: ConnectedSources = .all
    ) -> Int {
        SidebarView.sectionBadgeCount(
            in: .today,
            hidden: hidden,
            disabledFeatures: disabled,
            connected: connected
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
            todayBadge(disabled: ["ideas", "briefing", "day-plan", "secretary-inbox"]),
            5,
            "only the ungated .inbox count survives"
        )
    }

    /// Same rule on the source axis: with no message source, Catch-Up's 2
    /// and Inbox's 5 drop out.
    func testSectionBadgeExcludesSourceGatedItems() {
        XCTAssertEqual(todayBadge(connected: .none), 14)
    }

    func testSectionBadgeExcludesUserHiddenItems() {
        XCTAssertEqual(todayBadge(hidden: [SidebarDestination.ideas.id]), 14)
    }

    // MARK: - Navigation fallback

    func testFallbackDestinationSwitchesAwayWhenCurrentBecomesHidden() {
        XCTAssertEqual(SidebarDestination.fallbackDestination(current: .ideas, disabled: ["ideas"], connected: .all), .inbox)
    }

    func testFallbackDestinationNilWhenCurrentStillVisible() {
        XCTAssertNil(SidebarDestination.fallbackDestination(current: .targets, disabled: ["ideas"], connected: .all))
    }

    // MARK: - Icon rail

    /// Opening a section in the rail closes whichever was open: at most one.
    func testRailToggleOpensClickedSectionAndClosesTheOther() {
        XCTAssertEqual(SidebarView.railSection(afterToggling: .delivery, current: SidebarSection.today.id), "delivery")
        XCTAssertEqual(SidebarView.railSection(afterToggling: .today, current: nil), "today")
    }

    func testRailToggleOfTheOpenSectionClosesIt() {
        XCTAssertNil(SidebarView.railSection(afterToggling: .analytics, current: SidebarSection.analytics.id))
    }

    func testRailSectionFollowsTheSelectionsSection() {
        XCTAssertEqual(SidebarView.railSection(for: .digests, current: SidebarSection.today.id), "analytics")
        XCTAssertEqual(SidebarView.railSection(for: .workload, current: nil), "delivery")
    }

    /// A root, trailing or tool selection has no section: whatever the
    /// owner had open stays open (or closed).
    func testRailSectionKeptForSelectionsOutsideAnySection() {
        XCTAssertEqual(SidebarView.railSection(for: .targets, current: SidebarSection.delivery.id), "delivery")
        XCTAssertNil(SidebarView.railSection(for: .chat, current: nil))
        XCTAssertNil(SidebarView.railSection(for: .search, current: nil))
    }

    func testRailGroupIconsAreDistinctFromItemIcons() {
        let groupIcons = SidebarSection.ordered.map(\.railIcon)
        XCTAssertEqual(Set(groupIcons).count, groupIcons.count)
        let itemIcons = Set(SidebarDestination.allCases.map(\.icon))
        XCTAssertTrue(itemIcons.isDisjoint(with: groupIcons), "a group icon must not read as a tab")
    }

    /// The menu capsule's colour rule, shared by the rail dot.
    func testBadgeColorRule() {
        XCTAssertEqual(SidebarView.badgeColor(for: .tracks, overdue: false), .orange)
        XCTAssertEqual(SidebarView.badgeColor(for: .memory, overdue: false), .orange)
        XCTAssertEqual(SidebarView.badgeColor(for: .ideas, overdue: false), .orange)
        XCTAssertEqual(SidebarView.badgeColor(for: .inbox, overdue: false), .blue)
        XCTAssertEqual(SidebarView.badgeColor(for: .workbench, overdue: true), .blue)
        XCTAssertEqual(SidebarView.badgeColor(for: .targets, overdue: false), .blue)
        XCTAssertEqual(SidebarView.badgeColor(for: .targets, overdue: true), .red)
        XCTAssertEqual(SidebarView.badgeColor(for: .digests, overdue: false), .red)
        XCTAssertEqual(SidebarView.badgeColor(for: .catchUp, overdue: false), .red)
    }

    private func railDot(
        _ item: SidebarDestination,
        count: Int = 0,
        overdue: Bool = false,
        conflicts: Bool = false,
        calendarConnected: Bool = true
    ) -> Color? {
        SidebarView.railDotColor(
            for: item,
            count: count,
            overdue: overdue,
            dayPlanHasConflicts: conflicts,
            calendarConnected: calendarConnected
        )
    }

    func testRailDotFollowsCountAndColour() {
        XCTAssertNil(railDot(.digests))
        XCTAssertEqual(railDot(.digests, count: 3), .red)
        XCTAssertEqual(railDot(.tracks, count: 1), .orange)
        XCTAssertEqual(railDot(.targets, count: 2, overdue: true), .red)
        XCTAssertEqual(railDot(.targets, count: 2), .blue)
    }

    /// Day Plan and Calendar carry no count; their menu indicators map to dots.
    func testRailDotForDayPlanConflictsAndCalendarConnection() {
        XCTAssertNil(railDot(.dayPlan))
        XCTAssertEqual(railDot(.dayPlan, conflicts: true), .red)
        XCTAssertNil(railDot(.calendar))
        XCTAssertEqual(railDot(.calendar, calendarConnected: false), .orange)
    }

    func testRailHelpAppendsAPositiveCount() {
        XCTAssertEqual(SidebarView.railHelp(title: "Digests", count: 4), "Digests · 4")
        XCTAssertEqual(SidebarView.railHelp(title: "Digests", count: 0), "Digests")
    }
}
