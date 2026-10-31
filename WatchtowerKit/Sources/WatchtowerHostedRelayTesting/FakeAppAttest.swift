import Foundation
import os
import WatchtowerHostedRelay

/// A scripted `AppAttesting` for tests. Its attestation and assertion bytes
/// are JSON the fake relay verifies:
/// - attestation object: `{"fake_app_attest":1,"key_id","client_data_hash","app_id":"acme.test"}`;
/// - assertion: `{"key_id","client_data_hash","counter"}`, the counter rising per key from 1.
/// `client_data_hash` is base64; `key_id` is the key id string `generateKey` returned
/// (base64 of 32 bytes, like Apple's).
public final class FakeAppAttest: AppAttesting, @unchecked Sendable {
    public enum Call: String, Sendable {
        case generateKey, attestKey, generateAssertion
    }

    public static let appID = "acme.test"

    private struct State {
        var isSupported = true
        var failures: [Call: [AppAttestFailure]] = [:]
        var calls: [String] = []
        var keysMade = 0
        var counters: [String: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isSupported: Bool {
        get { state.withLock { $0.isSupported } }
        set { state.withLock { $0.isSupported = newValue } }
    }

    /// Every App Attest call so far, by name, in order.
    public var calls: [String] {
        state.withLock { $0.calls }
    }

    /// Queues failures for the next calls of `call`, one per call, in order.
    public func script(_ call: Call, failures: [AppAttestFailure]) {
        state.withLock { $0.failures[call, default: []].append(contentsOf: failures) }
    }

    /// A new key id without logging a call: a key "made earlier", for a
    /// pre-filled key store.
    public func makeKeyID() -> String {
        state.withLock { Self.nextKeyID(&$0) }
    }

    public func generateKey() async throws -> String {
        try state.withLock { state in
            try Self.begin(.generateKey, &state)
            return Self.nextKeyID(&state)
        }
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try state.withLock { try Self.begin(.attestKey, &$0) }
        return try Self.json([
            "fake_app_attest": 1,
            "key_id": keyID,
            "client_data_hash": clientDataHash.base64EncodedString(),
            "app_id": Self.appID
        ])
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        let counter = try state.withLock { state in
            try Self.begin(.generateAssertion, &state)
            state.counters[keyID, default: 0] += 1
            return state.counters[keyID, default: 0]
        }
        return try Self.json([
            "key_id": keyID,
            "client_data_hash": clientDataHash.base64EncodedString(),
            "counter": counter
        ])
    }

    private static func begin(_ call: Call, _ state: inout State) throws {
        state.calls.append(call.rawValue)
        if var queue = state.failures[call], !queue.isEmpty {
            let failure = queue.removeFirst()
            state.failures[call] = queue
            throw failure
        }
    }

    private static func nextKeyID(_ state: inout State) -> String {
        state.keysMade += 1
        return Data(repeating: UInt8(truncatingIfNeeded: state.keysMade), count: 32).base64EncodedString()
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
