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
/// through the CLI, which validates keys against the live site. Whether the
/// grant can read and edit Confluence comes from `confluence access --json`
/// (the stored token only), which drives "Allow editing".
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
            guard let synced = Self.isoParser.date(from: lastSyncedAt) else { return docs }
            return "\(docs) · synced \(Self.relativeFormatter.localizedString(for: synced, relativeTo: now))"
        }

        /// Built once: the rows re-render on every 15 s status poll.
        private static let isoParser = ISO8601DateFormatter()
        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter
        }()
    }

    /// One `confluence spaces --json` row (cmd/confluence.go
    /// `confluenceSpaceJSON`). `selected` is ignored: the DB is the truth.
    private struct LiveSpace: Decodable {
        let key: String
        let name: String
    }

    /// `confluence access --json` (cmd/confluence.go `confluenceAccess`): the
    /// stored grant's Confluence read and write scopes.
    private struct Access: Decodable {
        let read: Bool
        let write: Bool
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
    /// Why the last "Grant Confluence access" or "Allow editing" failed (the
    /// Jira login flow's own error), mirrored here so it shows next to the
    /// button.
    private(set) var reconsentError: String?
    /// The grant carries the Confluence read scopes (`confluence access`).
    private(set) var hasReadAccess = false
    /// The grant carries the Confluence write scopes: the assistant may
    /// propose page edits (`edit_confluence_page`, each behind Approve).
    private(set) var canEdit = false

    /// "Allow editing" is offered when the site is readable but not writable
    /// (spec 2026-09-30 §2) — never over the consent screen, whose own
    /// button grants read access first.
    var showsAllowEditing: Bool { hasReadAccess && !canEdit && !needsConsent }

    private let dbPool: DatabasePool
    private let runner: CLIRunnerProtocol?
    private let onReconsent: @MainActor (Int64) async -> String?
    private let onSelected: @MainActor () async -> Void
    private let onAllowEditing: @MainActor (Int64) async -> String?
    /// The last successful live listing, reused by `refreshStatuses()` so a
    /// status poll never hits the network.
    private var liveSpaces: [LiveSpace] = []
    /// Bumped by every `load()`; only the newest applies its results and
    /// clears `isLoading`, so overlapping loads never land out of order.
    private var loadGeneration = 0
    /// Whether `errorMessage` came from a failed DB read — the only kind a
    /// later successful read may clear (a CLI error stays until the next
    /// CLI call).
    private var errorIsFromDBRead = false

    /// `onReconsent` runs the Jira account's login flow with
    /// `--with-confluence` and returns its error, nil on success (AppState
    /// wires it to `JiraAccountsViewModel`). `onSelected` runs after a
    /// successful select — AppState asks the daemon to sync now (the tray's
    /// Sync Now) so the new space starts without waiting for the next poll.
    /// `onAllowEditing` runs the login flow with `--with-confluence-write`
    /// and returns its error, nil on success.
    init(
        accountID: Int64,
        dbPool: DatabasePool,
        runner: CLIRunnerProtocol?,
        onReconsent: @escaping @MainActor (Int64) async -> String? = { _ in nil },
        onAllowEditing: @escaping @MainActor (Int64) async -> String? = { _ in nil },
        onSelected: @escaping @MainActor () async -> Void = {}
    ) {
        self.accountID = accountID
        self.dbPool = dbPool
        self.runner = runner
        self.onReconsent = onReconsent
        self.onSelected = onSelected
        self.onAllowEditing = onAllowEditing
    }

    // MARK: - Load

    /// Lists the site's spaces through the CLI and merges them with the DB.
    /// On a CLI failure the selected spaces still show from the DB alone.
    func load() async {
        guard let runner else {
            setError("Watchtower CLI not found")
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let access = await readAccess(runner)
        let listing: Result<[LiveSpace], Error>
        do {
            let data = try await runner.run(args: [
                "confluence", "spaces", "--account", String(accountID), "--json"
            ])
            listing = .success(try JSONDecoder().decode([LiveSpace].self, from: data))
        } catch {
            listing = .failure(error)
        }
        let statuses = await readStatuses()
        // A newer load started meanwhile: it owns the results and the flag.
        guard generation == loadGeneration else { return }
        defer { isLoading = false }
        errorMessage = nil
        errorIsFromDBRead = false
        switch listing {
        case .success(let live):
            liveSpaces = live
            needsConsent = false
            consentMessage = nil
        case .failure(let error):
            liveSpaces = []
            apply(error)
        }
        applyAccess(access, listingFailed: liveSpacesFailed(listing))
        applyStatuses(statuses)
    }

    private func liveSpacesFailed(_ listing: Result<[LiveSpace], Error>) -> Bool {
        if case .failure = listing { return true }
        return false
    }

    /// `confluence access --json`: the stored token only, no network.
    private func readAccess(_ runner: CLIRunnerProtocol) async -> Result<Access, Error> {
        do {
            let data = try await runner.run(args: [
                "confluence", "access", "--account", String(accountID), "--json"
            ])
            return .success(try JSONDecoder().decode(Access.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    /// A failed access check hides "Allow editing" and says why — unless the
    /// listing failed too, whose error (usually the same cause) is shown.
    private func applyAccess(_ result: Result<Access, Error>, listingFailed: Bool) {
        switch result {
        case .success(let access):
            hasReadAccess = access.read
            canEdit = access.write
        case .failure(let error):
            hasReadAccess = false
            canEdit = false
            if !listingFailed {
                setError("Couldn't check Confluence editing access: \(Self.message(from: error))")
            }
        }
    }

    /// Re-reads the selected spaces' sync state from the DB (the daemon
    /// writes it from another process, so nothing observes it live) and
    /// re-merges with the last live listing. No CLI call.
    func refreshStatuses() async {
        applyStatuses(await readStatuses())
    }

    private func readStatuses() async -> Result<[(ExtSource, Int)], Error> {
        let accountID = accountID
        do {
            return .success(try await dbPool.read { db -> [(ExtSource, Int)] in
                try ExtSourceQueries.fetchForJiraAccount(db, accountID: accountID).map { src in
                    (src, try ExtSourceQueries.documentCount(db, sourceID: src.id))
                }
            })
        } catch {
            return .failure(error)
        }
    }

    private func applyStatuses(_ result: Result<[(ExtSource, Int)], Error>) {
        switch result {
        case .success(let rows):
            spaces = Self.merge(live: liveSpaces, sources: rows)
            if errorIsFromDBRead {
                errorMessage = nil
                errorIsFromDBRead = false
            }
        case .failure(let error):
            errorMessage = "Failed to read Confluence sync state: \(error.localizedDescription)"
            errorIsFromDBRead = true
        }
    }

    private func setError(_ message: String) {
        errorMessage = message
        errorIsFromDBRead = false
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
    /// CLI's message. A successful select also asks the daemon to sync now
    /// (best-effort); an unselect needs no sync.
    func setSelected(_ key: String, _ on: Bool) async {
        guard let runner else {
            setError("Watchtower CLI not found")
            return
        }
        guard !busyKeys.contains(key) else { return }
        busyKeys.insert(key)
        defer { busyKeys.remove(key) }
        errorMessage = nil
        errorIsFromDBRead = false
        do {
            _ = try await runner.run(args: [
                "confluence", on ? "select" : "unselect", key, "--account", String(accountID)
            ])
        } catch {
            apply(error)
            return
        }
        if on {
            await onSelected()
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
        reconsentError = nil
        reconsentError = await onReconsent(accountID)
        await load()
    }

    /// "Allow editing": the Jira account's login flow with
    /// `--with-confluence-write`, then a reload (which re-reads the access).
    /// Detached like `reconsent()`; shares its in-flight flag and error.
    func allowEditing() {
        Task { await allowEditingAsync() }
    }

    /// The awaitable body of `allowEditing()`, split out for tests.
    func allowEditingAsync() async {
        guard !isReconsenting else { return }
        isReconsenting = true
        defer { isReconsenting = false }
        reconsentError = nil
        reconsentError = await onAllowEditing(accountID)
        await load()
    }

    // MARK: - Errors

    /// Every consent-shaped CLI failure (scopes missing, sign-in expired, no
    /// token) names the same remedy: `jira login … --with-confluence` (dual
    /// path: the Go texts live in cmd/confluence.go's `confluenceHints`). The
    /// CLI prints its error as the last stderr line (cmd/root.go), after any
    /// log lines the command wrote.
    private func apply(_ error: Error) {
        let message = Self.message(from: error)
        if message.contains("--with-confluence") {
            needsConsent = true
            consentMessage = message
        } else {
            setError(message)
        }
    }

    private static func message(from error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return last.isEmpty ? "watchtower exited with code \(code)" : last
        }
        return error.localizedDescription
    }
}
