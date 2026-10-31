import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync

/// A `RelayHTTP` in front of another: `answer` may replace an op's answer (or throw, as a
/// lost network would) before the request reaches the backend; `download` may replace a blob
/// GET's status. Every GET it lets through or answers is counted.
final class InterceptingRelayHTTP: RelayHTTP, @unchecked Sendable {
    private struct State {
        var answer: ((Relay_V1_Request) throws -> Relay_V1_Response?)?
        var download: ((URL) -> Int?)?
        var gets: [URL] = []
    }

    private let base: any RelayHTTP
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ base: any RelayHTTP) {
        self.base = base
    }

    /// The op hook: nil lets the request through.
    func answer(_ hook: ((Relay_V1_Request) throws -> Relay_V1_Response?)?) {
        state.withLock { $0.answer = hook }
    }

    /// The blob GET hook: a status answers the GET with it and writes nothing.
    func download(_ hook: ((URL) -> Int?)?) {
        state.withLock { $0.download = hook }
    }

    var gets: [URL] {
        state.withLock { $0.gets }
    }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let hook = state.withLock { $0.answer }
        if let hook, let request = try? Relay_V1_Request(serializedBytes: body), let response = try hook(request) {
            return (200, try response.serializedData())
        }
        return try await base.post(url, body: body, headers: headers)
    }

    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        try await base.put(url, file: file, headers: headers)
    }

    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        let hook = state.withLock { state -> ((URL) -> Int?)? in
            state.gets.append(url)
            return state.download
        }
        if let status = hook?(url) { return status }
        return try await base.get(url, to: file, maxBytes: maxBytes, headers: headers)
    }
}

/// Collects what a transport reports: its `relayEvents` and its `TransportEvent`s.
final class TransportEventLog: @unchecked Sendable {
    private let relay = OSAllocatedUnfairLock<[HostedRelayEvent]>(initialState: [])
    private let transport = OSAllocatedUnfairLock<[TransportEvent]>(initialState: [])
    private let fetched = OSAllocatedUnfairLock(initialState: 0)
    private var reader: Task<Void, Never>?

    func attach(to subject: HostedRelayTransport) async {
        let stream = subject.relayEvents
        reader = Task { [relay] in
            for await event in stream { relay.withLock { $0.append(event) } }
        }
        await subject.setEventHandler { [transport] event in transport.withLock { $0.append(event) } }
        await subject.setEngineFetchedHandler { [fetched] in fetched.withLock { $0 += 1 } }
    }

    var relayEvents: [HostedRelayEvent] {
        relay.withLock { $0 }
    }

    var transportEvents: [TransportEvent] {
        transport.withLock { $0 }
    }

    /// How many times the engine-fetched handler fired.
    var fetches: Int {
        fetched.withLock { $0 }
    }

    func cancel() {
        reader?.cancel()
    }
}
