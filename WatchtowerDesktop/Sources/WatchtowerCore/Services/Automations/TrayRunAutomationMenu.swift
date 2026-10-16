import Foundation

/// The menu-bar tray's "Run automation ▸" submenu (spec §12.7, mockup 7):
/// quick run's rows grouped by workbench name, then Personal, each item
/// with its last status. A SwiftUI menu item has no trailing detail column,
/// so the status rides in the label.
package enum TrayRunAutomationMenu {
    package struct Section: Identifiable, Equatable, Sendable {
        /// "workbench-<id>" or "personal".
        package let id: String
        /// The workbench name, or "Personal".
        package let title: String
        package let items: [Item]
    }

    package struct Item: Identifiable, Equatable, Sendable {
        /// The automation id.
        package let id: Int64
        /// The name, "…" appended when it asks before running, " (run now)" for a scheduled or event recipe.
        package let title: String
        /// "✓ 2 d ago", "✗ 2 d ago", "● running", "— needs confirmation", "— disabled", "— can't be read" or "".
        package let status: String
        /// False for a disabled or unreadable recipe: a click would do nothing
        /// useful. A recipe waiting for confirmation stays clickable (it opens the sheet).
        package let isActionable: Bool

        package var label: String { status.isEmpty ? title : title + "  " + status }
    }

    /// Groups in `QuickRunCatalog.rows` order (workbenches by name, Personal last).
    package static func sections(_ rows: [QuickRunRow], now: Date) -> [Section] {
        var sections: [Section] = []
        for row in rows {
            let item = item(row, now: now)
            let (id, title) = switch row.group {
            case let .workbench(workbenchID, name): ("workbench-\(workbenchID)", name)
            case .personal: ("personal", "Personal")
            }
            if let last = sections.last, last.id == id {
                sections[sections.count - 1] = Section(id: id, title: title, items: last.items + [item])
            } else {
                sections.append(Section(id: id, title: title, items: [item]))
            }
        }
        return sections
    }

    private static func item(_ row: QuickRunRow, now: Date) -> Item {
        var title = row.name
        if row.kind == .scheduledOrEvent {
            title += " (run now)"
        } else if row.asksFirst {
            title += "…"
        }
        let actionable = switch row.state {
        case .disabled, .parseError: false
        case .runnable, .running, .needsConfirmation: true
        }
        return Item(id: row.id, title: title, status: status(row, now: now), isActionable: actionable)
    }

    private static func status(_ row: QuickRunRow, now: Date) -> String {
        switch row.state {
        case .running: return "● running"
        case .needsConfirmation: return "— needs confirmation"
        case .disabled: return "— disabled"
        case .parseError: return "— can't be read"
        case .runnable: break
        }
        guard let run = row.lastRun, !run.status.isActive else { return "" }
        let mark = run.status == .succeeded ? "✓" : "✗"
        guard let at = run.finishedAt ?? run.startedAt ?? run.queuedAt else { return mark }
        return "\(mark) \(age(of: at, now: now))"
    }

    /// "just now", "5 min ago", "3 h ago", "2 d ago".
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
    }
}
