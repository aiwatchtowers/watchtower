/// Collapsible, named groups of sidebar destinations. Source of truth for the
/// order and membership of grouped items. Root items (always visible) and tool
/// items live on `SidebarDestination` instead.
enum SidebarSection: String, CaseIterable, Identifiable {
    case today
    case delivery
    case analytics

    var id: String { rawValue }

    /// Render order of the sections.
    static let ordered: [Self] = [.today, .delivery, .analytics]

    var title: String {
        switch self {
        case .today: "FOCUS"
        case .delivery: "EXECUTION"
        case .analytics: "INSIGHTS"
        }
    }

    var items: [SidebarDestination] {
        switch self {
        case .today: [.catchUp, .briefings, .dayPlan, .inbox, .ideas, .calendar]
        case .delivery: [.projectMap, .releases, .blockers, .workload]
        case .analytics: [.digests, .people, .memory, .statistics]
        }
    }

    /// Whether the section starts collapsed on first launch. All sections start
    /// collapsed — the sidebar opens compact and the user expands what they need.
    var collapsedByDefault: Bool { true }

    /// Splits this section's items into the currently visible ones and the ones
    /// the user has hidden (matched by destination id), preserving declared order.
    func partition(hidden: Set<String>) -> (visible: [SidebarDestination], hidden: [SidebarDestination]) {
        var visible: [SidebarDestination] = []
        var hiddenItems: [SidebarDestination] = []
        for item in items {
            if hidden.contains(item.id) { hiddenItems.append(item) } else { visible.append(item) }
        }
        return (visible, hiddenItems)
    }
}
