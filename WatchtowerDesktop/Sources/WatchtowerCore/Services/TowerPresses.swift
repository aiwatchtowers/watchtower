import Foundation
import Observation
import WatchtowerInterface

/// Where the Desktop's writes go (mobile Inbox spec §5.2, §8): the tower
/// commands, which run in Go. `TowerClient` is the app's; tests pass a fake.
package protocol TowerSending: AnyObject, Sendable {
    func act<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand,
        key: String,
        params: (String) -> Params
    ) async -> TowerActOutcome<Resp>
}

extension TowerClient: TowerSending {}

/// A tower write that did not land: Go's sentence, or the client's when no
/// answer came (`didntConfirmMac` for an unknown outcome), shown as is.
package struct TowerWriteError: LocalizedError, Equatable, Sendable {
    package let sentence: String

    package init(_ sentence: String) {
        self.sentence = sentence
    }

    package var errorDescription: String? { sentence }

    /// Go refused it `not_found`: what it named is gone ("Couldn't …: it's
    /// no longer on the Mac.", `reasonNotFound`), which a caller may take
    /// as done.
    package var isGone: Bool { sentence.hasSuffix(Self.goneReason) }

    /// The end of Go's `not_found` sentence.
    package static let goneReason = "it's no longer on the Mac."
}

extension TowerSending {
    /// One write outside a screen's rows (a seam's call): its response, or
    /// why it did not land. `key` names the press (nil: each call is its
    /// own): a press re-sent under its key after a failure with no answer
    /// keeps its request_id.
    package func perform<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand,
        key: String? = nil,
        _ params: (_ requestID: String) -> Params
    ) async throws -> Resp {
        let outcome: TowerActOutcome<Resp> = await act(
            command, key: key ?? "\(command.rawValue)|\(UUID().uuidString)", params: params)
        switch outcome {
        case .ok(let response): return response
        case .refused(let sentence): throw TowerWriteError(sentence)
        case .unknown: throw TowerWriteError(TowerText.didntConfirmMac)
        case .failed(let failure): throw TowerWriteError(failure.sentence)
        }
    }
}

/// A screen's presses through the tower (#1170 Task 12, mockup §8): every
/// write is one tower command, and the row it was pressed on carries its
/// state (`TowerRowState`) — busy while it waits, the tower's sentence with
/// **Retry** when it did not land, "Didn't confirm — checking again…" when
/// its outcome is unknown. The screen reads its rows on GRDB and re-reads
/// them (`reread`) after a press the tower answered: Go's write is another
/// process's, which no `ValueObservation` sees.
///
/// Failure modes: the daemon down (no answer within the client's 15 s) is a
/// sentence with Retry, and Retry re-sends the same request_id, so a first
/// send that did land is answered from the ledger instead of acting twice; a
/// refusal is Go's sentence with Retry (a new press); an unknown outcome is
/// never re-sent, only re-read. A second press on a busy row does nothing.
@MainActor
@Observable
package final class TowerPresses {
    /// Each row's press state; a row without one shows nothing.
    package private(set) var states: [String: TowerActionState] = [:]
    /// Each row's last press's busy label (`TowerPressText`).
    package private(set) var labels: [String: String] = [:]

    /// The screen's re-read, run after every answered press.
    @ObservationIgnored package var reread: @MainActor () async -> Void = {}

    @ObservationIgnored private let tower: (any TowerSending)?
    @ObservationIgnored private var retries: [String: @MainActor () async -> Void] = [:]

    /// `tower` nil: the screen was made without the app's tower (a test that
    /// never presses); a press fails with the daemon's sentence.
    package init(tower: (any TowerSending)?) {
        self.tower = tower
    }

    package func state(_ row: String) -> TowerActionState? {
        states[row]
    }

    package func isBusy(_ row: String) -> Bool {
        states[row] == .busy
    }

    /// The busy label of `row`'s last press.
    package func label(_ row: String) -> String {
        labels[row] ?? TowerPressText.updating
    }

    /// Sends `command` for `row`, busy as `label`; its response when it
    /// landed, else nil (the row keeps the failure). `variant` tells two presses of one row apart
    /// (another status, another date): the client keeps one request_id per
    /// row, command and variant until a final answer.
    @discardableResult
    package func send<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand,
        row: String,
        label: String,
        variant: String = "",
        params: @escaping (String) -> Params
    ) async -> Resp? {
        guard states[row] != .busy else { return nil }
        retries[row] = { [weak self] in
            let _: Resp? = await self?.send(command, row: row, label: label, variant: variant, params: params)
        }
        labels[row] = label
        states[row] = .busy
        guard let tower else {
            states[row] = .refused(TowerText.daemonDown)
            return nil
        }
        let outcome: TowerActOutcome<Resp> = await tower.act(
            command, key: "\(command.rawValue)|\(row)|\(variant)", params: params)
        switch outcome {
        case .ok(let response):
            states[row] = nil
            retries[row] = nil
            await reread()
            return response
        case .refused(let sentence):
            states[row] = .refused(sentence)
            await reread()
        case .failed(let failure):
            states[row] = .refused(failure.sentence)
        case .unknown:
            // Never re-sent: the screen reads what landed.
            states[row] = .unknown
            retries[row] = nil
            await reread()
        }
        return nil
    }

    /// Retry on `row`: the press that failed, again.
    package func retry(_ row: String) async {
        guard let press = retries[row] else { return }
        await press()
    }

    /// The row's failure is no longer shown (its record left the screen).
    package func forget(_ row: String) {
        guard states[row] != .busy else { return }
        states[row] = nil
        retries[row] = nil
    }
}

/// The busy labels of the screens' presses (mockup §8: "Approving…").
package enum TowerPressText {
    package static let approving = "Approving…"
    package static let rejecting = "Rejecting…"
    package static let saving = "Saving…"
    package static let deleting = "Deleting…"
    package static let updating = "Updating…"
    package static let marking = "Marking…"
    package static let snoozing = "Snoozing…"
    package static let moving = "Moving…"
    package static let converting = "Converting…"
}
