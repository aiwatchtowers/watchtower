import Foundation
import GRDB
import WatchtowerCore

/// Drives the Confluence spaces picker of one Jira account in Settings →
/// Jira. Confluence rides the Jira account's OAuth grant, so the account id
/// is the whole identity here.
///
/// The live space list comes from `watchtower confluence spaces --json`;
/// which spaces are selected, and how far their sync got, comes from the DB
/// (`ext_sources` + `ext_documents`) — that is what the daemon actually
/// syncs. Selecting runs `confluence select|unselect`; every write goes
/// through the CLI, which validates keys against the live site.
///
/// Owned by AppState (one per Jira account, `confluenceSpacesViewModel(
/// forJiraAccount:)`) so a select still running when the Settings pane goes
/// away finishes and is visible on return.
@MainActor
@Observable
final class ConfluenceSpacesViewModel {
    struct SpaceRow: Identifiable, Equatable {
        let key: String
        let name: String
        let selected: Bool
        /// The source's `ext_sources.status`; empty when not selected.
        let status: String
        let error: String
        let docCount: Int
        let backfillDone: Bool
        let lastSyncedAt: String

        var id: String { key }

        /// "Syncing…" until the first full enumeration finishes — a
        /// budget-cut first run still stamps `lastSyncedAt`, so the timestamp
        /// alone would call an unfinished backfill done. Then
        /// "N documents · synced <relative time>".
        func statusLine(now: Date = Date()) -> String {
            let docs = "\(docCount) \(docCount == 1 ? "document" : "documents")"
            if !backfillDone {
                return docCount > 0 ? "Syncing… · \(docs)" : "Syncing…"
            }
            guard let synced = ISO8601DateFormatter().date(from: lastSyncedAt) else { return docs }
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            return "\(docs) · synced \(relative.localizedString(for: synced, relativeTo: now))"
        }
    }

    /// One `confluence spaces --json` row (cmd/confluence.go
    /// `confluenceSpaceJSON`). `selected` is ignored: the DB is the truth.
    private struct LiveSpace: Decodable {
        let key: String
        let name: String
    }

    let accountID: Int64
    private(set) var spaces: [SpaceRow] = []
    private(set) var isLoading = false
    var errorMessage: String?
    /// The account's grant lacks the Confluence scopes (or expired): the CLI
    /// answered with its `jira login … --with-confluence` hint.
    private(set) var needsConsent = false
    /// The CLI's own hint text, shown as the consent explanation.
    private(set) var consentMessage: String?
    /// Keys with a select/unselect in flight (their toggles are disabled).
    private(set) var busyKeys: Set<String> = []
    private(set) var isReconsenting = false

    private let dbPool: DatabasePool
    private let runner: CLIRunnerProtocol?
    private let onReconsent: @MainActor (Int64) async -> Void
    /// The last successful live listing, reused by `refreshStatuses()` so a
    /// status poll never hits the network.
    private var liveSpaces: [LiveSpace] = []

    /// `onReconsent` runs the Jira account's login flow with
    /// `--with-confluence` (AppState wires it to `JiraAccountsViewModel`).
    init(
        accountID: Int64,
        dbPool: DatabasePool,
        runner: CLIRunnerProtocol?,
        onReconsent: @escaping @MainActor (Int64) async -> Void = { _ in }
    ) {
        self.accountID = accountID
        self.dbPool = dbPool
        self.runner = runner
        self.onReconsent = onReconsent
    }

    // MARK: - Load

    /// Lists the site's spaces through the CLI and merges them with the DB.
    /// On a CLI failure the selected spaces still show from the DB alone.
    func load() async {
        guard let runner else {
            errorMessage = "Watchtower CLI not found"
            return
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let data = try await runner.run(args: [
                "confluence", "spaces", "--account", String(accountID), "--json"
            ])
            liveSpaces = try JSONDecoder().decode([LiveSpace].self, from: data)
            needsConsent = false
            consentMessage = nil
        } catch {
            liveSpaces = []
            apply(error)
        }
        await refreshStatuses()
    }

