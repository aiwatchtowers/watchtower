import os
import WatchtowerRelayProto

/// What a `HostedRelayConnection` reports.
public enum HostedRelayClientEvent: Equatable, Sendable {
    /// A zone changed. `seq` 0 is record-less: "pull, you may have missed changes"
    /// (after every connect, and in place of events that did not fit the buffer).
    case zoneChanged(zone: String, seq: UInt64)
    /// The relay refused to subscribe the zone; it is dropped from the connection's set.
    case zoneRefused(zone: String, error: HostedRelayError)
    /// A control event (`SESSION_EXPIRED` is handled by the connection and never reported).
    case control(kind: Relay_V1_ControlKind, detail: String)
    /// The socket said `HelloOk`.
    case connected
    /// A connection that had said `HelloOk` ended; the connection reconnects.
    case disconnected
    /// Unsupported version, or an attestation outcome that ends the relay
    /// (`.notSupported`, `.updateRequired`): no more reconnects, the stream ends.
    case stopped(HostedRelayError)
}

/// The connection's event queue (the Go `Conn.events` + backlog + resync).
/// Writers never wait: a zone event that does not fit `capacity` is folded
/// into that zone's record-less `zoneChanged`, delivered once the queue has
/// emptied; every other event is queued without bound and never dropped.
/// One reader, through `next()`.
final class RelayEventBuffer: Sendable {
    private struct State {
        var queue: [HostedRelayClientEvent] = []
        /// Zones owed a record-less `zoneChanged`, in the order they were owed.
        var owed: [String] = []
        var reader: CheckedContinuation<HostedRelayClientEvent?, Never>?
        var finished = false
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// Queues an event that must not be dropped.
    func push(_ event: HostedRelayClientEvent) {
        hand(event) { $0.queue.append(event) }
    }

    /// A zone event from the socket: queued when it fits, else owed as a record-less one.
    func zoneChanged(_ zone: String, seq: UInt64) {
        let event = HostedRelayClientEvent.zoneChanged(zone: zone, seq: seq)
        hand(event) { state in
            // An owed marker already covers this change.
            guard !state.owed.contains(zone) else { return }
            if state.queue.count < capacity {
                state.queue.append(event)
            } else {
                state.owed.append(zone)
            }
        }
    }

    /// Owes `zone` a record-less `zoneChanged` (merged with one already owed).
    func owe(_ zone: String) {
        hand(.zoneChanged(zone: zone, seq: 0)) { state in
            if !state.owed.contains(zone) { state.owed.append(zone) }
        }
    }

    /// Ends the stream once what is queued has been read.
    func finish() {
        let reader: CheckedContinuation<HostedRelayClientEvent?, Never>? = state.withLock { state in
            state.finished = true
            defer { state.reader = nil }
            return state.reader
        }
        reader?.resume(returning: nil)
    }

    /// The next event: the queue first, then owed zones; nil after `finish()`
    /// once both are empty, or when the reading task is cancelled.
    func next() async -> HostedRelayClientEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: HostedRelayClientEvent?? = state.withLock { state in
                    if !state.queue.isEmpty { return .some(state.queue.removeFirst()) }
                    if !state.owed.isEmpty { return .some(.zoneChanged(zone: state.owed.removeFirst(), seq: 0)) }
                    if state.finished || Task.isCancelled { return .some(nil) }
                    state.reader = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let reader: CheckedContinuation<HostedRelayClientEvent?, Never>? = state.withLock { state in
                defer { state.reader = nil }
                return state.reader
            }
            reader?.resume(returning: nil)
        }
    }

    /// Gives `event` straight to a waiting reader (the queue and the owed
    /// zones are empty then), else applies `enqueue`. Nothing after `finish()`.
    private func hand(_ event: HostedRelayClientEvent, else enqueue: (inout State) -> Void) {
        let reader: CheckedContinuation<HostedRelayClientEvent?, Never>? = state.withLock { state in
            guard !state.finished else { return nil }
            if let reader = state.reader {
                state.reader = nil
                return reader
            }
            enqueue(&state)
            return nil
        }
        reader?.resume(returning: event)
    }
}
