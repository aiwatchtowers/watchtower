import SwiftUI
import WatchtowerCore

/// `briefings`, `dayPlan`, `ideas` and `tracks` were destinations until the
/// one Inbox (C1). A stored raw value of theirs decodes to nil (a
/// `sidebar.hiddenItems` entry is ignored), and a `watchtower-nav://` link
/// naming one opens the matching Inbox filter (`InboxRoute.aliasHosts`).
enum SidebarDestination: String, CaseIterable, Identifiable {
    case home
    case chat
    case catchUp
    case inbox
    case calendar
    case targets
    // The raw value is persisted (`sidebar.hiddenItems`, the tab id), so the
    // Workbench rename keeps its bytes (spec 2026-10-02 A9).
    case workbench = "projects"
    case automations
    case digests
    case people
    case memory
    case workload
    case blockers
    case projectMap
    case releases
    case statistics
    case boards
    case usage
    case mcpServer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .chat: "AI Chat"
        case .catchUp: "Catch Up"
        case .inbox: "Inbox"
        case .calendar: "Calendar"
        case .targets: "Targets"
        case .workbench: "Workbench"
        case .automations: "Automations"
        case .digests: "Digests"
        case .people: "People"
        case .memory: "Memory"
        case .workload: "Workload"
        case .blockers: "Blockers"
        case .projectMap: "Project Map"
        case .releases: "Releases"
        case .statistics: "Statistics"
        case .boards: "Boards"
        case .usage: "Usage"
        case .mcpServer: "MCP Server"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .chat: "bubble.left.and.bubble.right"
        case .catchUp: "tray.and.arrow.down"
        case .inbox: "tray"
        case .calendar: "calendar"
        case .targets: "scope"
        case .workbench: "folder.badge.gearshape"
        case .automations: "gearshape.2"
        case .digests: "doc.text.magnifyingglass"
        case .people: "person.2"
        case .memory: "archivebox"
        case .workload: "gauge.with.dots.needle.33percent"
        case .blockers: "exclamationmark.triangle"
        case .projectMap: "map"
        case .releases: "shippingbox"
        case .statistics: "chart.bar.xaxis"
        case .boards: "rectangle.on.rectangle.angled"
        case .usage: "chart.bar"
        case .mcpServer: "terminal"
        }
    }

    /// Always-visible items rendered above the collapsible sections, Home
    /// first. Automations follows Workbench (hidden with its feature off).
    /// Calendar sits right under them (board #206; it was in FOCUS before): a root
    /// item has no hide menu, so a `sidebar.hiddenItems` entry left from
    /// hiding it in FOCUS is ignored and the tab shows again. Tracks left the
    /// root with the one Inbox (C1): its cards are the Inbox's Tracks filter.
    static var rootItems: [Self] {
        [.home, .targets, .workbench, .automations, .calendar]
    }

    /// Always-visible items rendered below the collapsible sections, as the last
    /// entries of the main menu (above the TOOLS separator). AI Chat anchors here.
    static var mainTrailingItems: [Self] {
        [.chat]
    }

    /// Tool items (shown below the separator).
    static var toolItems: [Self] {
        [.boards, .usage, .mcpServer]
    }
}

extension SidebarDestination {
    /// Feature ids that keep this tab visible; visible iff ANY is enabled.
    /// nil = no feature gate (core tabs, and tabs with no single owning
    /// feature — e.g. `.inbox`, which stays reachable even with the
    /// secretary-inbox feature off so its banner and existing situations
    /// remain visible). Catch-Up shows a recap built from Attention
    /// detection or from the digests, so any of the three keeps it.
    var requiredFeatures: [String]? {
        switch self {
        case .catchUp: ["secretary-inbox", "slack-digests", "stream-digests"]
        case .digests: ["slack-digests", "stream-digests", "ideas"]
        case .memory: ["memory"]
        case .people: ["people-cards"]
        default: nil
        }
    }

    /// Sources this tab needs to have anything to show; visible iff ANY is
    /// connected. nil = no source gate.
    var requiredSources: [SidebarSource]? {
        switch self {
        case .calendar: [.calendar]
        case .boards, .workload, .projectMap, .releases: [.jira]
        // Blockers read Jira and Linear through `tracker_issues`.
        case .blockers: [.jira, .linear]
        // Catch-Up also surfaces tracker mentions and meeting items. The
        // Inbox has no source gate: it also holds the briefings, day plans,
        // tracks and ideas (C1), whose own tabs never had one.
        case .catchUp: [.messages, .jira, .linear, .calendar]
        case .statistics: [.messages]
        default: nil
        }
    }

    /// Whether this tab should render: its feature rule (`requiredFeatures`
    /// against the disabled ids) AND its source rule (`requiredSources`
    /// against what is connected) both hold.
    func isVisible(disabledFeatures: Set<String>, connected: ConnectedSources) -> Bool {
        SidebarVisibility.isVisible(
            requiredFeatures: requiredFeatures,
            requiredSources: requiredSources,
            disabledFeatures: disabledFeatures,
            connected: connected
        )
    }

    /// The destination navigation should fall back to when `current` is no
    /// longer visible (its feature was just turned off, its source is gone,
    /// or a persisted selection from a previous launch points at a now-hidden
    /// tab), or nil when `current` is still visible and no fallback is
    /// needed: always Home, which has no feature or source gate, so it shows
    /// on every install. Pure — no AppState dependency — so the selection
    /// owner can call it both on a live change and once at appear.
    static func fallbackDestination(
        current: SidebarDestination,
        disabled: Set<String>,
        connected: ConnectedSources
    ) -> SidebarDestination? {
        current.isVisible(disabledFeatures: disabled, connected: connected) ? nil : .home
    }
}
