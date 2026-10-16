import Foundation

/// Holds the chat feed of one session and merges each poll of
/// `watchtower workbench session-feed` into it: upsert by entry id keeping the
/// first position, so a growing agent message or a subagent whose status
/// changed updates in place.
@MainActor
package final class SessionFeedStore: ObservableObject {
    @Published package private(set) var entries: [SessionFeedEntry] = []
    @Published package private(set) var error: String?

    private let sessionID: Int64
    private let runner: CLIRunnerProtocol
    private var cursor = ""
    private var index: [String: Int] = [:]

    package init(sessionID: Int64, runner: CLIRunnerProtocol) {
        self.sessionID = sessionID
        self.runner = runner
    }

    /// Reads what is new since the last cursor (a full read while none exists).
    /// A failure keeps the entries and sets `error`.
    package func refresh() async {
        var args = ["workbench", "session-feed", "--session", String(sessionID), "--json"]
        if !cursor.isEmpty { args += ["--after", cursor] }
        do {
            let payload = try Self.decode(try await runner.run(args: args))
            merge(payload.entries)
            merge(payload.subagents)
            cursor = payload.cursor
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The feed of one subagent run; not merged into the main feed.
    package func subagentFeed(_ toolUseID: String) async throws -> [SessionFeedEntry] {
        let data = try await runner.run(args: [
            "workbench", "session-feed", "--session", String(sessionID), "--subagent", toolUseID, "--json"
        ])
        return try Self.decode(data).entries.filter { SessionFeedEntry.knownKinds.contains($0.kind) }
    }

    private static func decode(_ data: Data) throws -> SessionFeedPayload {
        try JSONDecoder().decode(SessionFeedPayload.self, from: data)
    }

    private func merge(_ incoming: [SessionFeedEntry]) {
        for entry in incoming where SessionFeedEntry.knownKinds.contains(entry.kind) {
            if let i = index[entry.id] {
                entries[i] = entry
            } else {
                index[entry.id] = entries.count
                entries.append(entry)
            }
        }
    }
}
