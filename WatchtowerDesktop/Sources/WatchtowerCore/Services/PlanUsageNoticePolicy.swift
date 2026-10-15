import Foundation

/// One banner about a Claude plan limit.
package struct PlanUsageNotice: Equatable, Sendable {
    package let identifier: String
    package let title: String
    package let body: String
}

/// Decides which Claude plan limit banners are due: one per
/// (limit, reset window) for "will hit before the reset" (session and weekly
/// only) and one per window at 90 % (every limit). Pure; the caller persists
/// `sent` and delivers the notices.
package enum PlanUsageNoticePolicy {
    /// `@AppStorage` key of the Settings toggle; absent = on.
    package static let enabledKey = "planUsage.notifications"
    /// `[String]` of `"<kind>|<limit_key>|<resets_at ISO>"`.
    package static let sentKey = "planUsage.sentNotices"

    private static let projectedKeys: Set<String> = ["session", "weekly_all"]

    package static func evaluate(
        _ s: PlanUsageStatus, sent: Set<String>, now: Date
    ) -> (notices: [PlanUsageNotice], sent: Set<String>) {
        // Entries of windows that already reset can never match again.
        var kept = sent.filter { entry in
            guard let reset = PlanUsageDates.parse(entry.split(separator: "|").last.map(String.init)) else { return false }
            return reset >= now
        }
        guard !PlanUsagePresentation.isStale(s, now: now) else { return (notices: [], sent: kept) }

        var notices: [PlanUsageNotice] = []
        for limit in s.limits {
            guard let reset = limit.resetsAt else { continue }
            // Nearest minute: server jitter across a second boundary must not mint a new key.
            let iso = PlanUsageDates.format(Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 60).rounded() * 60))
            let resetText = PlanUsagePresentation.clock(reset, now: now)

            let will = "will|\(limit.key)|\(iso)"
            if limit.projection.state == "will_hit", projectedKeys.contains(limit.key), !kept.contains(will) {
                let hit = limit.projection.hitAt.map { PlanUsagePresentation.clock($0, now: now) } ?? "before the reset"
                notices.append(PlanUsageNotice(
                    identifier: will,
                    title: "\(limit.label) Claude limit",
                    body: "At this pace you hit it at \(hit) — it resets \(resetText)."))
                kept.insert(will)
            }

            let p90 = "p90|\(limit.key)|\(iso)"
            if limit.percent >= 90, !kept.contains(p90) {
                notices.append(PlanUsageNotice(
                    identifier: p90,
                    title: "\(limit.label) Claude limit at \(Int(limit.percent))%",
                    body: limit.percent >= 100 ? "Limit reached. Resets \(resetText)." : "Resets \(resetText)."))
                kept.insert(p90)
            }
        }
        return (notices: notices, sent: kept)
    }
}
