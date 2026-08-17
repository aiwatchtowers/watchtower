import GRDB
import Observation
import os
import SwiftUI
import WatchtowerKit

// MARK: - Feed entry

/// One row of the phone's digest feed — a Slack digest or a Gmail/Jira
/// stream digest, unified for the merged newest-first list. `id` doubles as
/// the slice recordName, which is exactly what the mark-as-read outbox call
/// needs.
enum DigestEntry: Identifiable, Equatable {
    case slack(Digest)
    case stream(StreamDigest)

    var id: String {
        switch self {
        case .slack(let digest): return SliceKind.digest.recordName(id: String(digest.id))
        case .stream(let digest): return SliceKind.streamDigest.recordName(id: String(digest.id))
        }
    }

    /// ISO8601 `created_at` — both sources store the same second-precision
    /// UTC shape, so lexicographic order IS chronological order.
    var createdAt: String {
        switch self {
        case .slack(let digest): return digest.createdAt
        case .stream(let digest): return digest.createdAt
        }
    }

    var isRead: Bool {
        switch self {
        case .slack(let digest): return digest.isRead
        case .stream(let digest): return digest.isRead
        }
    }
}

// MARK: - View model

/// The Digests surface: Slack digests (`digest` + `digest_topic` slices) and
/// Gmail/Jira stream digests (`stream_digest` slice) merged newest first.
/// READ-ONLY by construction — the phone renders what the Mac generated; the
/// only write is the mark-as-read relay action, and the read state itself
/// only flips when the updated row hydrates back (overlay-free, Plan 4's
/// "never mutate replica rows" rule).
@MainActor
@Observable
final class DigestsViewModel {
    private(set) var entries: [DigestEntry] = []
    private var topicsByDigest: [Int: [DigestTopic]] = [:]

    private var digestsCancellable: AnyDatabaseCancellable?
    private var topicsCancellable: AnyDatabaseCancellable?
    private var streamsCancellable: AnyDatabaseCancellable?

