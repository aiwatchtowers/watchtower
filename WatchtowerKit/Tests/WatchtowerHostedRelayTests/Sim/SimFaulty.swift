import Foundation
import os
import WatchtowerSync

/// Port of the Go `sim_interop_test.go` `faulty`: one device's view of one transport that can
/// fail some of its writes. `SimWorld` wraps every leg of every device in one at construction
/// (`world.fault(owner, kind)`), so the knobs act per device and per transport.
final class SimFaulty: SimTransport {
    private struct Knobs {
        var failControls = false
        var refuseActions = 0
        var holdControls = false
    }

    let inner: any SimTransport
    private let knobs = OSAllocatedUnfairLock(initialState: Knobs())

    init(_ inner: any SimTransport) {
        self.inner = inner
    }

    var kind: SimKind {
        inner.kind
    }

    /// Every write other than an action record (control records, the transport marker) fails
    /// as unreachable.
    var failControls: Bool {
        get { knobs.withLock { $0.failControls } }
        set { knobs.withLock { $0.failControls = newValue } }
    }

    /// Refuses that many action writes with RATE_LIMITED.
    var refuseActions: Int {
        get { knobs.withLock { $0.refuseActions } }
        set { knobs.withLock { $0.refuseActions = newValue } }
    }

    /// Keeps the server control events from the device: they have not reached it yet.
    var holdControls: Bool {
        get { knobs.withLock { $0.holdControls } }
        set { knobs.withLock { $0.holdControls = newValue } }
    }

    /// Go `faulty.Save`: decided on the first item, as Go's.
    func save(_ zone: String, _ items: [SimSaveItem]) async -> [SaveOutcome] {
        guard let first = items.first else { return await inner.save(zone, items) }
        let isActionName = first.name.hasPrefix("a-")
        let isAction = isActionName && SimEnvelope.kindOf(first.envelope) == SimEnvelope.kindAction
        let refusal: TransportRefusal? = knobs.withLock { knobs in
            if knobs.failControls, !isActionName { return .unreachable }
            if knobs.refuseActions > 0, isAction {
                knobs.refuseActions -= 1
                return .rateLimited(retryAfter: nil)
            }
            return nil
        }
        if let refusal { return items.map { _ in .refused(refusal) } }
        return await inner.save(zone, items)
    }

    func delete(_ zone: String, _ items: [SimDeleteItem]) async -> [DeleteOutcome] {
        await inner.delete(zone, items)
    }

    func changes(_ zone: String, since: UInt64) async throws -> SimChanges {
        try await inner.changes(zone, since: since)
    }

    func available() async -> Bool {
        await inner.available()
    }

    func takeControls() async -> [SimControl] {
        if holdControls { return [] }
        return await inner.takeControls()
    }

    /// What reached the device's connection, held or not.
    func pendingControls() -> [SimControl] {
        inner.pendingControls()
    }
}
