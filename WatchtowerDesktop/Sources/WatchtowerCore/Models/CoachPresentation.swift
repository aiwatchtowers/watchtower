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

    /// The tuning chat's own proposals: origin `chat`, that conversation,
    /// oldest first (the order they were proposed in the chat).
    package static func forChat(_ all: [CoachProposal], conversationID: Int64) -> [CoachProposal] {
        all.filter { $0.origin == "chat" && $0.conversationID == conversationID }
            .sorted { $0.id < $1.id }
    }

    /// The Accepted edits row's state. A repository file (§4.3a) is measured
    /// from its commit (`measure_from`): until then it waits for the commit,
    /// and 30 days without one end it unmeasured. `writtenPath` is the
    /// accept result's path when the Desktop has it.
    /// A pull-request edit (`pr_url`, spec 2026-11-19 §4.4) waits for its
    /// merge instead, and 30 days without one end it unmeasured.
    package func verdictLine(hasCut: Bool, now: Date, writtenPath: String? = nil) -> String {
        let repoPath = writtenPath ?? repoRelativePath
        if status == "rolled_back" {
            if !prURL.isEmpty {
                return revertPRURL.isEmpty ? CoachPRTexts.closed : CoachPRTexts.rolledBack
            }
            return repoPath.map { TuningChatTexts.rolledBackRepoFile(path: $0) } ?? "rolled back"
        }
        if !prURL.isEmpty, status == "accepted", measureFrom == nil {
            return verdict == "too_little_data" ? CoachPRTexts.notMerged : CoachPRTexts.waiting
        }
        if repoPath != nil, status == "accepted", measureFrom == nil {
            return verdict == "too_little_data" ? TuningChatTexts.notCommitted : TuningChatTexts.awaitingCommit
        }
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
            guard status == "accepted", let decided = (measureFrom ?? decidedAt).flatMap(Self.parseDate) else { return "" }
            let due = decided.addingTimeInterval(14 * 24 * 3600)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "MMM d"
            return "measuring · verdict on \(f.string(from: due))"
        }
    }

    /// "PR #12" for the pull request Accept opened.
    package var prLabel: String { CoachPRTexts.label(prURL) }

    /// The rolled-back row's second line while the revert PR waits for its
    /// merge (§4.6); nil without one.
    package var revertLine: String? {
        guard status == "rolled_back", !revertPRURL.isEmpty else { return nil }
        return CoachPRTexts.revertLine(CoachPRTexts.label(revertPRURL))
    }

    package var diffLines: [CoachDiffLine] {
        Self.lineDiff(before.isEmpty ? [] : before.components(separatedBy: "\n"),
                      after.isEmpty ? [] : after.components(separatedBy: "\n"))
    }

    package var destinationLabel: String {
        // The owner's own files and the pack serve every workbench by nature:
        // no "all workbenches" suffix.
        let named = { (kind: String) in [kind, self.skill ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") }
        switch destination {
        case "claude_skill_user": return named("Claude skill")
        case "codex_skill_user": return named("Codex skill")
        case "pack_overlay": return named("Watchtower skill")
        case "codex_agents_md_user": return "Codex AGENTS.md"
        case "codex_rules_allow": return "Codex rules"
        // A workbench's own files name it already: no suffix either.
        case "repo_claude_md": return "Workbench CLAUDE.md"
        case "repo_agents_md": return "Workbench AGENTS.md"
        case "repo_claude_skill": return named("Workbench Claude skill")
        case "repo_codex_skill": return named("Workbench Codex skill")
        case "repo_workflow": return "Workbench workflow.md"
        default: break
        }
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

    /// A workbench repository destination's file, relative to the workbench
    /// folder: the twin of Go's `coach.RepoRelPath` (shared table
    /// `internal/coach/testdata/repo_rel_paths.json`). nil for any other
    /// destination and for a skill name Go refuses.
    package var repoRelativePath: String? {
        switch destination {
        case "repo_claude_md": return "CLAUDE.md"
        case "repo_agents_md": return "AGENTS.md"
        case "repo_workflow": return ".watchtower/workflow.md"
        case "repo_claude_skill", "repo_codex_skill":
            guard let skill, skill.wholeMatch(of: Self.skillName) != nil else { return nil }
            let top = destination == "repo_claude_skill" ? ".claude" : ".agents"
            return "\(top)/skills/\(skill)/SKILL.md"
        default: return nil
        }
    }

    /// Go's `validSkillName`.
    private static let skillName = #/[A-Za-z0-9][A-Za-z0-9._-]{0,63}/#

    /// The caption above the card's diff: the destination, or for a
    /// repository file its path, then the size line. No branch: before
    /// Accept the Desktop cannot tell whether the edit opens a pull request
    /// or writes the working copy (spec 2026-11-19 §4.6).
    package var diffCaption: String {
        let head = repoRelativePath ?? destinationLabel
        return [head, sizeLine].compactMap { $0 }.joined(separator: " · ")
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

/// The coach's pull-request texts (spec 2026-11-19 §4.4–§4.6): the link
/// label, the Accepted edits lines and the refusals of Accept, Roll Back and
/// `coach sync-prs`. The refusal sentences are twins of Go's `coach.*Line`
/// (`internal/coach/repopr.go`); tested in `CoachPresentationTests`.
package enum CoachPRTexts {
    package static let retry = "Retry"
    package static let rolledBack = "Rolled back"
    package static let revertLead = "Revert:"
    package static let revertTail = "— merge it to remove the edit."
    /// The Accepted edits row (the yellow dot) until the PR is merged; the
    /// "PR #N" link beside it names the PR.
    package static let waiting = "Waiting for the merge"
    /// The row of a PR not merged 30 days after Accept (`too_little_data`).
    package static let notMerged = "Not merged in 30 days — not measured"
    /// The row of a PR closed without merge (by hand or by Roll Back).
    package static let closed = "Rolled back · PR closed"
    /// The tuning panel's folded card until the PR is merged (the link sits beside it).
    package static let foldedWaiting = "Accepted · waiting for the PR to merge"
    /// The folded card of a PR not merged in 30 days.
    package static let foldedNotMerged = "Accepted · not merged in 30 days — not measured"
    package static let foldedMerged = "Accepted · merged · measuring for 14 days"
    /// Over Accepted edits when `coach sync-prs` read no state for some
    /// PRs for any reason but the two below; they are read again next time.
    package static let syncFailed =
        "Couldn't check the pull requests on GitHub — they are checked again next time you open this list."

    /// Go `coach.NoGHLine`.
    package static let noGH = "Log in with `gh auth login` to let Watchtower open the pull request."
    /// Go `coach.PushFailedLine`.
    package static let pushFailed = "GitHub refused the branch, or the push needed a password prompt."
    /// Go `coach.PRFailedLine`.
    package static let prFailed = "GitHub did not open or close the pull request — press the button again to retry."
    /// Go `coach.TimeoutLine`.
    package static let timeout = "GitHub did not answer in time; nothing changed — try again."
    /// Go `coach.OriginMovedLine`.
    package static let originMoved =
        "This folder's origin is no longer the repository the pull request is in; nothing changed."
    /// Go `coach.UnreachableLine` (`github_unreachable`: gh could not reach GitHub to check the login).
    package static let unreachable = "Could not reach GitHub to check your gh login; nothing changed — try again."
    /// Go `coach.InProgressLine` (`in_progress`: another process is deciding the same proposal).
    package static let inProgress =
        "This proposal is already being accepted, declined or rolled back — wait for it to finish."

    /// Go `coach.BaseDiffersLine`.
    package static func baseDiffers(path: String) -> String {
        "\(path) on the default branch differs from the one the chat read — pull, then ask the chat again."
    }

    /// Go `coach.PRUnreadableLine`; `number` is "#N".
    package static func prUnreadable(_ number: String) -> String {
        "Could not read pull request \(number) from GitHub — try again."
    }

    /// "#12" from `https://github.com/acme/repo/pull/12` (Go `prNumber`);
    /// nil for a URL that names no pull request.
    package static func number(_ url: String) -> String? {
        guard let range = url.range(of: "/pull/", options: .backwards) else { return nil }
        var tail = url[range.upperBound...]
        if tail.hasSuffix("/") { tail = tail.dropLast() }
        guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "#\(tail)"
    }

    /// The link's label: "PR #12", or "PR" for a URL without a number.
    package static func label(_ url: String) -> String { number(url).map { "PR \($0)" } ?? "PR" }

    /// The rolled-back row's line while its revert PR waits.
    package static func revertLine(_ label: String) -> String { "\(revertLead) \(label) \(revertTail)" }

    /// The line over Accepted edits after a `coach sync-prs` that could not
    /// read some PRs (`sync_code`; nil when it read them all) or failed
    /// outright. Never the CLI's `sync_error`: that joins one line per row,
    /// with proposal ids and gh's words.
    package static func syncLine(code: String) -> String {
        switch code {
        case "no_gh": noGH
        case "timeout": timeout
        default: syncFailed
        }
    }

    /// A card's line for a pull-request refusal code, nil for any other code
    /// (or when the file or PR it names is unknown: the CLI's line then).
    /// GitHub's or git's own words, which the CLI adds after its sentence,
    /// stay for the codes where they tell the owner what went wrong.
    package static func refusal(code: String, cliError: String, path: String?, prURL: String) -> String? {
        let sentence: String
        var detail = false
        switch code {
        case "no_gh": sentence = noGH
        case "base_differs":
            guard let path else { return nil }
            sentence = baseDiffers(path: path)
        case "push_failed": sentence = pushFailed; detail = true
        case "pr_failed": sentence = prFailed; detail = true
        case "timeout": sentence = timeout
        case "pr_unreadable":
            guard let number = number(prURL) else { return nil }
            sentence = prUnreadable(number); detail = true
        case "origin_moved": sentence = originMoved
        case "github_unreachable": sentence = unreachable
        case "in_progress": sentence = inProgress
        default: return nil
        }
        guard detail, let range = cliError.range(of: sentence) else { return sentence }
        let tail = cliError[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? sentence : "\(sentence) \(tail)"
    }

    /// The codes whose card offers Retry: GitHub or the network failed and
    /// nothing changed.
    package static func retryable(_ code: String?) -> Bool {
        ["push_failed", "pr_failed", "timeout", "pr_unreadable", "github_unreachable"].contains(code ?? "")
    }

    /// `text` with its `backtick` spans as inline code (the `gh auth login`
    /// command); the backticks themselves are dropped. An odd count of
    /// backticks is no code span: the text stays as it is.
    package static func styled(_ text: String) -> AttributedString {
        guard text.filter({ $0 == "`" }).count.isMultiple(of: 2) else { return AttributedString(text) }
        var out = AttributedString()
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            var run = AttributedString(String(part))
            if index.isMultiple(of: 2) == false { run.inlinePresentationIntent = .code }
            out += run
        }
        return out
    }
}

/// The Roll Back sheet shown when the destination changed since the accept
/// (`changed_since`). A working-copy edit offers Roll Back Anyway (`--force`);
/// a pull-request edit (`prURL` set) cannot be forced — a revert pull request
/// needs the merged text on the default branch — so its sheet keeps the diff,
/// says to revert by hand and only closes.
package struct CoachRollbackTexts: Equatable {
    package let title: String
    package let body: String
    /// Roll Back Anyway is offered: the working-copy route only.
    package let offersForce: Bool
    /// The dismiss button: Cancel beside Roll Back Anyway, else Close.
    package let dismiss: String

    package static let rollBackAnyway = "Roll Back Anyway"
    package static let noDiff = "No diff available."

    package init(_ proposal: CoachProposal) {
        if proposal.prURL.isEmpty {
            title = "The text changed since you accepted"
            body = "\(proposal.destinationLabel) was edited after “\(proposal.title)”. Rolling back overwrites those edits."
            offersForce = true
            dismiss = "Cancel"
        } else {
            let file = proposal.repoRelativePath ?? proposal.destinationLabel
            title = "The file changed since the merge"
            body = "\(file) on the default branch changed since the merge — revert it by hand in a pull request."
            offersForce = false
            dismiss = "Close"
        }
    }
}
