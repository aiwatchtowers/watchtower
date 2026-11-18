import CryptoKit
import Foundation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The order of everything the hand-over did, across its seams.
final class AdoptionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ event: String) { lock.withLock { storage.append(event) } }
    func reset() { lock.withLock { storage = [] } }
    var events: [String] { lock.withLock { storage } }
}

/// The app was killed at this point: what ran before it stays done.
struct FakeKill: Error {}

/// A Go hub behind `watchtower hub adopt`: answers each verb from its state,
/// as cmd/hub_adopt.go does (JSON on stdout even on a refusal, exit 1).
final class FakeAdoptHub: HubAdoptRunning, @unchecked Sendable {
    struct State {
        var step = ""
        var hubID = ""
        var identity = "none"
        var swiftState = "absent"
        var pending: [HubAdoptStatus.PendingRecording] = []
    }

    struct Call {
        let args: [String]
        let stdin: Data
    }

    private let log: AdoptionLog
    var state = State()
    var calls: [Call] = []
    /// Verbs whose change was applied (not just called).
    var applied: [String] = []
    var adoptError: String?
    var keysError: String?
    var confirmError: String?
    var setAsideError: String?
    var garbleStatus = false
    /// Verbs answered with their success JSON but a non-zero exit.
    var exitOne: Set<String> = []
    /// Verbs after whose change the app dies (the runner throws).
    var killAfter: Set<String> = []
    /// Verbs the app dies before starting.
    var killBefore: Set<String> = []
    /// Verbs that hang until cancelled (a stuck child); `cancelled` records them.
    var hangOn: Set<String> = []
    var cancelled: [String] = []
    var onAdopt: (@MainActor () -> Void)?

    init(log: AdoptionLog) { self.log = log }

    func run(_ args: [String], stdin: Data) async throws -> HubAdoptOutput {
        let verb = args.first { $0.hasPrefix("--") && $0 != "--json" } ?? ""
        if killBefore.contains(verb) { throw FakeKill() }
        if verb == "--settings-stdin", let onAdopt { await onAdopt() }
        calls.append(Call(args: args, stdin: stdin))
        log.append("cli:\(verb)")
        if hangOn.contains(verb) {
            await parkUntilCancelled() // a stuck child: returns only once its task is cancelled, no clock
            if Task.isCancelled { cancelled.append(verb) }
            return HubAdoptOutput(stdout: Data(), exitCode: -1)
        }
        var (object, code) = answer(verb)
        if exitOne.contains(verb) { code = 1 }
        if killAfter.contains(verb) { throw FakeKill() }
        let data = garbleStatus && verb == "--status" ? Data("not json".utf8)
            : try JSONSerialization.data(withJSONObject: object)
        return HubAdoptOutput(stdout: data, exitCode: code)
    }

    private func answer(_ verb: String) -> ([String: Any], Int32) {
        switch verb {
        case "--status":
            return ([
                "step": state.step, "imported": ["devices": 0, "jobs": 0, "skipped": 0, "audio_left": 0],
                "error": "", "hub_id": state.hubID, "identity": state.identity, "swift_state": state.swiftState,
                "pending_recordings": state.pending.map { ["upload_id": $0.uploadID, "audio_name": $0.audioName] }
            ], 0)
        case "--settings-stdin":
            if let adoptError { return (["step": "verify", "error": adoptError], 1) }
            if state.step == "done" { return (["step": "done", "error": "already_adopted"], 1) }
            (state.step, state.swiftState, state.pending) = ("done", "absent", [])
            applied.append(verb)
            return (["step": "done", "error": ""], 0)
        case "--keys-stdin":
            if let keysError { return (["identity": keysError], 1) }
            guard state.step == "done" else { return (["identity": "adoption_unfinished"], 1) }
            if state.identity != "adopted", state.identity != "confirmed" { applied.append(verb) }
            if state.identity != "confirmed" { state.identity = "adopted" }
            return (["identity": "adopted"], 0)
        case "--confirm-deleted":
            if let confirmError { return (["identity": confirmError], 1) }
            guard state.identity == "adopted" || state.identity == "confirmed" else { return (["identity": "not_adopted"], 1) }
            state.identity = "confirmed"
            return (["identity": "confirmed"], 0)
        case "--set-aside":
            return setAside()
        default:
            return (["error": "usage"], 1)
        }
    }

    private func setAside() -> ([String: Any], Int32) {
        if let setAsideError { return (["set_aside": setAsideError], 1) }
        guard state.step.isEmpty else { return (["set_aside": "adoption_started"], 1) }
        (state.swiftState, state.pending) = ("absent", [])
        applied.append("--set-aside")
        return (["set_aside": "done"], 0)
    }
}

/// The Kit key store over an in-memory keychain, with its calls logged.
final class FakeHubKeyStore: HubKeyStore, @unchecked Sendable {
    private let inner = InMemoryHubKeyStore()
    private let log: AdoptionLog
    private let lock = NSLock()
    private var present: Set<String> = []
    var readError = false
    var deleteError = false
    /// A partial identity in the keychain (`.corrupt`).
    var partial = false
    var killAfter: Set<String> = []
    /// Identities created through `hubIdentity` (the adoption never may).
    private(set) var creations = 0

    init(log: AdoptionLog) { self.log = log }

    @discardableResult
    func seed(hubID: String) throws -> HubIdentityKeys {
        let keys = try inner.hubIdentity(hubID: hubID).keys
        lock.withLock { _ = present.insert(hubID) }
        return keys
    }

    func has(_ hubID: String) -> Bool { lock.withLock { present.contains(hubID) } }

    func hubIdentity(hubID: String) throws -> (keys: HubIdentityKeys, created: Bool) {
        log.append("keychain:create-or-get:\(hubID)")
        let loaded = try inner.hubIdentity(hubID: hubID)
        if loaded.created { lock.withLock { creations += 1 } }
        lock.withLock { _ = present.insert(hubID) }
        return loaded
    }

    func existingHubIdentity(hubID: String) throws -> HubIdentityKeys? {
        log.append("keychain:lookup:\(hubID)")
        if readError { throw KeyStoreError.locked }
        if partial { throw KeyStoreError.corrupt("hub identity is partially present") }
        let found = has(hubID) ? try inner.existingHubIdentity(hubID: hubID) : nil
        if killAfter.contains("keychain:lookup") { throw FakeKill() }
        return found
    }

    func deleteHubIdentity(hubID: String) throws {
        log.append("keychain:delete:\(hubID)")
        if deleteError { throw KeyStoreError.locked }
        try inner.deleteHubIdentity(hubID: hubID)
        lock.withLock { _ = present.remove(hubID) }
        if killAfter.contains("keychain:delete") { throw FakeKill() }
    }
}
