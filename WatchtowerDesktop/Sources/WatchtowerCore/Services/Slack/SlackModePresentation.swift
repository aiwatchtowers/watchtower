import Foundation

/// A colour of the Slack mode pane, mapped to `Tone` by the view.
package enum SlackModeTone: Equatable, Sendable {
    case success, warning, blue, gray
}

/// Connections → Slack, the **Slack mode** section (screens spec
/// `2026-11-15-slack-full-live-screens-design.md` §1): the chip, the
/// one-sentence summary and the Live block. A pure value over the accounts,
/// the Live status rows and `SlackLiveStatusCenter`'s state; it owns every
/// string, the view only lays it out (`SlackModePresentationTests`).
///
/// The mode is `SlackMode.derive` (SLACKMODE-01, never stored); the one
/// display-only override is **Shared app**: an enabled account on the
/// retired shared app while no company-app account makes the mode Full.
package struct SlackModePresentation: Equatable, Sendable {
    package enum Display: Equatable, Sendable {
        case full, fullLive, live, off, sharedApp
    }

    /// What the Live block shows under its header.
    package enum LiveBlock: Equatable, Sendable {
        /// The center's first read has not finished.
        case loading
        /// Read, no rows.
        case empty
        case rows
        /// The read failed before any row was read: only the warning.
        case readFailed
    }

    /// One provider's line: its newest check decides it.
    package struct LiveRow: Equatable, Sendable, Identifiable {
        package var id: String { provider }
        package let provider: String
        package let status: String
        package let reason: String?
        /// "checked 5 h ago"; nil for an unreadable stamp.
        package let age: String?
        package let tone: SlackModeTone
    }

    package let display: Display
    package let liveRows: [LiveRow]
    package let liveBlock: LiveBlock
    package let isBusy: Bool
    /// The warning line of a failed probe or read; nil when none.
    package let problem: String?
    package let showsCheckAgain: Bool
    package let checkAgainEnabled: Bool
    package let showsTryAgain: Bool
    /// §5: the banner over the pane while an account syncs through the
    /// retired shared app; nil otherwise.
    package let sharedAppBanner: SharedAppBanner?

    package let title = "Slack mode"
    package let liveTitle = "Live"
    package let checkAgain = "Check again"
    package let tryAgain = "Try again"
    package let loadingLine = "Reading the Live status…"
    package let emptyLine = "Live has not been checked yet."
    private let sharedLabel: String

    /// - Parameter sharedAppAccountIDs: accounts `slack accounts --json`
    ///   reports with `shared_app` (Go decides; empty until it is wired).
    package init(
        accounts: [SlackAccount],
        sharedAppAccountIDs: Set<Int>,
        liveStatuses: [SlackLiveStatusRow],
        isRunning: Bool,
        hasRead: Bool,
        lastError: SlackLiveError?,
        now: Date
    ) {
        let syncing = accounts.filter { $0.enabled && !$0.isGone }
        let shared = syncing.filter { sharedAppAccountIDs.contains($0.id) }
        let full = syncing.contains { $0.isOK && !sharedAppAccountIDs.contains($0.id) }
        // The chip reads the same verdicts as the Live block: each
        // provider's newest check, so an older ok cannot say "Live".
        let verdicts = Self.liveVerdicts(liveStatuses)
        let mode = SlackMode.derive(full: full, liveStatuses: verdicts)
        let liveOn = verdicts.contains("ok")
        display = switch mode {
        case .full: liveOn ? .fullLive : .full
        case .live, .off: shared.isEmpty ? (mode == .live ? .live : .off) : .sharedApp
        }
        sharedLabel = shared.first.map(Self.label) ?? ""
        // It goes once Slack stops the token: the row then shows its Re-login.
        sharedAppBanner = shared.first { $0.isOK }.map { SharedAppBanner(label: Self.label($0)) }

        let rows = Self.liveRows(Self.newestBatches(liveStatuses), accounts: accounts, now: now)
        liveRows = rows
        let readFailed = lastError?.kind == .read
        liveBlock = if !hasRead { .loading } else if !rows.isEmpty { .rows } else if readFailed { .readFailed } else { .empty }
        isBusy = isRunning
        problem = lastError.map(Self.problem)
        showsCheckAgain = hasRead && !readFailed
        checkAgainEnabled = !isRunning
        showsTryAgain = readFailed
    }

    // MARK: - §1.1 the chip and the summary

    package var chip: String {
        switch display {
        case .full: "Full"
        case .fullLive: "Full · Live on"
        case .live: "Live"
        case .off: "Off"
        case .sharedApp: "Shared app"
        }
    }

    package var chipTone: SlackModeTone {
        switch display {
        case .full, .fullLive: .success
        case .live: .blue
        case .off: .gray
        case .sharedApp: .warning
        }
    }

    package var summary: String {
        switch display {
        case .full:
            "Synced on this Mac through your workspace's own Slack app. Every feature works."
        case .fullLive:
            "Synced on this Mac through your workspace's own Slack app. "
                + "Chats also read Slack through Live for what is not synced."
        case .live:
            "Chats and automations read Slack through your Claude or ChatGPT connector. "
                + "Nothing is synced, so digests, the Inbox, tracks and people need your workspace's app."
        case .off:
            "Slack is not connected. Connect your workspace's app to sync, or turn on the Slack "
                + "connector in your Claude or ChatGPT account to ask about Slack in Chats."
        case .sharedApp:
            "\(sharedLabel) syncs through Watchtower's old shared Slack app until Slack turns it off."
        }
    }

    /// Shown under the rows while a probe pass runs.
    package var busyLine: String? { isBusy ? "Checking Live… this takes a few seconds." : nil }

    // MARK: - §1.2 the Live block

    private static let providerOrder = ["claude", "codex"]

    package static func providerName(_ provider: String) -> String {
        switch provider {
        case "claude": "Claude"
        case "codex": "ChatGPT (Codex)"
        default: provider
        }
    }

    /// One provider's newest check: one probe writes a row per team (and
    /// team "") at one instant, and that batch is the provider's verdict —
    /// `ok` when any row in it is, else its first row by team.
    private struct Batch {
        let provider: String
        let checkedAt: String
        let okTeams: [String]
        let verdict: SlackLiveStatusRow
    }

    /// The status of each provider's newest batch: the Live input of
    /// `SlackMode.derive`. Go twin: `slackmode.LiveVerdicts`, both checked
    /// over the shared fixture (SLACKMODE-01).
    package static func liveVerdicts(_ statuses: [SlackLiveStatusRow]) -> [String] {
        newestBatches(statuses).map(\.verdict.status)
    }

    /// Claude first, then ChatGPT (Codex), then any other provider by name.
    private static func newestBatches(_ statuses: [SlackLiveStatusRow]) -> [Batch] {
        let byProvider = Dictionary(grouping: statuses, by: \.provider)
        let providers = byProvider.keys.sorted { lhs, rhs in
            let li = providerOrder.firstIndex(of: lhs) ?? providerOrder.count
            let ri = providerOrder.firstIndex(of: rhs) ?? providerOrder.count
            return li == ri ? lhs < rhs : li < ri
        }
        return providers.compactMap { provider in
            guard let rows = byProvider[provider], let newest = rows.map(\.checkedAt).max() else { return nil }
            let batch = rows.filter { $0.checkedAt == newest }.sorted { $0.teamID < $1.teamID }
            let ok = batch.filter { $0.status == "ok" }
            guard let verdict = ok.first ?? batch.first else { return nil }
            return Batch(provider: provider, checkedAt: newest, okTeams: ok.map(\.teamID), verdict: verdict)
        }
    }

    private static func liveRows(_ batches: [Batch], accounts: [SlackAccount], now: Date) -> [LiveRow] {
        batches.map { batch in
            let age = TimeFormatting.parseISO(batch.checkedAt).map { Self.age(from: $0, now: now) }
            if !batch.okTeams.isEmpty {
                return okRow(provider: batch.provider, teams: batch.okTeams, accounts: accounts, age: age)
            }
            let verdict = verdict(
                status: batch.verdict.status, errorClass: batch.verdict.errorClass, provider: batch.provider)
            return LiveRow(provider: providerName(batch.provider), status: verdict.status, reason: verdict.reason,
                           age: age, tone: verdict.tone)
        }
    }

    /// An account's name in a sentence: its label or team name, else the team
    /// id, never blank.
    static func label(_ account: SlackAccount) -> String {
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let team = account.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !team.isEmpty { return team }
        return account.teamID.isEmpty ? "Slack account #\(account.id)" : account.teamID
    }

    private static func okRow(provider: String, teams: [String], accounts: [SlackAccount], age: String?) -> LiveRow {
        var seen = Set<String>()
        let names = teams.filter { !$0.isEmpty && seen.insert($0).inserted }.sorted().map { team in
            accounts.first { $0.teamID == team && !$0.isGone }.map(label) ?? team
        }
        if names.isEmpty {
            return LiveRow(provider: providerName(provider), status: "On · workspace not identified",
                           reason: "Chats use it; Watchtower could not tell which workspace it reads.",
                           age: age, tone: .success)
        }
        return LiveRow(provider: providerName(provider), status: "On · " + names.joined(separator: ", "),
                       reason: nil, age: age, tone: .success)
    }

    private static func verdict(
        status: String, errorClass: String, provider: String
    ) -> (status: String, reason: String, tone: SlackModeTone) {
        switch status {
        case "needs_admin":
            return ("Waiting for your Slack admin", "Your workspace admin must approve the connector.", .warning)
        case "no_plan":
            return ("Not in your plan", "Your plan has no Slack connector.", .gray)
        case "unavailable":
            let reason = errorClass == "sandbox"
                ? "The chat sandbox is not available on this Mac."
                : "The connector did not answer. Check again later."
            return ("Unavailable", reason, .warning)
        default:
            return ("Not connected", notConnectedReason(errorClass, provider: provider), .gray)
        }
    }

    private static func notConnectedReason(_ errorClass: String, provider: String) -> String {
        switch errorClass {
        case "cli_missing":
            provider == "codex" ? "Codex is not installed on this Mac." : "Claude Code is not installed on this Mac."
        case "connectors_off": "Connectors are off in Watchtower's chat settings."
        case "disabled": "The Slack connector is switched off in Watchtower's chat settings."
        case "policy": "Your organization's policy turns this off."
        case "workspace_not_connected": "The connector reads a different Slack workspace."
        case "connector_id_unknown": "Codex has not loaded its Slack app yet. Check again later."
        default: "Turn on the Slack connector in your Claude or ChatGPT account."
        }
    }

    /// "checked just now" under 1 min, "N min" under 60 min, "N h" under
    /// 48 h, then "N d". Never a bare "on" (parent spec §1).
    package static func age(from date: Date, now: Date) -> String {
        "checked " + ago(from: date, now: now)
    }

    /// "just now", "N min ago", "N h ago", "N d ago" (the thresholds of `age`).
    static func ago(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 48 * 3600 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }

    private static func problem(_ error: SlackLiveError) -> String {
        let message = sentence(error.message)
        switch error.kind {
        case .probe: return "The \(providerName(error.provider)) Live Slack check failed: \(message)"
        case .read: return "Could not read the Live Slack status: \(message)"
        }
    }

    /// The message with a closing full stop, unless it already ends a sentence.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }
}
