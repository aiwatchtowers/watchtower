import Foundation

/// Every visible string of the tuning chat panel (spec 2026-11-03 §3, §4.4),
/// in one place and tested in `TuningChatTextsTests`. Views read text from here.
package enum TuningChatTexts {
    // MARK: Panel

    package static let title = "Tuning"
    package static let newChat = "New tuning chat"
    package static let newButton = "New"
    package static let closeHelp = "Close (Esc)"
    package static let tune = "Tune"
    package static let tuneIcon = "slider.horizontal.3"
    package static let tuneHelp = "Tune prompts, skills and agent instructions in a chat"
    package static let placeholder = "Ask about cost, prompts, skills or instructions…"
    package static let loading = "Reading this workbench's analytics…"
    package static let noTools = "Tuning tools need Claude or Codex — pick one in Settings → System → AI"
    package static let noToolsDetail = "Without them the chat can talk, but it cannot read the report, prompts or skills, or propose an edit."
    package static let openSettings = "Open Settings"
    package static let accepted = "Accepted · measuring for 14 days"
    package static let showAccepted = "Show in Accepted edits"

    // MARK: Load errors

    /// The panel could not open the workbench's tuning chat.
    package static func openFailed(_ reason: String) -> String { "Couldn't open the tuning chat: \(reason)" }

    /// The panel has no database to open the chat on yet.
    package static let notReady = "The tuning chat opens once the database is ready."

    /// The panel's open error offers it again.
    package static let retry = "Retry"

    /// **New** could not create the conversation.
    package static func newChatFailed(_ reason: String) -> String { "Couldn't start a new tuning chat: \(reason)" }

    /// The recent chats or the shown chat's proposal cards could not be read.
    package static func cardsReadFailed(_ reason: String) -> String {
        "Couldn't read the tuning chat's proposals: \(reason)"
    }

    // MARK: Figures and starters

    package struct Figures: Equatable, Sendable {
        package var days: Int
        package var sessions: Int
        package var tasks: Int
        package var costUSD: Double
        package var perTaskUSD: Double?
        package var previousPerTaskUSD: Double?

        package init(
            days: Int,
            sessions: Int,
            tasks: Int,
            costUSD: Double,
            perTaskUSD: Double? = nil,
            previousPerTaskUSD: Double? = nil
        ) {
            self.days = days
            self.sessions = sessions
            self.tasks = tasks
            self.costUSD = costUSD
            self.perTaskUSD = perTaskUSD
            self.previousPerTaskUSD = previousPerTaskUSD
        }
    }

    package static func figures(_ f: Figures) -> String {
        var parts = [count(f.days, "day"), count(f.sessions, "session"), count(f.tasks, "task"), money(f.costUSD)]
        if let perTask = f.perTaskUSD {
            var part = "\(money(perTask)) per task"
            if let previous = f.previousPerTaskUSD { part += " (was \(money(previous)))" }
            parts.append(part)
        }
        return parts.joined(separator: " · ")
    }

    package struct StarterInputs: Sendable {
        package var costPerTaskGrew: Bool
        package var topHintFinding: String?

        package init(costPerTaskGrew: Bool, topHintFinding: String? = nil) {
            self.costPerTaskGrew = costPerTaskGrew
            self.topHintFinding = topHintFinding
        }
    }

    package static func starters(_ s: StarterInputs) -> [ChatStarterPrompt] {
        var out: [ChatStarterPrompt] = []
        if s.costPerTaskGrew {
            out.append(starter("Why did cost per task grow?"))
        }
        if let finding = s.topHintFinding, !finding.isEmpty {
            out.append(ChatStarterPrompt(title: finding, text: "How do I fix this? \(finding)", sendsImmediately: true))
        }
        out.append(starter("Which prompt costs the most?"))
        out.append(ChatStarterPrompt(title: "Tune a skill", text: "Which of my skills should I tune first, and how?",
                                     sendsImmediately: true))
        return Array(out.prefix(4))
    }

    private static func starter(_ text: String) -> ChatStarterPrompt {
        ChatStarterPrompt(title: text, text: text, sendsImmediately: true)
    }

    // MARK: Tool lines

    /// The quiet line of a tuning tool step, nil for any other tool.
    package static func toolLine(name: String, args: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
        func string(_ key: String) -> String? {
            guard let value = object?[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        let days = (object?["days"] as? NSNumber).flatMap { Int(exactly: $0.doubleValue) }.flatMap { $0 > 0 ? $0 : nil }
        switch name {
        case "get_agent_report": return days.map { "Read the \($0)-day report" } ?? "Read the agent report"
        case "list_agent_sessions": return "Listed sessions"
        case "get_agent_session": return "Read a session"
        case "get_llm_usage": return days.map { "Read the \($0)-day LLM usage" } ?? "Read the LLM usage"
        case "list_prompts": return "Listed prompts"
        case "get_prompt": return string("prompt_id").map { "Read prompt \($0)" } ?? "Read a prompt"
        case "list_skills": return "Listed skills"
        case "get_skill": return string("name").map { "Read skill \($0)" } ?? "Read a skill"
        case "get_agent_instructions": return "Read your agent instructions"
        case "list_coach_proposals": return "Read the coach's proposals"
        case "propose_tuning_edit":
            return (string("skill") ?? string("prompt_id")).map { "Proposed an edit to \($0)" } ?? "Proposed an edit"
        default: return nil
        }
    }

    /// The folded line of a settled proposal card, nil while it is open.
    package static func foldedProposal(status: String, title: String) -> String? {
        switch status {
        case "accepted": accepted
        case "declined": "Declined · \(title)"
        case "superseded": "Withdrawn · \(title)"
        case "rolled_back": "Rolled back · \(title)"
        default: nil
        }
    }

    // MARK: Workbench repository files (spec §4.3a, D66–D68)

    /// The open card's diff caption: the file and the branch it would land
    /// on ("" = the branch could not be read: the path only).
    package static func repoCardCaption(path: String, branch: String) -> String {
        guard let on = onBranch(branch, named: true) else { return path }
        return "\(path) · \(on)"
    }

    /// The folded line of an accepted repository edit until its commit is seen.
    package static func acceptedRepoFile(path: String, branch: String) -> String {
        let on = onBranch(branch, named: false).map { " \($0)" } ?? ""
        return "Accepted · wrote \(path)\(on) — commit it yourself"
    }

    /// The folded line once the daemon saw the edit committed (`measure_from`).
    package static let committedRepoFile = "Accepted · committed · measuring for 14 days"
    /// The Accepted edits row of a repository edit not committed yet.
    package static let awaitingCommit = "Accepted · waiting for your commit"
    /// The Accepted edits row of a repository edit not committed 30 days after Accept.
    package static let notCommitted = "Not committed in 30 days — not measured"

    /// The Accepted edits row after Roll Back of a repository file.
    package static func rolledBackRepoFile(path: String) -> String {
        "Rolled back · restored \(path) — commit it yourself"
    }

    /// The card's error line for CLI code `dirty` (Go `coach.RepoDirtyLine`).
    package static func repoDirty(path: String) -> String {
        "\(path) has uncommitted changes — commit or discard them, then press Accept again."
    }

    /// The card's error line for CLI code `not_git` (Go `coach.RepoNotGitLine`).
    package static let repoNotGit = "This workbench folder is not a git repository: "
        + "Watchtower changes files here only where you can review and commit the change."

    /// The folded line of a settled chat proposal, nil while it is open. A
    /// repository edit names the file and branch it wrote (`written`, from
    /// the accept result, else derived from the proposal).
    package static func folded(_ proposal: CoachProposal, written: CoachWrittenFile? = nil) -> String? {
        if proposal.status == "accepted",
           let path = written?.path ?? proposal.repoRelativePath {
            if proposal.measureFrom != nil { return committedRepoFile }
            return acceptedRepoFile(path: path, branch: written?.branch ?? proposal.writtenBranch)
        }
        return foldedProposal(status: proposal.status, title: proposal.title)
    }

    /// "on branch main" / "on main" (`named` false); "on a detached HEAD
    /// (abc1234)" for the CLI's `detached:<short sha>`; nil for "".
    private static func onBranch(_ branch: String, named: Bool) -> String? {
        if branch.isEmpty { return nil }
        if branch.hasPrefix("detached:") { return "on a detached HEAD (\(branch.dropFirst("detached:".count)))" }
        return named ? "on branch \(branch)" : "on \(branch)"
    }

    // MARK: Helpers

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private static func money(_ usd: Double) -> String { String(format: "$%.2f", usd) }
}
