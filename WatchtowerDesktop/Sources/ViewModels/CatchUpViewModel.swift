import Foundation
import GRDB
import WatchtowerCore

// MARK: - Catch-Up absence-recap ViewModel
//
// Drives the recap document UX: a list of persisted `catchup_recaps` rows on the
// left, one rendered recap on the right. Building and regenerating are delegated
// to `watchtower catchup run` (which owns the window resolution, the coverage
// top-up and the compose call); acknowledge is a direct DB write via
// `CatchUpQueries.acknowledge` — the Swift half of the CATCHUP-01 dual path.

/// The window a build covers. `auto` is the default and passes no flags at all,
/// leaving the CLI to resolve "since I was last caught up".
enum CatchUpWindowChoice: Hashable {
    case auto
    case today
    case yesterday
    case threeDays
    case week
    case custom(from: Date, to: Date)

    /// The presets offered by the segmented control, in order. `.custom` is
    /// reached through the range pickers instead.
    static let presets: [Self] = [.auto, .today, .yesterday, .threeDays, .week]

    /// Window flags for `catchup run`. Auto is the *absence* of window flags —
    /// passing one would override the last-acknowledged start the CLI computes.
    var cliArguments: [String] {
        switch self {
        case .auto: []
        case .today: ["--preset", "today"]
        case .yesterday: ["--preset", "yesterday"]
        case .threeDays: ["--preset", "3d"]
        case .week: ["--preset", "week"]
        case let .custom(from, to):
            ["--from", Self.iso.string(from: from), "--to", Self.iso.string(from: to)]
        }
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .threeDays: "3 days"
        case .week: "Week"
        case .custom: "Range"
        }
    }

    /// RFC 3339 — what `catchup run --from/--to` parses (`catchup.ParseWindowTime`).
    /// Pinned to UTC like its sibling `CatchUpQueries.isoFormatter`, so the offset
    /// the CLI parses is stated explicitly rather than inherited from the host.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

@MainActor
@Observable
final class CatchUpViewModel {
    var recaps: [CatchUpRecap] = []
    var selected: CatchUpRecap?
    /// True while a `catchup run` child process is alive (build or regen).
    var isBuilding = false
    var error: String?
    var windowChoice: CatchUpWindowChoice = .auto
    /// Where the next auto window starts — `period_to` of the most recently
    /// acknowledged recap, nil when nothing has been acknowledged yet. Reloaded
    /// with the list, so acknowledging moves the caption immediately.
    var autoWindowStart: Date?

    private let dbPool: DatabasePool
    private var observationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// One-shot: the next `apply` selects the newest recap instead of keeping the
    /// current selection. Set when a CLI run starts (build / regen / feedback, all
    /// of which can insert a row), consumed by the first `apply` that follows —
    /// which is the poll that first sees the CLI's `building` row, so the operator
    /// watches the recap they just asked for build itself. Ordinary polls keep the
    /// selection put.
    private var selectNewestOnNextApply = false

    /// Poll cadence while `catchup run` is building. GRDB ValueObservation cannot
    /// see writes from the separate CLI process, so the list needs a periodic
    /// reload to surface the `building` row and its transition to ready/failed.
    private let pollInterval: Duration = .seconds(1)

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Loading

    /// Observes the recap list. Idempotent — safe to call on every `onAppear`.
    func startObserving() {
        guard observationTask == nil else { return }
        let pool = dbPool
        observationTask = Task { [weak self] in
            do {
                for try await recaps in CatchUpQueries.observeRecaps().values(in: pool) {
                    guard !Task.isCancelled, let self else { break }
                    await self.apply(recaps)
                }
            } catch {
                await MainActor.run { self?.error = error.localizedDescription }
            }
        }
    }

