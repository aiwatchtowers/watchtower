import SwiftUI
import GRDB

struct SidebarView: View {
    @Binding var selection: SidebarDestination
    @Environment(AppState.self) private var appState

    /// Per-section collapsed flag. Held in @State so toggling re-renders the view;
    /// seeded from UserDefaults (persisted across launches) on first appearance.
    @State private var collapsedSections: [String: Bool] = SidebarView.loadCollapsedSections()

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

    private var counts: SidebarCountsViewModel? { appState.sidebarCountsViewModel }
    private var updatedTrackCount: Int { counts?.updatedTrackCount ?? 0 }
    private var unreadDigestCount: Int { counts?.unreadDigestCount ?? 0 }
    private var unreadBriefingCount: Int { counts?.unreadBriefingCount ?? 0 }
    private var recommendationCount: Int { counts?.recommendationCount ?? 0 }
    private var activeTaskCount: Int { counts?.activeTaskCount ?? 0 }
    private var overdueTaskCount: Int { counts?.overdueTaskCount ?? 0 }
    private var inboxPendingCount: Int { counts?.inboxPendingCount ?? 0 }
    private var inboxHighPriorityCount: Int { counts?.inboxHighPriorityCount ?? 0 }
    private var catchUpTotalCount: Int { counts?.catchUpTotalCount ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarDestination.rootItems) { item in
                sidebarButton(item)
            }

            ForEach(SidebarSection.ordered) { section in
                sectionView(section)
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
        case .inbox: inboxPendingCount
        case .targets: overdueTaskCount > 0 ? overdueTaskCount : activeTaskCount
        case .tracks: updatedTrackCount
        case .digests: unreadDigestCount
        case .statistics: recommendationCount
        default: 0
        }
    }

    /// Sum of all child badge counts in a section (drives the collapsed-header badge).
    private func sectionBadgeCount(_ section: SidebarSection) -> Int {
        section.items.reduce(0) { $0 + count(for: $1) }
    }

    /// Color of the collapsed-header badge: red if any child is a red source (inbox-high/digests/briefings/statistics/catch-up), otherwise blue.
    private func sectionBadgeColor(_ section: SidebarSection) -> Color {
        if section.items.contains(.inbox), inboxHighPriorityCount > 0 { return .red }
        if section.items.contains(.digests), unreadDigestCount > 0 { return .red }
        if section.items.contains(.briefings), unreadBriefingCount > 0 { return .red }
        if section.items.contains(.statistics), recommendationCount > 0 { return .red }
        if section.items.contains(.catchUp), catchUpTotalCount > 0 { return .red }
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
                ForEach(section.items) { item in
                    sidebarButton(item)
                }
            }
        }
    }

}
