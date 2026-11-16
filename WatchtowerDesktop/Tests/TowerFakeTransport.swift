import Foundation
import os
import WatchtowerInterface

/// A tower that answers at once: `tower.hello` with this build's interface
/// version and `syncPaused`, `sync.pause`/`sync.resume` with the new state.
/// Records every request it gets.
final class TowerFakeTransport: TowerTransport {
    private struct State {
        var paused = false
        var requests: [Request] = []
        var refusal: Refusal?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(paused: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(paused: paused))
    }

    var requests: [Request] { state.withLock { $0.requests } }

    /// The next pause or resume is refused with `refusal`.
    func refuse(_ refusal: Refusal) {
        state.withLock { $0.refusal = refusal }
    }

    func call(_ request: Request) async throws -> Response {
        let (paused, refusal) = state.withLock { state -> (Bool, Refusal?) in
            state.requests.append(request)
            var refusal: Refusal?
            switch request.command {
            case TowerCommand.syncPause.rawValue, TowerCommand.syncResume.rawValue:
                refusal = state.refusal
                state.refusal = nil
                if refusal == nil { state.paused = request.command == TowerCommand.syncPause.rawValue }
            default:
                break
            }
            return (state.paused, refusal)
        }
        if let refusal { return Response(id: request.id, status: .refused, refusal: refusal) }
        switch request.command {
        case TowerCommand.towerHello.rawValue:
            return try Self.ok(request, HelloResponse(
                interfaceVersion: InterfaceVersion.current, build: "test", syncPaused: paused, noSync: false
            ))
        default:
            return try Self.ok(request, PauseResponse(paused: paused))
        }
    }

    func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: TowerTransportError.down) }
    }

    private static func ok(_ request: Request, _ value: some Encodable) throws -> Response {
        Response(id: request.id, status: .ok, result: try RawJSON(data: JSONEncoder().encode(value)))
    }
}
