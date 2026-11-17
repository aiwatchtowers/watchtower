import Foundation
import WatchtowerInterface

/// Where the Desktop's chat writes go (mobile Inbox spec §8, stage 3): the
/// `chat.*` tower commands, which run in Go. `TowerClient` is the app's;
/// tests pass a fake. A turn's own rows are not here — `ai session
/// --persist` and `ai query --persist` write them.
package typealias ChatTowerSending = TowerSending

/// A chat write the tower did not apply: Go's sentence (or the client's,
/// when no answer came), shown as is.
package struct ChatWriteError: LocalizedError, Equatable, Sendable {
    package let sentence: String
    /// Refused `not_found`-like: what it names is gone (a delete then counts as done).
    package let isGone: Bool

    package init(sentence: String, isGone: Bool = false) {
        self.sentence = sentence
        self.isGone = isGone
    }

    package var errorDescription: String? { sentence }
}

/// The typed chat writes over a `ChatTowerSending`. Each call is one press:
/// its own request id, kept by the client until a final answer.
package struct ChatWrites: Sendable {
    package let tower: any ChatTowerSending

    package init(tower: any ChatTowerSending) {
        self.tower = tower
    }

    /// Runs `command` (a local database write by the daemon); the response, or
    /// why it was not applied.
    package func perform<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand,
        _ params: (_ requestID: String) -> Params
    ) async throws -> Resp {
        let outcome: TowerActOutcome<Resp> = await tower.act(command, key: "\(command.rawValue):\(UUID().uuidString)",
                                                             params: params)
        switch outcome {
        case .ok(let response):
            return response
        case .refused(let refusal):
            throw ChatWriteError(sentence: refusal.sentence, isGone: Self.goneSentences.contains(refusal.sentence))
        case .unknown:
            throw ChatWriteError(sentence: TowerText.didntConfirmMac)
        case .failed(let failure):
            throw ChatWriteError(sentence: failure.sentence)
        }
    }

    /// Before the app wired its tower (a screen made before the database
    /// opened): every write fails with a sentence the screen shows.
    package static let notReady = Self(tower: NotReadyChatTower())

    /// Go's `not_found` sentences for chat rows (`internal/chatstore/commands.go`).
    private static let goneSentences: Set<String> = [
        "This chat no longer exists.", "This message no longer exists.", "This project no longer exists."
    ]
}

/// The tower of `ChatWrites.notReady`.
private final class NotReadyChatTower: ChatTowerSending {
    func act<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand, key: String, params: (String) -> Params
    ) async -> TowerActOutcome<Resp> {
        .refused(Refusal(code: .unsupported, sentence: "Watchtower's chat isn't ready yet."))
    }
}