    /// One-shot reload from disk, applied exactly the way the observation does.
    /// Used by the build-time poll, after a CLI run, and after acknowledging,
    /// because cross-process writes are invisible to ValueObservation.
    func reload() async {
        do {
            let recaps = try await dbPool.read { try CatchUpQueries.fetchRecaps($0) }
            await apply(recaps)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ recaps: [CatchUpRecap]) async {
        self.recaps = recaps
        do {
            autoWindowStart = try await dbPool.read { try CatchUpQueries.autoWindowStart($0) }
        } catch {
            // Keep the previous value on a transient read failure — blanking it
            // would read as "you have never been caught up".
            print("CatchUp: autoWindowStart read failed (keeping previous): \(error)")
        }
        // A run just started: jump to the newest row, which is the one it is
        // producing. Without this the pane would keep rendering the previous recap
        // for the whole build and the operator would have to find the new one.
        if selectNewestOnNextApply, let newest = recaps.first {
            selectNewestOnNextApply = false
            selected = newest
            return
        }
        // Re-point the selection at the freshest copy of the selected row (so an
        // acknowledge or a finished build flips its state in place); fall back to
        // the newest recap when the selection is gone or nothing is selected yet.
        if let current = selected, let fresh = recaps.first(where: { $0.id == current.id }) {
            selected = fresh
        } else {
            selected = recaps.first
        }
    }

    /// Test seam for the one-shot select-newest flag: the production setter is
    /// `run`, which spawns a CLI process a unit test must not.
    func markSelectNewestForTesting() {
        selectNewestOnNextApply = true
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }
                await self.reload()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Build / regenerate

    /// Builds a recap for the chosen window. The CLI inserts the `building` row
    /// itself, so the poll surfaces it while composing runs.
    func build() {
        run(arguments: ["catchup", "run", "--json"] + windowChoice.cliArguments,
            failureLabel: "Catch-up failed", parseEnvelope: true)
    }

    /// Rebuilds the selected recap's window as a new row carrying `regen_of_id`,
    /// optionally steered by a correction. Also the Retry action on a failed recap.
    func regenerate(comment: String) {
        guard let recap = selected else { return }
        var args = ["catchup", "run", "--json", "--regen", String(recap.id)]
        if !comment.isEmpty {
            args.append(contentsOf: ["--comment", comment])
        }
        run(arguments: args, failureLabel: "Regenerate failed", parseEnvelope: true)
    }

    /// Every CLI call this VM makes is a potential strong-tier AI run, so they
    /// all share one lifecycle: `isBuilding` (which gates every trigger in the
    /// UI, so a second click can't launch a second concurrent run), the 1 s poll,
    /// and an authoritative reload once the child process is done.
    /// `parseEnvelope` is false for commands that print plain text rather than
    /// the `--json` run envelope.
    ///
    /// All three callers can insert a recap row (feedback only when the comment is
    /// a presentation correction), so all three arm `selectNewestOnNextApply`.
    /// Arming it when no row lands is harmless: the newest recap is then the one
    /// already selected.
    private func run(arguments: [String], failureLabel: String, parseEnvelope: Bool) {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }
        isBuilding = true
        error = nil
        selectNewestOnNextApply = true
        startPolling()

        Task.detached {
            let result = await Self.runCLI(path: cliPath, arguments: arguments)
            await MainActor.run {
                self.isBuilding = false
                self.stopPolling()
                self.error = Self.failureMessage(
                    result, label: failureLabel, parseEnvelope: parseEnvelope
                )
                // Authoritative load once the CLI has finished writing.
                Task { await self.reload() }
            }
        }
    }

    /// Records 👍/👎 on one topic, plus an optional comment.
    ///
    /// A comment makes `catchup feedback` run the learning interpreter and, on a
    /// presentation correction, a whole-recap regen — a strong-tier compose the
    /// CLI performs SYNCHRONOUSLY, so this can take minutes and can insert a new
    /// recap row. It therefore takes the same lifecycle as a build rather than
    /// running unattended. Its output is plain text, not the run envelope, so
    /// nothing is parsed out of stdout.
    func submitFeedback(topicIndex: Int, rating: Int, comment: String) {
        guard let recap = selected else { return }
        var args = [
            "catchup", "feedback", String(recap.id),
            "--topic", String(topicIndex),
            "--rating", rating >= 0 ? "up" : "down"
        ]
        if !comment.isEmpty {
            args.append(contentsOf: ["--comment", comment])
        }
        run(arguments: args, failureLabel: "Feedback failed", parseEnvelope: false)
    }

    /// `catchup run` exits non-zero only on a Go-level error (an invalid window,
    /// a failed insert). A recap that was *composed* and failed exits 0 with
    /// `"status":"failed"` in the envelope, so with `parseEnvelope` the JSON is
    /// inspected too — otherwise a failed recap would report as a clean build.
    /// Internal rather than private so the envelope rules are testable without
    /// spawning the CLI.
    nonisolated static func failureMessage(
        _ result: (exitCode: Int32, stdout: String, stderr: String),
        label: String,
        parseEnvelope: Bool = true
    ) -> String? {
        if result.exitCode != 0 {
            return result.stderr.isEmpty
                ? "\(label) (exit \(result.exitCode))"
                : String(result.stderr.prefix(300))
        }
        guard parseEnvelope,
              let data = result.stdout.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(RunEnvelope.self, from: data),
              envelope.status == "failed" else {
            return nil
        }
        return envelope.error.isEmpty ? label : String(envelope.error.prefix(300))
    }

    /// The two fields of `catchup run --json`'s envelope (`cmd/catchup.go`'s
    /// `catchupRunEnvelope`) the UI reacts to. Both decode tolerantly so a future
    /// envelope field, or an omitted one, never turns a readable run into a
    /// decode failure.
    private struct RunEnvelope: Decodable {
        let status: String
        let error: String

        enum CodingKeys: String, CodingKey {
            case status, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
            error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        }
    }