    /// Re-reads the selected spaces' sync state from the DB (the daemon
    /// writes it from another process, so nothing observes it live) and
    /// re-merges with the last live listing. No CLI call.
    func refreshStatuses() async {
        let accountID = accountID
        do {
            let rows = try await dbPool.read { db -> [(ExtSource, Int)] in
                try ExtSourceQueries.fetchForJiraAccount(db, accountID: accountID).map { src in
                    (src, try ExtSourceQueries.documentCount(db, sourceID: src.id))
                }
            }
            spaces = Self.merge(live: liveSpaces, sources: rows)
        } catch {
            errorMessage = "Failed to read Confluence sync state: \(error.localizedDescription)"
        }
    }

    private static func merge(live: [LiveSpace], sources: [(ExtSource, Int)]) -> [SpaceRow] {
        var byKey: [String: (ExtSource, Int)] = [:]
        for entry in sources { byKey[entry.0.containerKey] = entry }
        var rows = live.map { space -> SpaceRow in
            guard let (src, count) = byKey.removeValue(forKey: space.key) else {
                return SpaceRow(
                    key: space.key, name: space.name, selected: false, status: "", error: "",
                    docCount: 0, backfillDone: false, lastSyncedAt: ""
                )
            }
            return row(src, count, name: space.name)
        }
        // Selected but absent from the live list (deleted on the site, or the
        // listing failed): still shown, so it can be unselected.
        rows += byKey.values.map { row($0.0, $0.1, name: $0.0.containerName) }
        return rows.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
        }
    }

    private static func row(_ src: ExtSource, _ count: Int, name: String) -> SpaceRow {
        SpaceRow(
            key: src.containerKey, name: name.isEmpty ? src.containerKey : name, selected: true,
            status: src.status, error: src.error, docCount: count,
            backfillDone: src.backfillDone, lastSyncedAt: src.lastSyncedAt
        )
    }

    // MARK: - Select

    /// Runs `confluence select|unselect KEY --account N`, then reloads. A
    /// failure keeps the row as it was (the DB is unchanged) and reports the
    /// CLI's message.
    func setSelected(_ key: String, _ on: Bool) async {
        guard let runner else {
            errorMessage = "Watchtower CLI not found"
            return
        }
        guard !busyKeys.contains(key) else { return }
        busyKeys.insert(key)
        defer { busyKeys.remove(key) }
        errorMessage = nil
        do {
            _ = try await runner.run(args: [
                "confluence", on ? "select" : "unselect", key, "--account", String(accountID)
            ])
        } catch {
            apply(error)
            return
        }
        await load()
    }

    // MARK: - Re-consent

    /// "Grant Confluence access": the Jira account's login flow with
    /// `--with-confluence`, then a reload. Detached so the button returns at
    /// once; the task lives on this AppState-owned VM.
    func reconsent() {
        Task { await reconsentAsync() }
    }

    /// The awaitable body of `reconsent()`, split out for tests (the
    /// `JiraAccountsViewModel.refreshAsync` precedent).
    func reconsentAsync() async {
        guard !isReconsenting else { return }
        isReconsenting = true
        defer { isReconsenting = false }
        await onReconsent(accountID)
        await load()
    }

    // MARK: - Errors

    /// Every consent-shaped CLI failure (scopes missing, sign-in expired, no
    /// token) names the same remedy: `jira login … --with-confluence`. The
    /// CLI prints its error as the last stderr line (cmd/root.go), after any
    /// log lines the command wrote.
    private func apply(_ error: Error) {
        let message: String
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            message = last.isEmpty ? "watchtower exited with code \(code)" : last
        } else {
            message = error.localizedDescription
        }
        if message.contains("--with-confluence") {
            needsConsent = true
            consentMessage = message
        } else {
            errorMessage = message
        }
    }
}
