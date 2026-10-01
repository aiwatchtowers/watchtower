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

    /// Whether the section starts collapsed on first launch. FOCUS holds the
    /// everyday tabs (Catch Up, Briefings, Day Plan, Inbox, Ideas, Calendar)
    /// and starts expanded; EXECUTION and INSIGHTS are used less often and
    /// start collapsed — the owner expands what they need, and their own
    /// choice (persisted in UserDefaults, see `SidebarView.loadCollapsedSections`)
    /// always wins over this default once they've toggled a section.
    var collapsedByDefault: Bool { self != .today }

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

    /// The section a destination belongs to, or nil for a root/trailing/tool
    /// item that isn't in any collapsible section.
    static func containing(_ destination: SidebarDestination) -> Self? {
        ordered.first { $0.items.contains(destination) }
    }
}
