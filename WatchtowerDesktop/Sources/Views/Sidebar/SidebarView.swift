import SwiftUI
import GRDB
import WatchtowerCore

struct SidebarView: View {
    @Binding var selection: SidebarDestination
    /// The folded icon rail (⌘B) instead of the full menu: the same items,
    /// counts and visibility rules, drawn as icons with dot badges, and each
    /// section folded into one group icon (see `railBody`).
    var compact = false
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    /// Per-section collapsed flag — the one state both the menu and the icon
    /// rail draw, so folding a section in either shows it folded in the other.
    /// Held in @State so toggling re-renders the view; seeded from UserDefaults
    /// (persisted across launches) on first appearance.
    @State private var collapsedSections: [String: Bool] = Self.loadCollapsedSections()

    /// Destination ids the user has hidden into their section's "Hidden" sub-list.
    /// Held in @State so hide/show re-renders; persisted to UserDefaults.
    @State private var hiddenItems: Set<String> = Self.loadHiddenItems()

    /// Shows the full next-meeting card (with Join) from the rail's compact chip.
    @State private var showsMeetingPopover = false

    /// DB-derived connection check for the "connect" badge on the Calendar
    /// item — reuses `GoogleConnectFlow.shared.calendar` (wired to a dbPool
    /// by `AppState.initGoogleAccounts`) rather than a locally-constructed
    /// `GoogleAuthService()`, which would have no DB access. Re-checked on
    /// every selection change so the badge clears right after the user
    /// connects from any screen.
    private let googleAuth = GoogleConnectFlow.shared.calendar

    static func storageKey(_ section: SidebarSection) -> String {
        "sidebar.section.\(section.id).collapsed"
    }

