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
        XCTAssertEqual(SidebarSection.today.items, [.catchUp, .inbox])
        XCTAssertEqual(SidebarSection.delivery.items, [.projectMap, .releases, .blockers, .workload])
        XCTAssertEqual(SidebarSection.analytics.items, [.digests, .people, .memory, .statistics])
    }

    func testRootItems() {
        XCTAssertEqual(SidebarDestination.rootItems, [.home, .targets, .workbench, .automations, .calendar])
    }

    /// Briefings, Day Plan, Tracks and Ideas are Inbox filters since C1: no
    /// destination carries their names any more.
    func testTheFourInboxScreensAreNotDestinations() {
        for raw in ["briefings", "dayPlan", "tracks", "ideas"] {
            XCTAssertNil(SidebarDestination(rawValue: raw), raw)
        }
        XCTAssertFalse(SidebarDestination.allCases.map(\.title).contains { ["Briefings", "Day Plan", "Tracks", "Ideas"].contains($0) })
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
        XCTAssertNil(SidebarSection.containing(.usage))
    }

    // MARK: - Auto-expand on navigation

    func testExpandingSectionExpandsACollapsedSection() {
        let updated = SidebarView.expandingSection(for: .digests, in: [SidebarSection.analytics.id: true])
        XCTAssertEqual(updated?[SidebarSection.analytics.id], false)
    }

    /// Navigating opens the target's section and leaves every other fold as
    /// the owner set it — nothing closes.
    func testExpandingSectionKeepsOtherSectionsFolds() {
        let updated = SidebarView.expandingSection(
            for: .workload, in: ["today": true, "delivery": true, "analytics": false]
        )
        XCTAssertEqual(updated, ["today": true, "delivery": false, "analytics": false])
    }

    /// A cold launch has no last-seen selection: the persisted folds stand.
    func testColdLaunchIsNotNavigation() {
        XCTAssertFalse(SidebarView.selectionChangedWhileOffScreen(.digests, lastSeen: nil))
    }

    /// A tab switched while the window was closed (a notification route)
    /// counts as navigation when the sidebar reappears.
    func testReopenAfterTheSelectionChangedElsewhereIsNavigation() {
        XCTAssertTrue(SidebarView.selectionChangedWhileOffScreen(.digests, lastSeen: .inbox))
    }

    func testReopenOnTheSameTabIsNotNavigation() {
        XCTAssertFalse(SidebarView.selectionChangedWhileOffScreen(.digests, lastSeen: .digests))
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

    // MARK: - Section fold state (shared by the menu and the rail)

    /// A toggle flips only the clicked section: several sections can be
    /// open at once (the rail is no longer an accordion).
    func testToggleFlipsOnlyTheClickedSection() {
        let open: [String: Bool] = ["today": false, "delivery": false, "analytics": true]
        let updated = SidebarView.togglingSection(.analytics, in: open)
        XCTAssertEqual(updated, ["today": false, "delivery": false, "analytics": false])
        XCTAssertEqual(SidebarView.togglingSection(.today, in: updated)["today"], true)
        XCTAssertEqual(SidebarView.togglingSection(.today, in: updated)["delivery"], false)
    }

    /// A section with no entry flips away from its default.
    func testToggleOfAMissingEntryFlipsTheDefault() {
        XCTAssertEqual(SidebarView.togglingSection(.today, in: [:]), ["today": true])
        XCTAssertEqual(SidebarView.togglingSection(.delivery, in: [:]), ["delivery": false])
    }

    private func scratchDefaults() throws -> UserDefaults {
        let name = "SidebarSectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testLoadFallsBackToSectionDefaults() throws {
        let loaded = SidebarView.loadCollapsedSections(from: try scratchDefaults())
        XCTAssertEqual(loaded, ["today": false, "delivery": true, "analytics": true])
    }

    /// A fold persists under `sidebar.section.<id>.collapsed` and a relaunch
    /// reads it back — the one state the menu and the rail both draw.
    func testToggleSurvivesARelaunch() throws {
        let defaults = try scratchDefaults()
        let before = SidebarView.loadCollapsedSections(from: defaults)
        let after = SidebarView.toggledSection(.today, in: before, persistingTo: defaults)
        XCTAssertEqual(defaults.object(forKey: "sidebar.section.today.collapsed") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "sidebar.section.delivery.collapsed"), "an unchanged section is not written")
        XCTAssertEqual(SidebarView.loadCollapsedSections(from: defaults), after)
    }

    /// Board #365: navigation's expand of a folded section is for this run
    /// only — a later toggle of another section writes that section alone,
    /// so a relaunch shows the owner's fold again.
    func testNavigationsExpandIsNotPersisted() throws {
        let defaults = try scratchDefaults()
        let loaded = SidebarView.loadCollapsedSections(from: defaults)
        let navigated = try XCTUnwrap(SidebarView.expandingSection(for: .digests, in: loaded))
        XCTAssertEqual(navigated[SidebarSection.analytics.id], false)

        let toggled = SidebarView.toggledSection(.today, in: navigated, persistingTo: defaults)

        XCTAssertEqual(toggled[SidebarSection.analytics.id], false, "still open in this run")
        XCTAssertNil(defaults.object(forKey: SidebarView.storageKey(.analytics)))
        XCTAssertEqual(SidebarView.loadCollapsedSections(from: defaults)[SidebarSection.analytics.id], true,
                       "a relaunch shows it folded")
    }

    /// The retired rail accordion key is ignored: a stale value opens nothing.
    func testRetiredRailKeyIsIgnored() throws {
        let defaults = try scratchDefaults()
        defaults.set("analytics", forKey: "sidebar.rail.expandedSection")
        defaults.set(true, forKey: "sidebar.section.today.collapsed")
        XCTAssertEqual(
            SidebarView.loadCollapsedSections(from: defaults),
            ["today": true, "delivery": true, "analytics": true]
        )
    }

    // MARK: - Feature-gated visibility

    func testDisabledFeatureHidesItsTabs() {
        XCTAssertFalse(SidebarDestination.memory.isVisible(disabledFeatures: ["memory"], connected: .all))
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

    /// Core tabs have neither gate: everything off, nothing connected.
    func testCoreTabsAlwaysVisible() {
        let everythingDisabled: Set<String> = [
            "slack-digests", "stream-digests", "ideas", "memory",
            "briefing", "day-plan", "tracks", "people-cards", "secretary-inbox"
        ]
        XCTAssertTrue(SidebarDestination.targets.isVisible(disabledFeatures: everythingDisabled, connected: .none))
        XCTAssertTrue(SidebarDestination.chat.isVisible(disabledFeatures: everythingDisabled, connected: .none))
    }

    /// The Inbox has neither gate (C1: it also holds the briefings, plans,
    /// tracks and ideas); Calendar has no feature gate, only a source one.
    func testInboxHasNoGateAndCalendarNeedsItsSource() {
        let everythingDisabled: Set<String> = ["secretary-inbox", "briefing", "day-plan"]
        XCTAssertTrue(SidebarDestination.inbox.isVisible(disabledFeatures: everythingDisabled, connected: ConnectedSources(slack: true)))
        XCTAssertTrue(SidebarDestination.inbox.isVisible(disabledFeatures: everythingDisabled, connected: .none))
        XCTAssertTrue(SidebarDestination.calendar.isVisible(disabledFeatures: everythingDisabled, connected: ConnectedSources(calendar: true)))
        XCTAssertFalse(SidebarDestination.calendar.isVisible(disabledFeatures: [], connected: .none))
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
        // Automations' feature is unmanaged by onboarding, so a dev-only
        // install keeps whatever state it has (here: on).
        XCTAssertEqual(Set(visible), [.home, .inbox, .workbench, .automations, .chat, .targets, .connections, .usage, .mcpServer])
    }

    func testDevOnlyFallbackIsHome() {
        XCTAssertEqual(
            SidebarDestination.fallbackDestination(current: .catchUp, disabled: Self.devOnlyDisabled, connected: .none),
            .home
        )
        XCTAssertNil(SidebarDestination.fallbackDestination(current: .targets, disabled: Self.devOnlyDisabled, connected: .none))
        XCTAssertNil(SidebarDestination.fallbackDestination(current: .inbox, disabled: Self.devOnlyDisabled, connected: .none))
    }

    func testFallbackIsHomeEvenWhenInboxShows() {
        XCTAssertEqual(
            SidebarDestination.fallbackDestination(current: .workload, disabled: [], connected: ConnectedSources(slack: true)),
            .home
        )
    }

    /// Catch-Up (owner decision 2026-10-03, #284): Attention detection OR a
    /// digest feature on, AND any source (messages, Jira or a calendar).
    func testCatchUpFeatureAndSourceMatrix() {
        let digestsOff: Set<String> = ["slack-digests", "stream-digests"]
        let cases: [(disabled: Set<String>, connected: ConnectedSources, expected: Bool, why: String)] = [
            ([], ConnectedSources(jira: true), true, "Jira only"),
            ([], ConnectedSources(calendar: true), true, "calendar only"),
            ([], ConnectedSources(mail: true), true, "mail only"),
            ([], .none, false, "no source"),
            (["secretary-inbox", "stream-digests"], ConnectedSources(slack: true), true,
             "Attention detection off, Slack Digests on"),
            (["secretary-inbox", "slack-digests"], ConnectedSources(jira: true), true,
             "Attention detection off, Stream Digests on"),
            (digestsOff, ConnectedSources(slack: true), true, "Attention detection alone"),
            (digestsOff.union(["secretary-inbox"]), ConnectedSources(slack: true), false, "every feature off"),
            (digestsOff.union(["secretary-inbox"]), .all, false, "every feature off, every source on")
        ]
        for c in cases {
            XCTAssertEqual(
                SidebarDestination.catchUp.isVisible(disabledFeatures: c.disabled, connected: c.connected),
                c.expected, c.why
            )
        }
    }

    /// Inbox needs no source and no feature (C1; before, any source, #284).
    func testInboxShowsWithoutAnySource() {
        let everythingDisabled: Set<String> = ["secretary-inbox", "slack-digests", "stream-digests"]
        for connected in [ConnectedSources(jira: true), ConnectedSources(calendar: true), ConnectedSources(slack: true), .none] {
            XCTAssertTrue(SidebarDestination.inbox.isVisible(disabledFeatures: everythingDisabled, connected: connected), "\(connected)")
        }
    }

    /// A Jira-only install that lands on a hidden tab falls back to Home.
    func testJiraOnlyFallbackIsHome() {
        XCTAssertEqual(
            SidebarDestination.fallbackDestination(current: .statistics, disabled: [], connected: ConnectedSources(jira: true)),
            .home
        )
    }

    /// Every source-gated tab needs one of its sources.
    func testSourceMatrix() {
        let cases: [(SidebarDestination, ConnectedSources, Bool)] = [
            (.calendar, ConnectedSources(calendar: true), true),
            (.calendar, ConnectedSources(slack: true, mail: true, jira: true), false),
            (.statistics, ConnectedSources(mail: true), true),
            (.statistics, ConnectedSources(calendar: true, jira: true), false),
            (.catchUp, ConnectedSources(mail: true), true),
            (.catchUp, ConnectedSources(calendar: true), true),
            (.catchUp, .none, false)
        ]
        for (tab, connected, expected) in cases {
            XCTAssertEqual(tab.isVisible(disabledFeatures: [], connected: connected), expected, "\(tab) with \(connected)")
        }
        for tab in [SidebarDestination.workload, .blockers, .projectMap, .releases] {
            XCTAssertTrue(tab.isVisible(disabledFeatures: [], connected: ConnectedSources(jira: true)), "\(tab)")
            XCTAssertFalse(tab.isVisible(disabledFeatures: [], connected: ConnectedSources(slack: true, mail: true, calendar: true)), "\(tab)")
        }
        // Both axes: a source alone does not resurrect a disabled feature's tab.
        XCTAssertFalse(SidebarDestination.people.isVisible(disabledFeatures: ["people-cards"], connected: .all))
    }

    // MARK: - Collapsed-section badge aggregation

    /// Fixed per-item counts for the Today section, so the sums below are
    /// arithmetic rather than a live SidebarCountsViewModel read.
    private static let todayCounts: [SidebarDestination: Int] = [
        .catchUp: 2, .inbox: 5
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
        XCTAssertEqual(todayBadge(), 7)
    }

    /// A feature-disabled item's count must not reach the collapsed badge:
    /// expanding the section won't show that item, so the badge would
    /// promise a count the user cannot find anywhere.
    func testSectionBadgeExcludesFeatureDisabledItems() {
        XCTAssertEqual(
            todayBadge(disabled: ["secretary-inbox", "slack-digests", "stream-digests"]),
            5,
            "Catch Up's 2 drops out; only the feature-ungated .inbox count survives"
        )
    }

    /// Same rule on the source axis: with no source at all, Catch-Up's 2
    /// drops out; the ungated Inbox's 5 stays.
    func testSectionBadgeExcludesSourceGatedItems() {
        XCTAssertEqual(todayBadge(connected: .none), 5)
    }

    func testSectionBadgeExcludesUserHiddenItems() {
        XCTAssertEqual(todayBadge(hidden: [SidebarDestination.catchUp.id]), 5)
    }

    /// A `sidebar.hiddenItems` entry left from hiding a removed tab is ignored.
    func testHiddenEntryOfARemovedTabIsIgnored() {
        XCTAssertEqual(todayBadge(hidden: ["ideas", "briefings", "dayPlan", "tracks"]), 7)
        XCTAssertEqual(SidebarSection.today.partition(hidden: ["ideas", "dayPlan"]).hidden, [])
    }

    // MARK: - Navigation fallback

    func testFallbackDestinationSwitchesAwayWhenCurrentBecomesHidden() {
        XCTAssertEqual(SidebarDestination.fallbackDestination(current: .memory, disabled: ["memory"], connected: .all), .home)
    }

    func testFallbackDestinationNilWhenCurrentStillVisible() {
        XCTAssertNil(SidebarDestination.fallbackDestination(current: .targets, disabled: ["ideas"], connected: .all))
    }

    // MARK: - Icon rail

    func testRailGroupIconsAreDistinctFromItemIcons() {
        let groupIcons = SidebarSection.ordered.map(\.railIcon)
        XCTAssertEqual(Set(groupIcons).count, groupIcons.count)
        let itemIcons = Set(SidebarDestination.allCases.map(\.icon))
        XCTAssertTrue(itemIcons.isDisjoint(with: groupIcons), "a group icon must not read as a tab")
    }

    /// The menu capsule's colour rule, shared by the rail dot.
    func testBadgeColorRule() {
        XCTAssertEqual(SidebarView.badgeColor(for: .memory, overdue: false), .orange)
        XCTAssertEqual(SidebarView.badgeColor(for: .automations, overdue: false), .orange)
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
        calendarConnected: Bool = true
    ) -> Color? {
        SidebarView.railDotColor(
            for: item,
            count: count,
            overdue: overdue,
            calendarConnected: calendarConnected
        )
    }

    func testRailDotFollowsCountAndColour() {
        XCTAssertNil(railDot(.digests))
        XCTAssertEqual(railDot(.digests, count: 3), .red)
        XCTAssertEqual(railDot(.memory, count: 1), .orange)
        XCTAssertEqual(railDot(.targets, count: 2, overdue: true), .red)
        XCTAssertEqual(railDot(.targets, count: 2), .blue)
    }

    /// Calendar carries no count; its menu indicator maps to a dot.
    func testRailDotForCalendarConnection() {
        XCTAssertNil(railDot(.calendar))
        XCTAssertEqual(railDot(.calendar, calendarConnected: false), .orange)
    }

    func testRailHelpAppendsAPositiveCount() {
        XCTAssertEqual(SidebarView.railHelp(title: "Digests", count: 4), "Digests · 4")
        XCTAssertEqual(SidebarView.railHelp(title: "Digests", count: 0), "Digests")
    }
}