    // MARK: - Acknowledge

    /// "I'm caught up": marks the selected recap's whole window read across the
    /// five `read_at` surfaces and stamps `acknowledged_at` (CATCHUP-01), then
    /// reloads so the button flips to its label and the auto-window caption moves.
    func acknowledge() async {
        guard let recap = selected else { return }
        do {
            try await dbPool.write { db in
                try CatchUpQueries.acknowledge(db, recap: recap)
            }
            await reload()
        } catch {
            self.error = "Failed to acknowledge: \(error.localizedDescription)"
        }
    }

    // MARK: - Inline source detail

    // Read-only fetches backing the document's expandable source rows, one per
    // ref area the Go gather emits (internal/db/catchup.go). They read the VM's
    // own live `dbPool` — the same handle the recap list streams from — so a
    // source cited by a recap always resolves against current data. nil means the
    // row is gone (pruned, deleted), which the card renders as "no longer
    // available".

    func digest(byID id: Int) -> Digest? {
        try? dbPool.read { try DigestQueries.fetchByID($0, id: id) }
    }

    func track(byID id: Int) -> Track? {
        try? dbPool.read { try TrackQueries.fetchByID($0, id: id) }
    }

    func streamDigest(byID id: Int) -> StreamDigest? {
        try? dbPool.read { try StreamDigestQueries.fetchByID($0, id: id) }
    }

    func meetingRecap(byID id: Int) -> MeetingRecap? {
        try? dbPool.read { try MeetingRecapQueries.fetchByID($0, id: id) }
    }

    func transcript(byID id: Int) -> MeetingTranscript? {
        try? dbPool.read { try MeetingTranscriptQueries.fetch($0, id: Int64(id)) }
    }

    /// A decision ref resolves to its ledger row plus its mention trail — the
    /// mentions are what make a one-line decision checkable.
    func decision(byID id: Int) -> (idea: Idea, mentions: [IdeaMention])? {
        try? dbPool.read { db -> (idea: Idea, mentions: [IdeaMention])? in
            guard let idea = try IdeaQueries.fetchOne(db, id: id) else { return nil }
            return (idea, try IdeaQueries.fetchMentions(db, ideaID: id))
        }
    }

    func inboxItem(byID id: Int) -> InboxItem? {
        try? dbPool.read { try InboxQueries.fetchByID($0, id: id) }
    }

    func target(byID id: Int) -> Target? {
        try? dbPool.read { try TargetQueries.fetchByID($0, id: id) }
    }

    /// "from Ann in #eng" for an inbox source — the same caption the Go gather
    /// builds (`ListCatchupInbox`'s `Meta`). Resolved here because the row
    /// itself carries only namespaced Slack ids, which would read as noise.
    /// Empty when neither side resolves.
    func inboxOrigin(_ item: InboxItem) -> String {
        guard let names = try? dbPool.read({ db -> (sender: String, channel: String) in
            // fetchByID, not fetchDisplayName: the latter falls back to the raw
            // id, and "from 1:U0A9" is worse than no attribution at all.
            let sender = try UserQueries.fetchByID(db, id: item.senderUserID)?.bestName ?? ""
            let channel = try ChannelQueries.fetchByID(db, id: item.channelID)?.name ?? ""
            return (sender, channel)
        }) else {
            return ""
        }

        var parts: [String] = []
        if !names.sender.isEmpty { parts.append("from \(names.sender)") }
        if !names.channel.isEmpty { parts.append("in #\(names.channel)") }
        return parts.joined(separator: " ")
    }

    /// Message deep link for an inbox source: the item's stored permalink when
    /// present, else an archives link built from channel + message ts. Channel
    /// ids are namespaced "<accountID>:C…" since migration 00048; Slack wants the
    /// bare id. Static so the URL rules are testable without a view or DB.
    nonisolated static func slackMessageURL(for item: InboxItem) -> URL? {
        if !item.permalink.isEmpty { return URL(string: item.permalink) }
        guard !item.channelID.isEmpty, !item.messageTS.isEmpty else { return nil }
        let ts = item.messageTS.replacingOccurrences(of: ".", with: "")
        return URL(string: "https://slack.com/archives/\(SlackAccountID.raw(item.channelID))/p\(ts)")
    }

    // MARK: - CLI (detached, drains stdout+stderr concurrently)

    nonisolated private static func runCLI(
        path: String, arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runCLIBlocking(path: path, arguments: arguments))
            }
        }
    }

    nonisolated private static func runCLIBlocking(
        path: String, arguments: [String]
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        // Drain stdout and stderr CONCURRENTLY before waitUntilExit: if stderr fills its
        // ~64KB pipe buffer while we block on stdout (or vice versa), the child stalls and
        // we deadlock. Reading both in parallel keeps both buffers flowing.
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