    /// Every ordered section's collapsed flag: the stored one, else the
    /// section's default. The rail's former accordion key
    /// (`sidebar.rail.expandedSection`) is no longer read.
    static func loadCollapsedSections(from defaults: UserDefaults = .standard) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for section in SidebarSection.ordered {
            result[section.id] = defaults.object(forKey: storageKey(section)) as? Bool
                ?? section.collapsedByDefault
        }
        return result
    }

    /// Writes each section whose flag differs between `old` and `new` to
    /// `defaults`, so a toggle in either mode survives a relaunch.
    static func persistCollapsedSections(
        _ new: [String: Bool], replacing old: [String: Bool], to defaults: UserDefaults = .standard
    ) {
        for section in SidebarSection.ordered where new[section.id] != old[section.id] {
            if let value = new[section.id] {
                defaults.set(value, forKey: storageKey(section))
            }
        }
    }

    private static let hiddenItemsKey = "sidebar.hiddenItems"

    private static func loadHiddenItems() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenItemsKey) ?? [])
    }

    private func setHidden(_ item: SidebarDestination, _ hidden: Bool) {
        if hidden { hiddenItems.insert(item.id) } else { hiddenItems.remove(item.id) }
        UserDefaults.standard.set(Array(hiddenItems), forKey: Self.hiddenItemsKey)
    }

    /// Feature ids currently disabled — read fresh on every render so a live
    /// Feature Manager change (or the initial load) hides/reveals tabs
    /// without a separate observation wire-up.
    private var disabledFeatures: Set<String> { appState.featureVisibility.disabledFeatureIDs }
    /// Connected sources, the second visibility axis — same read-fresh rule.
    private var connectedSources: ConnectedSources { appState.featureVisibility.connectedSources }

    /// Both visibility axes for `item` (`SidebarDestination.isVisible`).
    private func isShown(_ item: SidebarDestination) -> Bool {
        item.isVisible(disabledFeatures: disabledFeatures, connected: connectedSources)
    }

    private var counts: SidebarCountsViewModel? { appState.sidebarCountsViewModel }
    private var updatedTrackCount: Int { counts?.updatedTrackCount ?? 0 }
    private var unreadDigestCount: Int { counts?.unreadDigestCount ?? 0 }
    /// The Digests badge: Slack + stream + decision unread, matching the
    /// Digests tab header (see `SidebarCountsViewModel.digestsBadgeCount`).
    private var digestsBadgeCount: Int { counts?.digestsBadgeCount ?? 0 }
    private var unreadBriefingCount: Int { counts?.unreadBriefingCount ?? 0 }
    private var recommendationCount: Int { counts?.recommendationCount ?? 0 }
    private var activeTaskCount: Int { counts?.activeTaskCount ?? 0 }
    private var overdueTaskCount: Int { counts?.overdueTaskCount ?? 0 }
    private var inboxStripCount: Int { counts?.inboxStripCount ?? 0 }
    private var memoryDisputedCount: Int { counts?.memoryDisputedCount ?? 0 }
    private var ideasCount: Int { counts?.ideasCount ?? 0 }
    private var catchUpTotalCount: Int { counts?.catchUpTotalCount ?? 0 }

    var body: some View {
        Group {
            if compact { railBody } else { menuBody }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, compact ? 6 : 8)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { googleAuth.checkStatus() }
        .onChange(of: selection) { _, _ in
            googleAuth.checkStatus()
            expandSectionContainingSelection()
        }
        .onChange(of: collapsedSections) { old, new in
            Self.persistCollapsedSections(new, replacing: old)
        }
    }

    private var menuBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarDestination.rootItems.filter(isShown)) { item in
                sidebarButton(item)
            }

            ForEach(SidebarSection.ordered) { section in
                sectionView(section)
            }

            ForEach(SidebarDestination.mainTrailingItems.filter(isShown)) { item in
                sidebarButton(item)
            }

            Spacer()

            SidebarConnectRow()

            // Tools section
            VStack(alignment: .leading, spacing: 2) {
                Text("TOOLS")
                    .sidebarSectionLabel()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)

                ForEach(SidebarDestination.toolItems.filter(isShown)) { item in
                    sidebarButton(item)
                }
            }

            // Next calendar event
            if let calVM = appState.calendarViewModel, let nextEvt = calVM.nextEvent {
                SidebarNextMeetingCard(event: nextEvt, center: appState.meetingRecorderCenter)
            }

            // Jira connection indicator
            if JiraQueries.isConnected() {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 16)
                    Text("Jira connected")
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Update available indicator
            if appState.updateService.isUpdateAvailable {
                Button {
                    // `showSettingsWindow:` via sendAction is a no-op on macOS 14+.
                    appState.settingsTab = .system
                    openSettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Update Available")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Expands `selection`'s section if it's currently collapsed. Called only
    /// when the selection changes — navigating to a tab tucked inside a folded
    /// section — never on appearance, a relaunch or a ⌘B fold, so the owner's
    /// own folds stand; a folded section holding the selection is tinted
    /// instead (the menu's header label, the rail's group icon).
    private func expandSectionContainingSelection() {
        if let expanded = Self.expandingSection(for: selection, in: collapsedSections) {
            collapsedSections = expanded
        }
    }

    // MARK: - Main Sidebar Button

    private func sidebarButton(_ item: SidebarDestination) -> some View {
        let isSelected = selection == item
        return Button {
            selection = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .white : .secondary)
                // One line always: on a narrow sidebar a long title next to a
                // wide badge shrinks a little instead of breaking mid-word.
                Text(item.title)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                badgeCount(for: item)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color.accentColor
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func badgeCount(for item: SidebarDestination) -> some View {
        if item == .dayPlan {
            if appState.dayPlanViewModel?.hasConflicts == true {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
            }
        } else if item == .calendar {
            if !connectedSources.calendar {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Google is not connected — open Calendar to connect it")
            }
        } else {
            let count = self.count(for: item)
            if count > 0 {
                capsuleBadge(count, color: Self.badgeColor(for: item, overdue: overdueTaskCount > 0))
            }
        }
    }

    @ViewBuilder
    private func capsuleBadge(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color, in: Capsule())
    }

    /// The numeric badge value for a single destination (0 = no badge).
    /// Shared by the per-item badge and the collapsed-section aggregate badge.
    private func count(for item: SidebarDestination) -> Int {
        switch item {
        case .catchUp: catchUpTotalCount
        case .briefings: unreadBriefingCount
        case .inbox: inboxStripCount
        case .ideas: ideasCount
        case .targets: overdueTaskCount > 0 ? overdueTaskCount : activeTaskCount
        case .tracks: updatedTrackCount
        case .workbench: appState.workbenchesViewModel?.badgeCount ?? 0
        case .digests: digestsBadgeCount
        case .memory: memoryDisputedCount
        case .statistics: recommendationCount
        default: 0
        }
    }

    /// A section's items after BOTH filters: the user's own hide choices and
    /// feature-gated visibility. Static and pure — the badge math below is
    /// otherwise only reachable through an `@Environment`-backed view
    /// instance, which a test cannot construct (see SidebarSectionTests).
    static func visibleItems(
        in section: SidebarSection,
        hidden: Set<String>,
        disabledFeatures: Set<String>,
        connected: ConnectedSources
    ) -> [SidebarDestination] {
        section.partition(hidden: hidden).visible
            .filter { $0.isVisible(disabledFeatures: disabledFeatures, connected: connected) }
    }

    /// Sum of badge counts for a section's VISIBLE items (drives the collapsed-header
    /// badge). Hidden items are excluded — hiding an item also silences its noise —
    /// and so are feature-disabled ones, for the same reason: a collapsed section
    /// must not promise a count the expanded list won't actually show.
    static func sectionBadgeCount(
        in section: SidebarSection,
        hidden: Set<String>,
        disabledFeatures: Set<String>,
        connected: ConnectedSources,
        count: (SidebarDestination) -> Int
    ) -> Int {
        visibleItems(in: section, hidden: hidden, disabledFeatures: disabledFeatures, connected: connected)
            .reduce(0) { $0 + count($1) }
    }

    private func sectionBadgeCount(_ section: SidebarSection) -> Int {
        Self.sectionBadgeCount(
            in: section,
            hidden: hiddenItems,
            disabledFeatures: disabledFeatures,
            connected: connectedSources,
            count: count(for:)
        )
    }

    /// Color of the collapsed-header badge: red if any visible child is a red source
    /// (digests/briefings/statistics/catch-up), otherwise blue. The Inbox is not
    /// one: its badge counts the action strip, and the high-priority inbox_items
    /// that used to turn it red are no longer shown on that tab.
    private func sectionBadgeColor(_ section: SidebarSection) -> Color {
        let visible = Self.visibleItems(
            in: section, hidden: hiddenItems, disabledFeatures: disabledFeatures, connected: connectedSources
        )
        if visible.contains(.digests), digestsBadgeCount > 0 { return .red }
        if visible.contains(.briefings), unreadBriefingCount > 0 { return .red }
        if visible.contains(.statistics), recommendationCount > 0 { return .red }
        if visible.contains(.catchUp), catchUpTotalCount > 0 { return .red }
        return .blue
    }

    /// A collapsed-sections map with `destination`'s section expanded, or nil
    /// when there's nothing to do (the destination has no section, or its
    /// section is already expanded) — so navigating to a tab tucked inside a
    /// collapsed section shows the selection instead of hiding it behind a
    /// closed header. Pure, for the same testability reason as
    /// `sectionBadgeCount` above.
    static func expandingSection(
        for destination: SidebarDestination,
        in collapsed: [String: Bool]
    ) -> [String: Bool]? {
        guard let section = SidebarSection.containing(destination), collapsed[section.id] == true else {
            return nil
        }
        var updated = collapsed
        updated[section.id] = false
        return updated
    }

    /// The collapsed-sections map after clicking `section`'s header (menu) or
    /// group icon (rail): only that section flips, the others keep their state.
    static func togglingSection(_ section: SidebarSection, in collapsed: [String: Bool]) -> [String: Bool] {
        var updated = collapsed
        updated[section.id] = !(collapsed[section.id] ?? section.collapsedByDefault)
        return updated
    }

    private func isCollapsed(_ section: SidebarSection) -> Bool {
        collapsedSections[section.id] ?? section.collapsedByDefault
    }

    private func toggleSection(_ section: SidebarSection) {
        collapsedSections = Self.togglingSection(section, in: collapsedSections)
    }

    @ViewBuilder
    private func sectionView(_ section: SidebarSection) -> some View {
        let collapsed = isCollapsed(section)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    toggleSection(section)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    // A folded section holding the selection keeps an accent
                    // tint, so the current tab is never invisible.
                    Text(section.title)
                        .sidebarSectionLabel(highlighted: collapsed && section.items.contains(selection))
                    Spacer()
                    let badge = sectionBadgeCount(section)
                    if collapsed, badge > 0 {
                        capsuleBadge(badge, color: sectionBadgeColor(section))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                let parts = section.partition(hidden: hiddenItems)
                // Feature-gated visibility is filtered on top of the user's
                // own show/hide choice, on BOTH halves — a feature-disabled
                // item disappears from the section entirely rather than
                // resurfacing in the "Hidden" sub-list.
                let visibleItems = parts.visible.filter(isShown)
                let userHiddenItems = parts.hidden.filter(isShown)
                ForEach(visibleItems) { item in
                    sidebarButton(item)
                        .contextMenu {
                            Button("Hide") {
                                withAnimation(.easeInOut(duration: 0.15)) { setHidden(item, true) }
                            }
                        }
                }

                if !userHiddenItems.isEmpty {
                    Text("HIDDEN")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    ForEach(userHiddenItems) { item in
                        sidebarButton(item)
                            .opacity(0.5)
                            .contextMenu {
                                Button("Show") {
                                    withAnimation(.easeInOut(duration: 0.15)) { setHidden(item, false) }
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: - Badge colours (shared by the menu and the rail)

    /// The colour of an item's count badge: the capsule in the menu, the dot
    /// in the rail. Targets turn red once anything is overdue.
    static func badgeColor(for item: SidebarDestination, overdue: Bool) -> Color {
        switch item {
        case .tracks, .memory, .ideas: .orange
        case .inbox, .workbench: .blue
        case .targets: overdue ? .red : .blue
        default: .red
        }
    }

    /// The rail's dot for an item, or nil for none — the menu's badge rule
    /// without the number: Day Plan's conflict dot, Calendar's not-connected
    /// indicator, otherwise `badgeColor` whenever the count is positive.
    static func railDotColor(
        for item: SidebarDestination,
        count: Int,
        overdue: Bool,
        dayPlanHasConflicts: Bool,
        calendarConnected: Bool
    ) -> Color? {
        switch item {
        case .dayPlan: dayPlanHasConflicts ? .red : nil
        case .calendar: calendarConnected ? nil : .orange
        default: count > 0 ? badgeColor(for: item, overdue: overdue) : nil
        }
    }

    /// A rail icon's tooltip: the title, plus " · <count>" when there is one.
    static func railHelp(title: String, count: Int) -> String {
        count > 0 ? "\(title) · \(count)" : title
    }

    // MARK: - Icon rail

    private var railBody: some View {
        VStack(spacing: 2) {
            ForEach(SidebarDestination.rootItems.filter(isShown)) { item in
                railButton(item)
            }

            ForEach(SidebarSection.ordered) { section in
                railSectionView(section)
            }

            railSeparator

            ForEach(SidebarDestination.mainTrailingItems.filter(isShown)) { item in
                railButton(item)
            }

            Spacer()

            railSeparator

            ForEach(SidebarDestination.toolItems.filter(isShown)) { item in
                railButton(item)
            }

            railFooter
        }
        .frame(maxWidth: .infinity)
    }

    private var railSeparator: some View {
        Divider()
            .frame(width: 24)
            .padding(.vertical, 4)
    }

    private func railIcon(_ systemName: String, isSelected: Bool, tint: Color = .secondary, dot: Color?) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14))
            .foregroundStyle(isSelected ? .white : tint)
            .frame(width: 34, height: 28)
            .background(
                isSelected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(alignment: .topTrailing) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: 3)
                }
            }
            .contentShape(Rectangle())
    }

    private func railButton(_ item: SidebarDestination) -> some View {
        let count = count(for: item)
        let dot = Self.railDotColor(
            for: item,
            count: count,
            overdue: overdueTaskCount > 0,
            dayPlanHasConflicts: appState.dayPlanViewModel?.hasConflicts == true,
            calendarConnected: connectedSources.calendar
        )
        var help = Self.railHelp(title: item.title, count: count)
        if item == .calendar, !connectedSources.calendar {
            help += " · Google is not connected"
        }
        return Button {
            selection = item
        } label: {
            railIcon(item.icon, isSelected: selection == item, dot: dot)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func railSectionView(_ section: SidebarSection) -> some View {
        let items = Self.visibleItems(
            in: section, hidden: hiddenItems, disabledFeatures: disabledFeatures, connected: connectedSources
        )
        if !items.isEmpty {
            let expanded = !isCollapsed(section)
            let badge = sectionBadgeCount(section)
            railSeparator
            VStack(spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        toggleSection(section)
                    }
                } label: {
                    // A closed group holding the selection keeps an accent
                    // tint, so the current tab is never invisible.
                    railIcon(
                        section.railIcon,
                        isSelected: false,
                        tint: !expanded && items.contains(selection) ? .accentColor : .secondary,
                        dot: !expanded && badge > 0 ? sectionBadgeColor(section) : nil
                    )
                }
                .buttonStyle(.plain)
                .help(Self.railHelp(title: section.title.capitalized, count: expanded ? 0 : badge))

                if expanded {
                    ForEach(items) { item in
                        railButton(item)
                    }
                }
            }
            .background(
                expanded ? Color.primary.opacity(0.05) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }

    private static let railTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    @ViewBuilder
    private var railFooter: some View {
        if let calVM = appState.calendarViewModel, let nextEvt = calVM.nextEvent {
            Button {
                showsMeetingPopover = true
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(Self.railTimeFormatter.string(from: nextEvt.startDate))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(nextEvt.title)
            .popover(isPresented: $showsMeetingPopover, arrowEdge: .trailing) {
                SidebarNextMeetingCard(event: nextEvt, center: appState.meetingRecorderCenter)
                    .frame(width: 240)
                    .padding(.vertical, 8)
            }
        }

        if JiraQueries.isConnected() {
            railIcon("bolt.horizontal.circle.fill", isSelected: false, tint: .blue, dot: nil)
                .help("Jira connected")
        }

        if appState.updateService.isUpdateAvailable {
            Button {
                appState.settingsTab = .system
                openSettings()
            } label: {
                railIcon("arrow.down.circle.fill", isSelected: false, tint: .blue, dot: nil)
            }
            .buttonStyle(.plain)
            .help("Update Available")
        }
    }
}

extension Text {
    /// The sidebar's section labels (FOCUS, EXECUTION, TOOLS), also used by
    /// the Workbench panel's SESSIONS label so the two never drift.
    /// `highlighted` draws it in the accent colour instead.
    func sidebarSectionLabel(highlighted: Bool = false) -> some View {
        font(.system(size: 10, weight: .semibold))
            .foregroundStyle(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
    }
}
