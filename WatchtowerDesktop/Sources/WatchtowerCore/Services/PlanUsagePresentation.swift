import Foundation

package enum PlanUsageTone: Equatable, Sendable { case normal, warning, critical, muted }

/// Pure text and tone rules for the Claude plan limits surfaces.
package enum PlanUsagePresentation {
    package static let staleAfter: TimeInterval = 15 * 60

    package static func isStale(_ s: PlanUsageStatus, now: Date) -> Bool {
        guard s.state == "ok", let fetched = s.fetchedAt else { return true }
        return now.timeIntervalSince(fetched) > staleAfter
    }

    package static func tone(_ l: PlanUsageLimit) -> PlanUsageTone {
        if l.percent >= 90 || l.projection.state == "hit" { return .critical }
        if l.percent >= 70 || l.projection.state == "will_hit" { return .warning }
        return .normal
    }

    package static func menuBarText(_ s: PlanUsageStatus?) -> String? {
        guard let s, ["ok", "stale", "error"].contains(s.state) else { return nil }
        let parts = [("session", "5h"), ("weekly_all", "7d")].compactMap { key, short in
            s.limits.first { $0.key == key }.map { "\(short) \(Int($0.percent.rounded()))%" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// MenuBarExtra labels render as a template, so the warning is a prefix, not a colour.
    package static func menuBarWarning(_ s: PlanUsageStatus?, now: Date) -> Bool {
        guard let s, !isStale(s, now: now) else { return false }
        return s.limits.contains { ["session", "weekly_all"].contains($0.key) && tone($0) != .normal }
    }

    package static func resetText(_ l: PlanUsageLimit, now: Date) -> String {
        guard let reset = l.resetsAt else { return "Not started" }
        let mins = max(0, Int(reset.timeIntervalSince(now) / 60))
        let span = mins >= 24 * 60 ? "\(mins / 1440) d \(mins % 1440 / 60) h" : "\(mins / 60) h \(mins % 60) m"
        return "Resets in \(span) (\(clock(reset, now: now)))"
    }

    package static func projectionText(_ l: PlanUsageLimit, now: Date) -> String {
        switch l.projection.state {
        case "will_hit":
            guard let hit = l.projection.hitAt else { return "You may hit it before the reset" }
            var text = "At this pace you hit it at \(clock(hit, now: now))"
            if let reset = l.resetsAt {
                let lead = Int(reset.timeIntervalSince(hit) / 60)
                text += lead >= 60 ? ", \(lead / 60) h before the reset" : ", \(lead) m before the reset"
            }
            return text
        case "hit": return "Limit reached"
        case "collecting": return "Collecting data…"
        case "idle": return "Window not started"
        default: return "You won't hit it before the reset"
        }
    }

    package static func trayLine(_ l: PlanUsageLimit, now: Date) -> String {
        let reset = l.resetsAt.map { "resets \(clock($0, now: now))" } ?? "not started"
        let tail: String
        switch l.projection.state {
        case "will_hit": tail = l.projection.hitAt.map { "hits \(clock($0, now: now))" } ?? "may hit"
        case "hit": tail = "limit reached"
        case "collecting": tail = "collecting"
        case "idle": tail = ""
        default: tail = "safe"
        }
        return ["\(l.label): \(Int(l.percent.rounded()))%", reset, tail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "13:59" today, "Mon 18:59" on another day — local time.
    static func clock(_ date: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
}
