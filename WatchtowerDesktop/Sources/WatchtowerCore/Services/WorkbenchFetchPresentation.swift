import Foundation

/// Where the branch popover's `git fetch origin` stands for one repository
/// (board #563). In memory only: the first popover after launch fetches.
package struct GitFetchState: Equatable, Sendable {
    /// A fetch is in flight; no second one starts.
    package var running = false
    /// When the last fetch started, whatever its outcome — what the
    /// background fetch's rarity counts from, so an offline Mac does not
    /// retry on every open.
    package var lastAttemptAt: Date?
    /// When the last successful fetch finished.
    package var lastFetchedAt: Date?
    /// The quiet note of the last failed fetch; nil after a success.
    package var failure: String?
    /// The last try found no origin remote. Not final: the next due try
    /// checks again (an agent may add origin meanwhile).
    package var noRemote = false

    package init(
        running: Bool = false,
        lastAttemptAt: Date? = nil,
        lastFetchedAt: Date? = nil,
        failure: String? = nil,
        noRemote: Bool = false
    ) {
        self.running = running
        self.lastAttemptAt = lastAttemptAt
        self.lastFetchedAt = lastFetchedAt
        self.failure = failure
        self.noRemote = noRemote
    }
}

/// The branch popover's fetch row (board #563): when a background fetch is
/// due, the "Fetched 2m ago" caption and the quiet failure note. Pure.
package enum WorkbenchFetchPresentation {
    /// A popover opening fetches in the background only when the last try
    /// is older than this.
    package static let backgroundInterval: TimeInterval = 5 * 60

    /// Whether opening the popover starts a background fetch: never while
    /// one runs, otherwise when the last try — one that found no origin
    /// included — is older than `backgroundInterval` (or there was none).
    package static func isBackgroundFetchDue(_ state: GitFetchState?, now: Date) -> Bool {
        guard let state else { return true }
        guard !state.running else { return false }
        guard let last = state.lastAttemptAt else { return true }
        return now.timeIntervalSince(last) >= backgroundInterval
    }

    /// `Fetching origin…`, `No origin remote`, `Fetched just now`,
    /// `Fetched 2m ago`, `Not fetched yet`.
    package static func caption(_ state: GitFetchState?, now: Date) -> String {
        if state?.running == true { return "Fetching origin…" }
        if state?.noRemote == true { return "No origin remote" }
        guard let fetched = state?.lastFetchedAt else { return "Not fetched yet" }
        return "Fetched " + ago(now.timeIntervalSince(fetched))
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(s / 60)m ago"
        case ..<86400: return "\(s / 3600)h ago"
        default: return "\(s / 86400)d ago"
        }
    }

    /// The quiet note of a fetch that did not happen, nil for a success or
    /// a repository without origin. git's first line, without its
    /// `fatal: ` — the branch list still works on the local data.
    /// `unattended`: the automatic fetch, which uses no ssh agent; an ssh
    /// key it could not use is then the agent's, and ↻ fetches with it.
    package static func failure(_ result: WorkbenchGitFetchResult, unattended: Bool = false) -> String? {
        guard !result.fetched, !result.noRemote else { return nil }
        let detail: String
        if result.timedOut {
            detail = "it did not answer within 20 s"
        } else if !result.refused.isEmpty {
            detail = WorkbenchBranchPresentation.refusalText(refused: result.refused, detail: result.refusedDetail)
        } else if !result.error.isEmpty {
            detail = firstLine(result.error) + credentialsHint(result.error, unattended: unattended)
        } else if !result.note.isEmpty {
            detail = result.note
        } else {
            detail = "git gave no reason"
        }
        return "Couldn't fetch origin: \(detail)"
    }

    /// A call that did not come back with an envelope.
    package static func failure(callError text: String) -> String {
        "Couldn't fetch origin: \(text)"
    }

    /// Why a remote that wanted credentials failed, in git's words: an https
    /// login the fetch may not ask for (no prompt, no credential helper), or
    /// an ssh key or host key it may not confirm.
    private static func credentialsHint(_ error: String, unattended: Bool) -> String {
        if error.contains("terminal prompts disabled") {
            return " — Watchtower's fetch uses no credential helper and never asks for a password"
        }
        if unattended, error.contains("Permission denied") {
            return " — the automatic fetch uses no ssh agent; press ↻ to fetch with it"
        }
        if ["Permission denied", "Host key verification failed"].contains(where: { error.contains($0) }) {
            return " — Watchtower's fetch never asks for a key passphrase and does not use a custom core.sshCommand"
        }
        return ""
    }

    private static func firstLine(_ error: String) -> String {
        let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("fatal: ") ? String(trimmed.dropFirst("fatal: ".count)) : trimmed
    }
}
