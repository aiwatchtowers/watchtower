import Foundation

/// A destination the links zone offers, in its fixed order.
package enum HomeLinkKind: CaseIterable, Sendable {
    case briefing, catchUp, dayPlan, digests
}

/// One row of the links zone.
package struct HomeLinkRow: Equatable, Sendable {
    package let kind: HomeLinkKind
    package let title: String
    /// "ready 08:05", "Fri", "new recap", "2 of 5 done"; nil = no status.
    package let status: String?
    package let highlighted: Bool
    package let link: HomeLink

    package init(kind: HomeLinkKind, title: String, status: String?, highlighted: Bool, link: HomeLink) {
        self.kind = kind
        self.title = title
        self.status = status
        self.highlighted = highlighted
        self.link = link
    }
}

/// Pure builder of the links zone from `HomeLinksData`.
package enum HomeLinksBuilder {
    /// Rows in kind order, only for kinds in `allowed` (a hidden tab leaves no link).
    package static func links(
        _ data: HomeLinksData,
        allowed: Set<HomeLinkKind>,
        now: Date,
        calendar: Calendar
    ) -> [HomeLinkRow] {
        HomeLinkKind.allCases.filter(allowed.contains).map { row($0, data, calendar: calendar) }
    }

    private static func row(_ kind: HomeLinkKind, _ data: HomeLinksData, calendar: Calendar) -> HomeLinkRow {
        switch kind {
        case .briefing:
            let status: String?
            let briefing: Briefing?
            if let today = data.briefingToday {
                briefing = today
                status = readyTime(today, calendar: calendar).map { "ready \($0)" }
            } else {
                briefing = data.latestBriefing
                status = briefing.flatMap { weekday($0.date, calendar: calendar) }
            }
            return HomeLinkRow(kind: kind, title: "Briefing", status: status, highlighted: false,
                               link: briefing.map { .briefing(id: $0.id) } ?? .feature(.briefing))
        case .catchUp:
            let pending = data.pendingRecap != nil
            return HomeLinkRow(kind: kind, title: "Catch-Up", status: pending ? "new recap" : nil,
                               highlighted: pending, link: .catchUp)
        case .dayPlan:
            var status: String?
            if let done = data.dayPlanDone, let total = data.dayPlanTotal, total > 0 {
                status = "\(done) of \(total) done"
            }
            return HomeLinkRow(kind: kind, title: "Day plan", status: status, highlighted: false,
                               link: .feature(.dayPlan))
        case .digests:
            return HomeLinkRow(kind: kind, title: "Digests", status: nil, highlighted: false,
                               link: .feature(.digests))
        }
    }

    private static func readyTime(_ briefing: Briefing, calendar: Calendar) -> String? {
        guard let created = ISO8601DateFormatter().date(from: briefing.createdAt) else { return nil }
        return formatter("HH:mm", calendar).string(from: created)
    }

    private static func weekday(_ day: String, calendar: Calendar) -> String? {
        guard let date = formatter("yyyy-MM-dd", calendar).date(from: day) else { return nil }
        return formatter("EEE", calendar).string(from: date)
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = format
        return fmt
    }
}
