import SwiftUI
import GRDB

struct SidebarView: View {
    @Binding var selection: SidebarDestination
    @Environment(AppState.self) private var appState

    /// Per-section collapsed flag. Held in @State so toggling re-renders the view;
    /// seeded from UserDefaults (persisted across launches) on first appearance.
    @State private var collapsedSections: [String: Bool] = Self.loadCollapsedSections()

    /// Destination ids the user has hidden into their section's "Hidden" sub-list.
    /// Held in @State so hide/show re-renders; persisted to UserDefaults.
    @State private var hiddenItems: Set<String> = Self.loadHiddenItems()

    /// Token-file check for the "connect" badge on the Calendar item.
    /// Re-checked on every selection change (cheap file stat) so the badge
    /// clears right after the user connects from any screen.
    @State private var googleAuth = GoogleAuthService()

    private static func storageKey(_ section: SidebarSection) -> String {
        "sidebar.section.\(section.id).collapsed"
    }

    private static func loadCollapsedSections() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for section in SidebarSection.ordered {
            result[section.id] = UserDefaults.standard.object(forKey: storageKey(section)) as? Bool
                ?? section.collapsedByDefault
        }
        return result
    }

    private static let hiddenItemsKey = "sidebar.hiddenItems"

    private static func loadHiddenItems() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenItemsKey) ?? [])
    }

    private func setHidden(_ item: SidebarDestination, _ hidden: Bool) {
        if hidden { hiddenItems.insert(item.id) } else { hiddenItems.remove(item.id) }
        UserDefaults.standard.set(Array(hiddenItems), forKey: Self.hiddenItemsKey)
    }

    private var counts: SidebarCountsViewModel? { appState.sidebarCountsViewModel }
    private var updatedTrackCount: Int { counts?.updatedTrackCount ?? 0 }
    private var unreadDigestCount: Int { counts?.unreadDigestCount ?? 0 }
    private var unreadBriefingCount: Int { counts?.unreadBriefingCount ?? 0 }
    private var recommendationCount: Int { counts?.recommendationCount ?? 0 }
    private var activeTaskCount: Int { counts?.activeTaskCount ?? 0 }
    private var overdueTaskCount: Int { counts?.overdueTaskCount ?? 0 }
    private var inboxHighPriorityCount: Int { counts?.inboxHighPriorityCount ?? 0 }
    private var situationsCount: Int { counts?.situationsCount ?? 0 }
    private var catchUpTotalCount: Int { counts?.catchUpTotalCount ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarDestination.rootItems) { item in
                sidebarButton(item)
            }

            ForEach(SidebarSection.ordered) { section in
                sectionView(section)
            }

            ForEach(SidebarDestination.mainTrailingItems) { item in
                sidebarButton(item)
            }

            Spacer()

            // Background tasks progress
            SidebarProgressView()

            // Tools section
            VStack(alignment: .leading, spacing: 2) {
                Text("TOOLS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)

                ForEach(SidebarDestination.toolItems) { item in
                    sidebarButton(item)
                }
            }

            // Next calendar event
            if let calVM = appState.calendarViewModel, let nextEvt = calVM.nextEvent {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(nextEvt.title)
                            .font(.caption)
                            .lineLimit(1)
                        Text(nextEvt.startDate, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
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
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { googleAuth.checkStatus() }
        .onChange(of: selection) { _, _ in googleAuth.checkStatus() }
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
                Text(item.title)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
                badgeCount(for: item)
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
            if !googleAuth.isConnected {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Google is not connected — open Calendar to connect it")
            }
        } else {
            let count = self.count(for: item)
            if count > 0 {
                capsuleBadge(count, color: item == .tracks ? .orange
                    : item == .inbox && inboxHighPriorityCount > 0 ? .red
                    : item == .inbox ? .blue
                    : item == .targets && overdueTaskCount > 0 ? .red
                    : item == .targets ? .blue
                    : .red)
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
        case .inbox: situationsCount
        case .targets: overdueTaskCount > 0 ? overdueTaskCount : activeTaskCount
        case .tracks: updatedTrackCount
        case .digests: unreadDigestCount
        case .statistics: recommendationCount
        default: 0
        }
    }

    /// Sum of badge counts for a section's VISIBLE items (drives the collapsed-header
    /// badge). Hidden items are excluded — hiding an item also silences its noise.
    private func sectionBadgeCount(_ section: SidebarSection) -> Int {
        section.partition(hidden: hiddenItems).visible.reduce(0) { $0 + count(for: $1) }
    }

    /// Color of the collapsed-header badge: red if any visible child is a red source
    /// (inbox-high/digests/briefings/statistics/catch-up), otherwise blue.
    private func sectionBadgeColor(_ section: SidebarSection) -> Color {
        let visible = section.partition(hidden: hiddenItems).visible
        if visible.contains(.inbox), inboxHighPriorityCount > 0 { return .red }
        if visible.contains(.digests), unreadDigestCount > 0 { return .red }
        if visible.contains(.briefings), unreadBriefingCount > 0 { return .red }
        if visible.contains(.statistics), recommendationCount > 0 { return .red }
        if visible.contains(.catchUp), catchUpTotalCount > 0 { return .red }
        return .blue
    }

    private func isCollapsed(_ section: SidebarSection) -> Bool {
        collapsedSections[section.id] ?? section.collapsedByDefault
    }

    private func toggleSection(_ section: SidebarSection) {
        let newValue = !isCollapsed(section)
        collapsedSections[section.id] = newValue
        UserDefaults.standard.set(newValue, forKey: Self.storageKey(section))
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
                    Text(section.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
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
                ForEach(parts.visible) { item in
                    sidebarButton(item)
                        .contextMenu {
                            Button("Hide") {
                                withAnimation(.easeInOut(duration: 0.15)) { setHidden(item, true) }
                            }
                        }
                }

                if !parts.hidden.isEmpty {
                    Text("HIDDEN")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    ForEach(parts.hidden) { item in
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

}
