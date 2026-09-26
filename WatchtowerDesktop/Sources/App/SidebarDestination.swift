import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case chat
    case catchUp
    case briefings
    case dayPlan
    case inbox
    case ideas
    case calendar
    case targets
    case tracks
    case digests
    case people
    case memory
    case workload
    case blockers
    case projectMap
    case releases
    case statistics
    case search
    case boards
    case usage
    case mcpServer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "AI Chat"
        case .catchUp: "Catch Up"
        case .briefings: "Briefings"
        case .dayPlan: "Day Plan"
        case .inbox: "Inbox"
        case .ideas: "Ideas"
        case .calendar: "Calendar"
        case .targets: "Targets"
        case .tracks: "Tracks"
        case .digests: "Digests"
        case .people: "People"
        case .memory: "Memory"
        case .workload: "Workload"
        case .blockers: "Blockers"
        case .projectMap: "Project Map"
        case .releases: "Releases"
        case .statistics: "Statistics"
        case .search: "Search"
        case .boards: "Boards"
        case .usage: "Usage"
        case .mcpServer: "MCP Server"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .catchUp: "tray.and.arrow.down"
        case .briefings: "sun.max"
        case .dayPlan: "calendar.day.timeline.left"
        case .inbox: "tray"
        case .ideas: "lightbulb"
        case .calendar: "calendar"
        case .targets: "scope"
        case .tracks: "binoculars"
        case .digests: "doc.text.magnifyingglass"
        case .people: "person.2"
        case .memory: "archivebox"
        case .workload: "gauge.with.dots.needle.33percent"
        case .blockers: "exclamationmark.triangle"
        case .projectMap: "map"
        case .releases: "shippingbox"
        case .statistics: "chart.bar.xaxis"
        case .search: "magnifyingglass"
        case .boards: "rectangle.on.rectangle.angled"
        case .usage: "chart.bar"
        case .mcpServer: "terminal"
        }
    }

    /// Always-visible items rendered above the collapsible sections.
    static var rootItems: [Self] {
        [.targets, .tracks]
    }

    /// Always-visible items rendered below the collapsible sections, as the last
    /// entries of the main menu (above the TOOLS separator). AI Chat anchors here.
    static var mainTrailingItems: [Self] {
        [.chat]
    }

    /// Tool items (shown below the separator). Search lives here too.
    static var toolItems: [Self] {
        [.search, .boards, .usage, .mcpServer]
    }
}

extension SidebarDestination {
    /// Feature ids that keep this tab visible; visible iff ANY is enabled.
    /// nil = always visible (core tabs, and tabs with no single owning
    /// feature — e.g. `.inbox`, which stays reachable even with the
    /// secretary-inbox feature off so its banner and existing situations
    /// remain visible).
    var requiredFeatures: [String]? {
        switch self {
        case .catchUp: ["slack-digests"]
        case .digests: ["slack-digests", "stream-digests", "ideas"]
        case .ideas: ["ideas"]
        case .memory: ["memory"]
        case .briefings: ["briefing"]
        case .dayPlan: ["day-plan"]
        case .tracks: ["tracks"]
        case .people: ["people-cards"]
        default: nil
        }
    }

    /// Whether this tab should render given the current set of disabled
    /// feature ids. A tab with no `requiredFeatures` is always visible; one
    /// that declares features is visible as long as at least one of them is
    /// still enabled.
    func isVisible(disabledFeatures: Set<String>) -> Bool {
        guard let required = requiredFeatures else { return true }
        return required.contains { !disabledFeatures.contains($0) }
    }

    /// The destination navigation should fall back to when `current` is no
    /// longer visible under `disabled` (its feature was just turned off, or
    /// a persisted selection from a previous launch points at a now-hidden
    /// tab), or nil when `current` is still visible and no fallback is
    /// needed. Pure — no AppState dependency — so the selection owner can
    /// call it both on a live feature-list change and once at appear.
    static func fallbackDestination(current: SidebarDestination, disabled: Set<String>) -> SidebarDestination? {
        current.isVisible(disabledFeatures: disabled) ? nil : .inbox
    }
}