    private var slackDigests: [Digest] = []
    private var streamDigests: [StreamDigest] = []
    private var outbox: ActionOutbox?
    /// Entry ids already sent this session — a detail re-appear must not
    /// enqueue a second action while the first echo is still in flight.
    private var readsEnqueued: Set<String> = []

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "DigestsViewModel")

    func start(store: ReplicaStore, outbox: ActionOutbox) {
        guard digestsCancellable == nil else { return }
        self.outbox = outbox
        digestsCancellable = ReplicaObserver.observe(Digest.self, kind: .digest, in: store) { [weak self] items in
            self?.slackDigests = items
            self?.rebuild()
        }
        topicsCancellable = ReplicaObserver.observe(DigestTopic.self, kind: .digestTopic, in: store) { [weak self] items in
            self?.topicsByDigest = Dictionary(grouping: items, by: \.digestID)
                .mapValues { $0.sorted { $0.idx < $1.idx } }
        }
        streamsCancellable = ReplicaObserver.observe(StreamDigest.self, kind: .streamDigest, in: store) { [weak self] items in
            self?.streamDigests = items
            self?.rebuild()
        }
    }

    private func rebuild() {
        entries = (slackDigests.map(DigestEntry.slack) + streamDigests.map(DigestEntry.stream))
            .sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    }

    /// Topics of one Slack digest, publisher order (`idx`). Empty for a
    /// legacy digest whose topics never got per-topic rows.
    func topics(digestID: Int) -> [DigestTopic] {
        topicsByDigest[digestID] ?? []
    }

    /// Relays mark-as-read for an unread entry — fire-and-forget: a failed
    /// enqueue is logged and the digest simply stays unread (self-surfaces;
    /// reading is never blocked on the relay).
    func markRead(_ entry: DigestEntry) {
        guard !entry.isRead, let outbox, readsEnqueued.insert(entry.id).inserted else { return }
        let kind: ActionKind
        switch entry {
        case .slack: kind = .digestRead
        case .stream: kind = .streamDigestRead
        }
        Task {
            do {
                _ = try await outbox.enqueue(kind: kind, entityRecordName: entry.id)
            } catch {
                // Allow a later retry (next detail open) for this entry.
                readsEnqueued.remove(entry.id)
                Self.logger.error("mark-read enqueue failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Formatting

/// Display labels shared by the digest list and detail screens.
enum DigestFormatting {
    /// "6 Jul – 7 Jul" period label from the Slack digest's Unix bounds.
    static func period(from: Double, to: Double) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM"
        let start = fmt.string(from: Date(timeIntervalSince1970: from))
        let end = fmt.string(from: Date(timeIntervalSince1970: to))
        return start == end ? start : "\(start) – \(end)"
    }

    /// "5 Jul – 6 Jul" from the stream digest's ISO bounds; falls back to the
    /// raw strings when they cannot be parsed (never swallow a stored value).
    static func period(fromISO: String, toISO: String) -> String {
        guard let from = parseISO(fromISO), let to = parseISO(toISO) else {
            return [fromISO, toISO].filter { !$0.isEmpty }.joined(separator: " – ")
        }
        return period(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970)
    }

    static func title(for digest: Digest) -> String {
        switch digest.type {
        case "daily": return "Daily digest"
        case "weekly": return "Weekly digest"
        default:
            if let name = digest.channelName, !name.isEmpty { return "#\(name)" }
            return digest.channelID.isEmpty ? "Channel digest" : digest.channelID
        }
    }

    static func sourceLabel(for digest: StreamDigest) -> String {
        digest.source == "jira" ? "Jira" : "Gmail"
    }

    private static func parseISO(_ raw: String) -> Date? {
        Self.iso.date(from: raw)
    }

    private static let iso = ISO8601DateFormatter()
}

// MARK: - List

/// Pushed inside Today's navigation stack (the Recordings precedent) —
/// deliberately no NavigationStack of its own, and NOT a seventh tab.
struct DigestsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = DigestsViewModel()

    var body: some View {
        List(model.entries) { entry in
            NavigationLink {
                DigestEntryDetailView(entry: entry, model: model)
            } label: {
                DigestEntryRow(entry: entry)
            }
        }
        .overlay {
            if model.entries.isEmpty {
                ContentUnavailableView(
                    "No digests",
                    systemImage: "newspaper",
                    description: Text("Digests your Mac generates show up here.")
                )
            }
        }
        .navigationTitle("Digests")
        .onAppear { model.start(store: env.store, outbox: env.outbox) }
    }
}

struct DigestEntryRow: View {
    let entry: DigestEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(entry.isRead ? Color.clear : Color.blue)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                switch entry {
                case .slack(let digest):
                    HStack(spacing: 6) {
                        Text(DigestFormatting.title(for: digest))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Badge(text: "Slack", color: .green)
                    }
                    Text(DigestFormatting.period(from: digest.periodFrom, to: digest.periodTo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !digest.summary.isEmpty {
                        Text(digest.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                case .stream(let digest):
                    HStack(spacing: 6) {
                        Text(digest.scope.isEmpty
                             ? DigestFormatting.sourceLabel(for: digest)
                             : digest.scope)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Badge(
                            text: DigestFormatting.sourceLabel(for: digest),
                            color: digest.source == "jira" ? .indigo : .red
                        )
                    }
                    Text(DigestFormatting.period(fromISO: digest.periodFrom, toISO: digest.periodTo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

/// Read-only digest detail. Marks the entry read on appear (the desktop
/// detail panes' mark-on-open convention), relayed to the Mac; the unread
/// dot clears when the updated row hydrates back.
struct DigestEntryDetailView: View {
    let entry: DigestEntry
    let model: DigestsViewModel

    var body: some View {
        List {
            switch entry {
            case .slack(let digest):
                slackSections(digest)
            case .stream(let digest):
                streamSections(digest)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { model.markRead(entry) }
    }

    private var title: String {
        switch entry {
        case .slack(let digest): return DigestFormatting.title(for: digest)
        case .stream(let digest): return DigestFormatting.sourceLabel(for: digest)
        }
    }

    // MARK: Slack digest

    @ViewBuilder
    private func slackSections(_ digest: Digest) -> some View {
        Section {
            Text(DigestFormatting.period(from: digest.periodFrom, to: digest.periodTo))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !digest.summary.isEmpty {
                Text(digest.summary).font(.subheadline)
            }
        }
        let topics = model.topics(digestID: digest.id)
        if topics.isEmpty {
            // Legacy digest without per-topic rows: digest-level decisions
            // are all there is to show.
            let decisions = digest.parsedDecisions
            if !decisions.isEmpty {
                Section("Decisions") {
                    ForEach(decisions) { decision in
                        DecisionRow(decision: decision)
                    }
                }
            }
        } else {
            ForEach(topics) { topic in
                Section(topic.title) {
                    if !topic.summary.isEmpty {
                        Text(topic.summary).font(.subheadline)
                    }
                    ForEach(topic.parsedDecisions) { decision in
                        DecisionRow(decision: decision)
                    }
                }
            }
        }
    }

    // MARK: Stream digest

    @ViewBuilder
    private func streamSections(_ digest: StreamDigest) -> some View {
        Section {
            if !digest.scope.isEmpty {
                Text(digest.scope).font(.subheadline.weight(.semibold))
            }
            Text(DigestFormatting.period(fromISO: digest.periodFrom, toISO: digest.periodTo))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        let topics = digest.parsedTopics
        if topics.isEmpty {
            Section {
                Text("No topics in this digest.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
                Section(topic.title) {
                    if let summary = topic.summary, !summary.isEmpty {
                        Text(summary).font(.subheadline)
                    }
                    ForEach(Array((topic.decisions ?? []).enumerated()), id: \.offset) { _, candidate in
                        CandidateRow(label: "Decision", candidate: candidate, color: .purple)
                    }
                    ForEach(Array((topic.ideas ?? []).enumerated()), id: \.offset) { _, candidate in
                        CandidateRow(label: "Idea", candidate: candidate, color: .orange)
                    }
                }
            }
        }
    }
}

/// One Slack-digest decision: text plus the author when the model carried one.
private struct DecisionRow: View {
    let decision: Decision

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(decision.text).font(.subheadline)
            if let by = decision.by, !by.isEmpty {
                Text(by).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One stream-digest candidate (decision or idea) with its kind badge.
private struct CandidateRow: View {
    let label: String
    let candidate: StreamCandidate
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                Badge(text: label, color: color)
                Text(candidate.text).font(.subheadline)
            }
            if let author = candidate.author, !author.isEmpty {
                Text(author).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
