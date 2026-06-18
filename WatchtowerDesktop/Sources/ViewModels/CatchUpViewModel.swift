import Foundation
import GRDB

// MARK: - Catch-Up Result (matches Go catchup.Result)

struct CatchUpRef: Codable, Identifiable, Equatable {
    var id: String { "\(area)-\(refID)" }
    let area: String
    let refID: Int
    let label: String

    enum CodingKeys: String, CodingKey {
        case area, label
        case refID = "id"
    }
}

struct CatchUpStory: Codable, Identifiable, Equatable {
    var id: String { title }
    let title: String
    let narrative: String
    let priority: String
    let needsYou: Bool
    let refs: [CatchUpRef]

    enum CodingKeys: String, CodingKey {
        case title, narrative, priority, refs
        case needsYou = "needs_you"
    }

    init(title: String, narrative: String, priority: String, needsYou: Bool, refs: [CatchUpRef]) {
        self.title = title
        self.narrative = narrative
        self.priority = priority
        self.needsYou = needsYou
        self.refs = refs
    }

    // Tolerate null / missing refs (older payloads, or a model omitting the key).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        narrative = try container.decodeIfPresent(String.self, forKey: .narrative) ?? ""
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
        needsYou = try container.decodeIfPresent(Bool.self, forKey: .needsYou) ?? false
        refs = try container.decodeIfPresent([CatchUpRef].self, forKey: .refs) ?? []
    }
}

struct CatchUpSectionItem: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    let snippet: String
}

struct CatchUpSection: Codable, Identifiable, Equatable {
    var id: String { area }
    let area: String
    let total: Int
    let included: Int
    let items: [CatchUpSectionItem]

    enum CodingKeys: String, CodingKey {
        case area, total, included, items
    }

    init(area: String, total: Int, included: Int, items: [CatchUpSectionItem]) {
        self.area = area
        self.total = total
        self.included = included
        self.items = items
    }

    // Tolerate null / missing items.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        area = try container.decodeIfPresent(String.self, forKey: .area) ?? ""
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        included = try container.decodeIfPresent(Int.self, forKey: .included) ?? 0
        items = try container.decodeIfPresent([CatchUpSectionItem].self, forKey: .items) ?? []
    }
}

struct CatchUpAreaCount: Codable, Equatable {
    let included: Int
    let total: Int
}

struct CatchUpCounts: Codable, Equatable {
    let digests: CatchUpAreaCount
    let tracks: CatchUpAreaCount
    let inbox: CatchUpAreaCount
    let briefings: CatchUpAreaCount
    let totalUnread: Int
    let totalIncluded: Int

    enum CodingKeys: String, CodingKey {
        case digests, tracks, inbox, briefings
        case totalUnread = "total_unread"
        case totalIncluded = "total_included"
    }
}

struct CatchUpResult: Codable, Equatable {
    let tldr: String
    let counts: CatchUpCounts
    let truncated: Bool
    let stories: [CatchUpStory]
    let sections: [CatchUpSection]

    enum CodingKeys: String, CodingKey {
        case tldr, counts, truncated, stories, sections
    }

    init(
        tldr: String,
        counts: CatchUpCounts,
        truncated: Bool,
        stories: [CatchUpStory],
        sections: [CatchUpSection]
    ) {
        self.tldr = tldr
        self.counts = counts
        self.truncated = truncated
        self.stories = stories
        self.sections = sections
    }

    // Tolerate null / missing stories and sections (Go sends [], but be defensive).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tldr = try container.decodeIfPresent(String.self, forKey: .tldr) ?? ""
        counts = try container.decode(CatchUpCounts.self, forKey: .counts)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        stories = try container.decodeIfPresent([CatchUpStory].self, forKey: .stories) ?? []
        sections = try container.decodeIfPresent([CatchUpSection].self, forKey: .sections) ?? []
    }

    /// The snapshot item IDs for one area — the authoritative set to clear.
    func ids(for area: String) -> [Int] {
        sections.first { $0.area == area }?.items.map(\.id) ?? []
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class CatchUpViewModel {
    var result: CatchUpResult?
    var isLoading = false
    var error: String?

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Runs `watchtower catchup --json` and parses the rollup.
    func generate() {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }
        isLoading = true
        error = nil

        Task.detached {
            let cliResult = await Self.runCLI(path: cliPath, arguments: ["catchup", "--json"])
            await MainActor.run {
                self.isLoading = false
                if cliResult.exitCode == 0, !cliResult.stdout.isEmpty {
                    self.parse(cliResult.stdout)
                } else {
                    self.error = cliResult.stderr.isEmpty
                        ? "Catch-up failed (exit \(cliResult.exitCode))"
                        : String(cliResult.stderr.prefix(300))
                }
            }
        }
    }

    /// Marks one area's snapshot IDs read, then refreshes the in-memory result
    /// so that section drops out of the UI.
    func markSectionRead(_ area: String) async {
        guard let result else { return }
        let ids = result.ids(for: area)
        guard !ids.isEmpty else { return }
        do {
            try await dbPool.write { db in
                switch area {
                case "digests": try DigestQueries.markRead(db, ids: ids)
                case "tracks": try TrackQueries.markRead(db, ids: ids)
                case "inbox": try InboxQueries.markRead(db, ids: ids)
                case "briefings": try BriefingQueries.markRead(db, ids: ids)
                default: break
                }
            }
            // Only drop the section from the UI once the write actually succeeded.
            clearSectionLocally(area)
        } catch {
            self.error = "Failed to mark \(area) read: \(error.localizedDescription)"
            print("CatchUp markSectionRead(\(area)) failed: \(error)")
        }
    }

    /// Marks every snapshot ID across all areas read.
    func markAllRead() async {
        guard let result else { return }
        let digestIDs = result.ids(for: "digests")
        let trackIDs = result.ids(for: "tracks")
        let inboxIDs = result.ids(for: "inbox")
        let briefingIDs = result.ids(for: "briefings")
        do {
            try await dbPool.write { db in
                try DigestQueries.markRead(db, ids: digestIDs)
                try TrackQueries.markRead(db, ids: trackIDs)
                try InboxQueries.markRead(db, ids: inboxIDs)
                try BriefingQueries.markRead(db, ids: briefingIDs)
            }
            // Only clear the rollup once the write actually succeeded.
            self.result = nil
        } catch {
            self.error = "Failed to mark everything read: \(error.localizedDescription)"
            print("CatchUp markAllRead failed: \(error)")
        }
    }

    private func clearSectionLocally(_ area: String) {
        guard let current = result else { return }
        let remaining = current.sections.filter { $0.area != area }
        result = CatchUpResult(
            tldr: current.tldr, counts: current.counts, truncated: current.truncated,
            stories: current.stories, sections: remaining
        )
    }

    private func parse(_ output: String) {
        guard let data = output.data(using: .utf8) else {
            error = "Invalid CLI output encoding"
            return
        }
        do {
            result = try JSONDecoder().decode(CatchUpResult.self, from: data)
        } catch {
            self.error = "Failed to parse catch-up: \(error.localizedDescription)"
        }
    }

    nonisolated private static func runCLI(
        path: String, arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        // The Process I/O below is synchronous and blocking, so run it off the
        // cooperative pool via a continuation — this also lets us use DispatchGroup.wait()
        // outside an async context (which is a hard error under Swift 6).
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
