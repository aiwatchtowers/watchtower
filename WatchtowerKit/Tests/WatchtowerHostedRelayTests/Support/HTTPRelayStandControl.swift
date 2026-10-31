import Foundation
import os
import SwiftProtobuf
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto

/// `RelayStandControl` over the local stand's `/dev` endpoints (relay@3a99bd7
/// `worker/src/http/dev.ts`): JSON in, JSON out. A 503 (the stand delivering a revocation)
/// is retried after its `Retry-After`, for at most 30 s. 400 → `.invalid`, 404 → `.notFound`,
/// 409 → `.refused` with the code the stand named (`add slot: entitlement_inactive`).
struct HTTPRelayStandControl: RelayStandControl {
    /// How long a 503 is retried.
    static let retryWindow: TimeInterval = 30

    let origin: URL
    let session: URLSession

    init(origin: URL, session: URLSession = URLSessionRelayHTTP.ephemeralSession) {
        self.origin = origin
        self.session = session
    }

    func setEntitlement(accountID: String, state: String, for duration: Duration) async throws {
        _ = try await post("entitlement", ["accountId": accountID, "state": state, "forMs": Self.milliseconds(duration)])
    }

    func accountID(ofPhone phoneID: String) async throws -> String {
        let answer = try await post("account", ["phoneId": phoneID])
        guard let id = answer["accountId"] as? String else { throw HTTPRelayStandError.badAnswer("account") }
        return id
    }

    func pair(mac: String, phones: [String]) async throws {
        _ = try await post("pair", ["macId": mac, "phoneIds": phones])
    }

    func expireMailboxes(_ zones: [String], elapsed: Duration) async throws {
        _ = try await post("expire-mailboxes", ["zones": zones, "elapsedMs": Self.milliseconds(elapsed)])
    }

    // MARK: - Private

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: origin.appendingPathComponent("dev/\(path)"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let deadline = Date().addingTimeInterval(Self.retryWindow)
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HTTPRelayStandError.badAnswer(path) }
            switch http.statusCode {
            case 200:
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            case 503 where Date() < deadline:
                let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(for: .seconds(min(max(wait, 0.1), 5)))
            case 400:
                throw RelayStandError.invalid
            case 404:
                throw RelayStandError.notFound
            case 409:
                throw RelayStandError.refused(Self.code(in: String(bytes: data, encoding: .utf8) ?? ""))
            default:
                throw HTTPRelayStandError.status(http.statusCode, path)
            }
        }
    }

    /// The error code a 409 names in its last word (`add slot: entitlement_inactive`),
    /// matched against the proto's case names; `.unspecified` when none matches.
    static func code(in body: String) -> Relay_V1_ErrorCode {
        let word = body.split(separator: " ").last.map(String.init) ?? ""
        let parts = word.split(separator: "_").map(String.init)
        let camel = (parts.first ?? "") + parts.dropFirst().map(\.capitalized).joined()
        return Relay_V1_ErrorCode.allCases.first { String(describing: $0) == camel } ?? .unspecified
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}

/// A stand answer the protocol of `/dev` does not cover.
enum HTTPRelayStandError: Error, Equatable {
    case status(Int, String)
    case badAnswer(String)
}

/// Every op the clients of one test sent to the stand, over HTTPS or the socket, in order:
/// the stand's twin of `FakeHostedRelay.log` (no tokens: ops only).
final class StandOpLog: @unchecked Sendable {
    private let ops = OSAllocatedUnfairLock<[Relay_V1_Request.OneOf_Op]>(initialState: [])

    var all: [Relay_V1_Request.OneOf_Op] {
        ops.withLock { $0 }
    }

    func record(_ op: Relay_V1_Request.OneOf_Op?) {
        guard let op else { return }
        ops.withLock { $0.append(op) }
    }
}

/// A `RelayHTTP` that records each `POST /v1/op` request's op, then sends it on.
struct RecordingRelayHTTP: RelayHTTP {
    let base: any RelayHTTP
    let log: StandOpLog

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
        log.record((try? Relay_V1_Request(serializedBytes: body))?.op)
        return try await base.post(url, body: body, headers: headers)
    }

    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        try await base.put(url, file: file, headers: headers)
    }

    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        try await base.get(url, to: file, maxBytes: maxBytes, headers: headers)
    }
}

/// A `RelaySocketDialer` whose sockets record the op of every request frame they send.
struct RecordingRelaySocketDialer: RelaySocketDialer {
    let base: any RelaySocketDialer
    let log: StandOpLog

    func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
        RecordingRelaySocket(base: try await base.dial(url, headers: headers), log: log)
    }
}

private struct RecordingRelaySocket: RelaySocket {
    let base: any RelaySocket
    let log: StandOpLog

    func send(_ data: Data) async throws {
        if let frame = try? Relay_V1_Frame(serializedBytes: data), case .request(let request) = frame.kind {
            log.record(request.op)
        }
        try await base.send(data)
    }

    func receive() async throws -> RelaySocketMessage {
        try await base.receive()
    }

    func ping() async throws {
        try await base.ping()
    }

    func close(code: Int) async {
        await base.close(code: code)
    }
}
