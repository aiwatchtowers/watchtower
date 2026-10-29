import Foundation

/// Pure presentation rules for the coach (Analytics pane and Home).

package enum CoachTrend: Equatable, Sendable {
    case better(String), worse(String), same, fewData, noTrend

    /// Lower is better for every metric; |change| < 5 % is "about the same";
    /// `known == false` or `n < 3` is "few data"; no previous = no trend.
    /// `points`: the metric is a share (0...1) and the change is in points.
    package static func of(_ m: CoachMetric, points: Bool) -> Self {
        guard m.known, m.n >= 3, let value = m.value else { return .fewData }
        guard let previous = m.previous else { return .noTrend }
        let delta = value - previous
        let relative = previous == 0 ? (delta == 0 ? 0 : Double.infinity) : abs(delta / previous)
        if relative < 0.05 { return .same }
        let arrow = delta < 0 ? "↓" : "↑"
        let label: String
        if points {
            label = "\(arrow) \(Int((abs(delta) * 100).rounded())) pts · was \(Int((previous * 100).rounded()))%"
        } else if previous == 0 {
            label = "\(arrow) · was 0"
        } else {
            label = "\(arrow) \(Int((relative * 100).rounded()))% · was \(String(format: "%.1f", previous))"
        }
        return delta < 0 ? .better(label) : .worse(label)
    }
}

package enum CoachDiffLine: Equatable, Sendable {
    case kept(String), removed(String), added(String)

    var isChange: Bool {
        if case .kept = self { return false }
        return true
    }
}

extension CoachProposal {
    /// Open proposals newest first; accepted and rolled back ones newest decided first.
    /// A proposal belongs to the pane of its workbench or is global (0).
    package static func forPane(_ all: [CoachProposal], workbench: Int64)
        -> (open: [CoachProposal], accepted: [CoachProposal]) {
        let mine = all.filter { $0.workbenchID == workbench || $0.workbenchID == 0 }
        let open = mine.filter { $0.status == "open" }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        let accepted = mine.filter { $0.status == "accepted" || $0.status == "rolled_back" }
            .sorted { (($0.decidedAt ?? $0.createdAt), $0.id) > (($1.decidedAt ?? $1.createdAt), $1.id) }
        return (open, accepted)
    }

    package func verdictLine(hasCut: Bool, now: Date) -> String {
        if status == "rolled_back" { return "rolled back" }
        switch verdict {
        case "works":
            let base = baseline.map(Self.number) ?? "?"
            let value = verdictValue.map(Self.number) ?? "?"
            return "works · \(metric) \(base) → \(value) since this edit"
        case "no_effect":
            return "no effect" + (hasCut ? " · a cut is proposed" : "")
        case "too_little_data":
            return "too little data"
        default:
            guard status == "accepted", let decided = decidedAt.flatMap(Self.parseDate) else { return "" }
            let due = decided.addingTimeInterval(14 * 24 * 3600)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "MMM d"
            return "measuring · verdict on \(f.string(from: due))"
        }
    }

    package var diffLines: [CoachDiffLine] {
        Self.lineDiff(before.isEmpty ? [] : before.components(separatedBy: "\n"),
                      after.isEmpty ? [] : after.components(separatedBy: "\n"))
    }

    package var destinationLabel: String {
        let base: String
        switch destination {
        case "session": base = "Session instructions"
        case "procedure": base = "Target procedure"
        case "chat": base = "Chat instructions"
        case "prompt_addition": base = "Watchtower prompt · \(promptID)"
        case "claude_settings_allow": base = "Claude Code settings · allow rules"
        case "claude_md_user": base = "~/.claude/CLAUDE.md"
        default: base = destination
        }
        return workbenchID == 0 ? base + " · all workbenches" : base
    }

    /// Sizes in Unicode scalars (Go runes); `String.count` counts graphemes.
    package var sizeLine: String? {
        guard budget > 0 else { return nil }
        return "\(before.unicodeScalars.count) → \(after.unicodeScalars.count) of \(budget)"
    }

    private static func number(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }

    private static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s)
    }

    /// Line diff by longest common subsequence, in document order.
    static func lineDiff(_ a: [String], _ b: [String]) -> [CoachDiffLine] {
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [CoachDiffLine] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                out.append(.kept(a[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append(.removed(a[i])); i += 1
            } else {
                out.append(.added(b[j])); j += 1
            }
        }
        while i < a.count { out.append(.removed(a[i])); i += 1 }
        while j < b.count { out.append(.added(b[j])); j += 1 }
        return out
    }
}

package enum CoachHomeRow {
    static let maxLines = 4

    /// Changed lines only, at most 4.
    package static func lines(_ p: CoachProposal) -> (shown: [CoachDiffLine], truncated: Bool) {
        let changed = p.diffLines.filter(\.isChange)
        return (Array(changed.prefix(maxLines)), changed.count > maxLines)
    }

    /// A workbench proposal: its id when analytics is on there, else nil.
    /// A global one (0): the last opened workbench when on, else the lowest on id, else nil.
    package static func targetWorkbench(proposalWorkbench: Int64, analyticsOn: [Int64], lastOpened: Int64?) -> Int64? {
        if proposalWorkbench != 0 {
            return analyticsOn.contains(proposalWorkbench) ? proposalWorkbench : nil
        }
        if let last = lastOpened, analyticsOn.contains(last) { return last }
        return analyticsOn.min()
    }
}
