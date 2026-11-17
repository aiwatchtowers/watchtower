import Foundation
import WatchtowerInterface

/// The Mac's Inbox writes through the tower (mobile Inbox spec §5.1, Task
/// 11c): every press is one `inbox.act` call over `TowerClient`, keyed so a
/// press that failed for want of an answer is re-sent with the same
/// request_id by its row's Retry.
package struct InboxTowerWrites: Sendable {
    /// How one write ended.
    package enum Outcome: Equatable, Sendable {
        /// It landed; `already` when it was a guarded no-op (nothing changed).
        case done(already: Bool)
        /// It did not land, or its tool failed: Go's sentence (or the
        /// client's for no answer), shown on the row with Retry.
        case failed(String)
    }

    private let client: TowerClient

    package init(client: TowerClient) {
        self.client = client
    }

    /// Sends `verb` on card `target`. An approval that applied with an error
    /// (its tool failed) is a failure with that error.
    package func act(target: String, verb: ActVerb, params: ActParams) async -> Outcome {
        let outcome: TowerActOutcome<ActResult> = await client.act(.inboxAct, key: Self.key(target, verb, params)) {
            ActRequest(requestID: $0, target: target, verb: verb, params: params)
        }
        switch outcome {
        case .ok(let result):
            if let error = result.error, !error.isEmpty { return .failed(error) }
            return .done(already: result.already == true)
        case .refused(let refusal): return .failed(refusal.sentence)
        case .unknown: return .failed(TowerText.didntConfirmMac)
        case .failed(let failure): return .failed(failure.sentence)
        }
    }

    /// One press's key: its target, verb and params, so a press with other
    /// params (another hash, another snooze) is a new request.
    static func key(_ target: String, _ verb: ActVerb, _ params: ActParams) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(params)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        return "\(target)|\(verb.rawValue)|\(body)"
    }
}
