import CryptoKit
import Foundation
import os
import SwiftProtobuf
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// A `RelayHTTP` for the client's tests: it decodes every `POST /v1/op`,
/// records it, and answers from a per-op script. An op with nothing scripted
/// gets a default answer (ops by case name): `challenge` a nonce, `login` a session `token-N`,
/// `register` the registered device, anything else `Ok`.
final class ScriptedRelayHTTP: RelayHTTP, @unchecked Sendable {
    struct Recorded: Sendable {
        let url: URL
        let headers: [String: String]
        let request: Relay_V1_Request

        var op: String {
            ScriptedRelayHTTP.name(of: request.op)
        }
    }

    enum Answer: Sendable {
        case response(Relay_V1_Response, status: Int)
        case raw(status: Int, body: Data)
        case failure(any Error)

        static func error(_ code: Relay_V1_ErrorCode, status: Int = 200, retryAfter: UInt32? = nil) -> Self {
            var error = Relay_V1_Error()
            error.code = code
            error.message = "scripted \(code)"
            if let retryAfter { error.retryAfterS = retryAfter }
            var response = Relay_V1_Response()
            response.error = error
            return .response(response, status: status)
        }

        static func ok(_ response: Relay_V1_Response) -> Self {
            .response(response, status: 200)
        }
    }

    private struct State {
        var script: [String: [Answer]] = [:]
        var requests: [Recorded] = []
        var tokens = 0
        var gatedOps: Set<String> = []
        var gated: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The nonce every default `challenge` answer carries.
    static let nonce = Data("scripted-nonce".utf8)

    /// Every request so far, in order.
    var requests: [Recorded] {
        state.withLock { $0.requests }
    }

    /// The op names of every request so far, in order.
    var ops: [String] {
        requests.map(\.op)
    }

    /// Requests of one op, in order.
    func requests(_ op: String) -> [Recorded] {
        requests.filter { $0.op == op }
    }

    /// Queues answers for the next requests of `op`, one per request.
    func script(_ op: String, _ answers: [Answer]) {
        state.withLock { $0.script[op, default: []].append(contentsOf: answers) }
    }

    /// Holds every request of `op` until `release()`.
    func gate(_ op: String) {
        state.withLock { _ = $0.gatedOps.insert(op) }
    }

    /// The requests waiting at a gate.
    var gatedCount: Int {
        state.withLock { $0.gated.count }
    }

    func waitForGated(_ count: Int) async {
        while gatedCount < count {
            await Task.yield()
        }
    }

    /// Lifts every gate and lets the held requests through.
    func release() {
        let held = state.withLock { state in
            state.gatedOps = []
            defer { state.gated = [] }
            return state.gated
        }
        for continuation in held { continuation.resume() }
    }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let request = try Relay_V1_Request(serializedBytes: body)
        let op = Self.name(of: request.op)
        let mustWait = state.withLock { state in
            state.requests.append(Recorded(url: url, headers: headers, request: request))
            return state.gatedOps.contains(op)
        }
        if mustWait {
            await withCheckedContinuation { continuation in
                let releasedMeanwhile = state.withLock { state in
                    guard state.gatedOps.contains(op) else { return true }
                    state.gated.append(continuation)
                    return false
                }
                if releasedMeanwhile { continuation.resume() }
            }
        }
        let answer = state.withLock { state -> Answer in
            if var queue = state.script[op], !queue.isEmpty {
                let next = queue.removeFirst()
                state.script[op] = queue
                return next
            }
            return Self.defaultAnswer(op, request, &state)
        }
        switch answer {
        case let .response(response, status):
            return (status, try response.serializedData())
        case let .raw(status, body):
            return (status, body)
        case .failure(let error):
            throw error
        }
    }

    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        200
    }

    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        200
    }

    private static func defaultAnswer(_ op: String, _ request: Relay_V1_Request, _ state: inout State) -> Answer {
        var response = Relay_V1_Response()
        switch request.op {
        case .challenge:
            var challenge = Relay_V1_Challenge()
            challenge.nonce = nonce
            response.challenge = challenge
        case .login:
            state.tokens += 1
            var session = Relay_V1_Session()
            session.token = "token-\(state.tokens)"
            response.session = session
        case .register(let register):
            var registered = Relay_V1_DeviceRegistered()
            registered.deviceID = RelayAuthMessages.deviceID(publicKey: register.authPub)
            registered.accountID = "acme-account"
            response.registered = registered
        default:
            response.ok = Relay_V1_Ok()
        }
        return .ok(response)
    }

    /// The op's case name (`challenge`, `login`, `removeSlot`, ...).
    static func name(of op: Relay_V1_Request.OneOf_Op?) -> String {
        guard let op else { return "none" }
        return Mirror(reflecting: op).children.first?.label ?? "unknown"
    }
}

/// No WebSocket: the HTTPS tests never dial.
struct NoRelaySockets: RelaySocketDialer {}

/// A `ManualRelayClock` that also records every sleep it is asked for.
final class RecordingRelayClock: RelayClock, @unchecked Sendable {
    let manual = ManualRelayClock()
    private let recorded = OSAllocatedUnfairLock(initialState: [Duration]())

    var sleeps: [Duration] {
        recorded.withLock { $0 }
    }

    func now() -> Date {
        manual.now()
    }

    func sleep(for duration: Duration) async throws {
        recorded.withLock { $0.append(duration) }
        try await manual.sleep(for: duration)
    }
}

/// One phone client on a scripted relay, with every seam reachable.
struct RelayClientHarness {
    static let originString = "https://relay.example.com"

    let http = ScriptedRelayHTTP()
    let fake = FakeAppAttest()
    let keys: InMemoryAppAttestKeyStore
    let clock = RecordingRelayClock()
    let origin: RelayOrigin
    let signer: Ed25519RelaySigner
    let client: HostedRelayClient

    /// `storedKey`: the device registered earlier, so a login sends an assertion.
    init(storedKey: Bool = true) throws {
        keys = InMemoryAppAttestKeyStore(keyID: storedKey ? fake.makeKeyID() : nil)
        origin = try RelayOrigin(Self.originString)
        signer = Ed25519RelaySigner(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32)))
        client = HostedRelayClient(
            origin: origin,
            signer: signer,
            kind: .phone,
            attestor: RelayAttestor(attest: fake, keys: keys, clock: clock),
            http: http,
            sockets: NoRelaySockets(),
            clock: clock
        )
    }

    /// An op that needs a session and answers `Ok`.
    static var removeSlot: Relay_V1_Request.OneOf_Op {
        .removeSlot(Relay_V1_RemoveMacSlot())
    }
}

/// Asserts `body` throws exactly `expected`.
func assertRelayError(
    _ expected: HostedRelayError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected), nothing thrown", file: file, line: line)
    } catch let error as HostedRelayError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
