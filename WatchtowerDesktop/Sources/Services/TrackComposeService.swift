import Foundation

/// AI-drafted custom-track title + watch instruction returned by
/// `watchtower tracks create`. The CLI both composes and persists the track
/// (one-shot "describe → it makes the track"); see `cmd/tracks.go`.
struct TrackDraft: Decodable {
    let title: String
    let instruction: String
}

/// Bridges the Desktop app to `watchtower tracks create`, which turns a
/// free-text "what to watch" request into a scoped custom track (title +
/// watch instruction). Ported from the removed `ObserverComposeService`.
struct TrackComposeService {
    let runner: CLIRunnerProtocol

    /// Composes a custom-track draft. When `targetID` > 0 the track is linked
    /// to that target for context.
    func compose(text: String, targetID: Int? = nil) async throws -> TrackDraft {
        var args = ["tracks", "create", "--text", text]
        if let targetID, targetID > 0 {
            args.append(contentsOf: ["--target", "\(targetID)"])
        }
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TrackDraft.self, from: data)
    }
}
