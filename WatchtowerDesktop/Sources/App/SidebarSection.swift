/// Collapsible, named groups of sidebar destinations. Source of truth for the
/// order and membership of grouped items. Root items (always visible) and tool
/// items live on `SidebarDestination` instead.
enum SidebarSection: String, CaseIterable, Identifiable {
    case today
    case delivery
    case analytics

    var id: String { rawValue }

    /// Render order of the sections.
    static let ordered: [SidebarSection] = [.today, .delivery, .analytics]

    var title: String {
        switch self {
        case .today: "FOCUS"
        case .delivery: "EXECUTION"
        case .analytics: "INSIGHTS"
        }
    }

    var items: [SidebarDestination] {
        switch self {
        case .today: [.catchUp, .briefings, .dayPlan, .inbox, .calendar]
        case .delivery: [.projectMap, .releases, .blockers, .workload]
        case .analytics: [.digests, .people, .statistics]
        }
    }

    /// Whether the section starts collapsed on first launch.
    var collapsedByDefault: Bool {
        switch self {
        case .today: false
        case .delivery, .analytics: true
        }
    }
}
