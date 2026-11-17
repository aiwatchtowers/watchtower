import Foundation
import WatchtowerCore
import WatchtowerInterface

/// A stand-in for the daemon's screen commands (#1170 Task 12): each call
/// is recorded with its params and request_id and answered as scripted —
/// `ok` with a result (`{}` by default), refused with a sentence, failed
/// (no answer) or unknown. It keeps `TowerClient`'s request_id rule: one id
/// per key until a final answer, so a press that failed for want of an
/// answer is re-sent with the same id. `onOK` runs before an `ok` answer (a
/// test's stand-in for Go's write landing); `apply` (`applying(_:)`) makes
/// Go's write on a test database and answers with its result.
package final class FakeScreenTower: TowerSending, @unchecked Sendable {
    package enum Answer: Sendable {
        case ok(String)
        case refused(String)
        case failed(String)
        case unknown
    }

    package struct Call: @unchecked Sendable {
        package let command: TowerCommand
        package let params: [String: Any]
        package var requestID: String { params["request_id"] as? String ?? "" }
    }

    private let lock = NSLock()
    private var answers: [TowerCommand: [Answer]] = [:]
    private var standing: [TowerCommand: Answer] = [:]
    private var requestIDs: [String: String] = [:]
    private var callsStorage: [Call] = []
    /// Runs before an `ok` answer.
    package var onOK: (@Sendable (TowerCommand, [String: Any]) async -> Void)?
    /// Makes the command's write before an `ok` answer and returns the
    /// answer's JSON (nil: the scripted one); a thrown `Refused` answers
    /// refused with its sentence.
    package var apply: (@Sendable (TowerCommand, Data) async throws -> Data?)?

    /// A refusal `apply` throws: Go's sentence.
    package struct Refused: Error {
        package let sentence: String
        package init(_ sentence: String) { self.sentence = sentence }
    }

    package init() {}

    /// The next call of `command` gets `answer`; later ones the standing answer.
    package func next(_ command: TowerCommand, _ answer: Answer) {
        lock.withLock { answers[command, default: []].append(answer) }
    }

    /// Every call of `command` (after the queued ones) gets `answer`.
    package func always(_ command: TowerCommand, _ answer: Answer) {
        lock.withLock { standing[command] = answer }
    }

    package var calls: [Call] { lock.withLock { callsStorage } }

    package func calls(_ command: TowerCommand) -> [Call] {
        calls.filter { $0.command == command }
    }

    package func act<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand,
        key: String,
        params: (String) -> Params
    ) async -> TowerActOutcome<Resp> {
        let (requestID, answer) = lock.withLock { () -> (String, Answer) in
            let id = requestIDs[key] ?? UUID().uuidString.lowercased()
            requestIDs[key] = id
            var queued = answers[command] ?? []
            let answer = queued.isEmpty ? (standing[command] ?? .ok("{}")) : queued.removeFirst()
            answers[command] = queued
            return (id, answer)
        }
        guard let data = try? JSONEncoder().encode(params(requestID)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(TowerFailure(kind: .refused, sentence: TowerText.couldNotSend))
        }
        lock.withLock { callsStorage.append(Call(command: command, params: object)) }
        switch answer {
        case .ok(let json):
            await onOK?(command, object)
            lock.withLock { requestIDs[key] = nil }
            var body = Data(json.utf8)
            do {
                if let applied = try await apply?(command, data) { body = applied }
            } catch let refused as Refused {
                return .refused(refused.sentence)
            } catch {
                return .refused(error.localizedDescription)
            }
            guard let value = try? JSONDecoder().decode(Resp.self, from: body) else {
                return .failed(TowerFailure(kind: .refused, sentence: TowerText.unreadableAnswer))
            }
            return .ok(value)
        case .refused(let sentence):
            lock.withLock { requestIDs[key] = nil }
            return .refused(sentence)
        case .failed(let sentence):
            return .failed(TowerFailure(kind: .down, sentence: sentence))
        case .unknown:
            lock.withLock { requestIDs[key] = nil }
            return .unknown
        }
    }
}
