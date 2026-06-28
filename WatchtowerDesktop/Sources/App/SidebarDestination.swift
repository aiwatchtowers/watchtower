import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case chat
    case catchUp
    case briefings
    case dayPlan
    case inbox
    case calendar
    case targets
    case tracks
    case digests
    case people
    case workload
    case blockers
    case projectMap
    case releases
    case statistics
    case search
    case boards
    case usage
    case training
    case mcpServer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "AI Chat"
        case .catchUp: "Catch Up"
        case .briefings: "Briefings"
        case .dayPlan: "Day Plan"
        case .inbox: "Inbox"
        case .calendar: "Calendar"
        case .targets: "Targets"
        case .tracks: "Tracks"
        case .digests: "Digests"
        case .people: "People"
        case .workload: "Workload"
        case .blockers: "Blockers"
        case .projectMap: "Project Map"
        case .releases: "Releases"
        case .statistics: "Statistics"
        case .search: "Search"
        case .boards: "Boards"
        case .usage: "Usage"
        case .training: "Training"
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
        case .calendar: "calendar"
        case .targets: "scope"
        case .tracks: "binoculars"
        case .digests: "doc.text.magnifyingglass"
        case .people: "person.2"
        case .workload: "gauge.with.dots.needle.33percent"
        case .blockers: "exclamationmark.triangle"
        case .projectMap: "map"
        case .releases: "shippingbox"
        case .statistics: "chart.bar.xaxis"
        case .search: "magnifyingglass"
        case .boards: "rectangle.on.rectangle.angled"
        case .usage: "chart.bar"
        case .training: "brain.head.profile"
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
        [.search, .boards, .usage, .training, .mcpServer]
    }
}
