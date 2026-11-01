import CryptoKit
import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// The Kit phone against a live headless Go hub over the relay's local stand (Go hub phase 2, Task 12),
/// run by `make relay-interop RELAY=../relay KIT=1`. The script brings the stand and the hub up and
/// exports two variables; without them every test skips, so the ordinary Kit suite never needs a stand.
///
/// - `WT_RELAY_INTEROP_URL`: the stand's origin.
/// - `WT_HUB_INTEROP_DIR`: the handoff folder. `hub.json` (`mode` `live|test` — a Mac with the app runs
///   the phase-1 test mode, which has no relay-only rules —, `workbench_id`, `typed`, `ready`: the stub
///   `claude`'s input file and ready mark); `pair.url` (the v4 link to parse); the test writes the code
///   its phone shows to `pair.sas` (temp file + rename) and the script confirms it only when it equals
///   the hub's; `pair.result` (the pairing's last line, written after a linked phone got the typing and
///   start_sessions grants).
///
/// The script pairs once, so the class shares one linked phone (`GoHubPhone`), linked by whichever test
/// runs first; a link that failed fails every test with the same error. The phone is the Kit's own stack
/// over `HostedRelayTransport`: `SecureTransport` with `PhoneKeyProvider`, `EnvelopeReplicaOpener`,
/// `ReplicaStore`, the ordered `ActionOutbox`, `RecordingUploader` and `RelayFeed`. The link steps the
/// app's link flow does on CloudKit (the hello, the keybox wait, the code) are done here by hand over a
/// `.pairing(slot:)` transport, with the relay's own steps (`open_pairing`, `vouch_hub`,
/// `promote_pairing`) through `HostedRelayPairing`.
final class GoHubInteropTests: XCTestCase {
    private static let cache = GoHubPhoneCache()

    override static func tearDown() {
        // The phone's socket and transports go with the class (no process to reap: nothing was spawned).
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await cache.close()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 15)
        super.tearDown()
    }

    /// The stand's origin and the handoff folder, or a skip when the script did not start the run.
    private func interopEnvironment() throws -> GoHubEnvironment {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["WT_RELAY_INTEROP_URL"], !origin.isEmpty,
              let dir = env["WT_HUB_INTEROP_DIR"], !dir.isEmpty
        else {
            throw XCTSkip("needs WT_RELAY_INTEROP_URL and WT_HUB_INTEROP_DIR: run make relay-interop RELAY=../relay KIT=1")
        }
        return GoHubEnvironment(origin: origin, dir: URL(fileURLWithPath: dir, isDirectory: true))
    }

    private func linkedPhone() async throws -> GoHubPhone {
        try await Self.cache.phone(try interopEnvironment())
    }

    /// The Kit parses the relay-only v4 QR, says hello with its `relay_device_id`, shows the hub's SAS,
    /// vouches and promotes; its `device_grant.transports == ["relay"]`.
    func testKitPhoneLinksAHeadlessHub() async throws {
        let phone = try await linkedPhone()
        let payload = phone.payload
        XCTAssertEqual(payload.v, 4)
        XCTAssertTrue(payload.offersRelay, "the link names the hub's relay device and key")
        XCTAssertEqual(payload.relayDeviceID, phone.grant.relayDeviceID, "the grant names the relay device of the link")
        XCTAssertTrue(phone.grant.linked)
        XCTAssertNotEqual(phone.grant.revoked, true)
        XCTAssertEqual(phone.grant.deviceID.uppercased(), phone.deviceID.uuidString)
        XCTAssertTrue(phone.grant.typingAllowed, "the script's hub allow … typing")
        XCTAssertTrue(phone.grant.mayStartSessions, "the script's hub allow … start_sessions")
        XCTAssertTrue(phone.grant.runsOrderedActions, "a Go hub runs ordered actions only")
        if phone.handoff.mode == "live" {
            // A headless host is relay-only: the code offers no CloudKit and the grant names the relay alone.
            XCTAssertEqual(payload.transports, ["relay"])
            XCTAssertFalse(payload.offersCloudKit)
            XCTAssertEqual(phone.grant.transports, ["relay"])
        } else {
            // The phase-1 test mode (a Mac with the app installed) has no relay-only rules: it still
            // links over the relay, but what else it offers is not this test's.
            XCTAssertTrue(phone.grant.transports?.contains("relay") == true, "transports \(phone.grant.transports ?? [])")
        }
    }

    /// Spec §13 E2E (3): every record kind the Go hub sealed opens on the phone.
    func testKitPhoneOpensEveryRecordKindTheGoHubSealed() async throws {
        let phone = try await linkedPhone()
        // The hub's own records and the script's workbench: the slices are published on the hub's tick.
        let required: Set<String> = [SliceKind.heartbeat.rawValue, SliceKind.deviceGrant.rawValue, SliceKind.workbench.rawValue]
        let opened = try await GoHubWait.until("the heartbeat, the grant and the workbench in the data zone", within: 120) {
            let opened = try await phone.openDataZone()
            return required.isSubset(of: Set(opened.map(\.kind))) ? opened : nil
        }
        let kinds = Set(opened.map(\.kind))
        for kind in kinds {
            XCTAssertNotNil(SliceKind(rawValue: kind), "\(kind) is a kind this Kit knows")
        }
        print("GoHubInteropTests: opened \(opened.count) records of kinds \(kinds.sorted())")
    }

    /// Actions a1..a3, one a `session_input` to the stub session, come back `applied` in order.
    func testGoHubAppliesKitActionsInOrder() async throws {
        let phone = try await linkedPhone()
        let marker = "wt-kit-interop-\(UUID().uuidString.prefix(8).lowercased())"
        let start = try await phone.outbox.enqueue(kind: .sessionStart, entityRecordName: nil, params: [
            "workbench_id": .integer(phone.handoff.workbenchID), "mode": .string("new"), "plan_first": .bool(false),
            "bring_forward": .bool(false), "brief": .string("Kit interop \(marker)")
        ])
        let started = try await phone.waitApplied(start)
        let sessionID: Int64
        switch started.result?["session_id"] {
        case .integer(let id): sessionID = id
        case .double(let id): sessionID = Int64(id)
        default: return XCTFail("session_start result without a session id: \(String(describing: started.result))")
        }
        XCTAssertGreaterThan(sessionID, 0)
        try await GoHubWait.until("the stub claude ready", within: 60) {
            FileManager.default.fileExists(atPath: phone.handoff.ready) ? true : nil
        }

        let session = SliceKind.terminalSession.recordName(id: String(sessionID))
        let first = "\(marker)-a2", second = "\(marker)-a3"
        // The brief went in as the session's first line and the stub reports no hook after it, so the hub
        // holds these lines `agent_busy` for its 30 s settle window (`busyAfterSubmit`) and types them on
        // the held-line retry: this test takes ~40 s by design.
        let input1 = try await phone.outbox.enqueue(kind: .sessionInput, entityRecordName: session, params: ["text": .string(first)])
        let input2 = try await phone.outbox.enqueue(kind: .sessionInput, entityRecordName: session, params: ["text": .string(second)])
        let typed1 = try await phone.waitApplied(input1)
        let typed2 = try await phone.waitApplied(input2)

        let order = phone.appliedOrder().filter { [start, input1, input2].contains($0.id) }
        XCTAssertEqual(order.map(\.id), [start, input1, input2], "applied in the order sent")
        let seqs = [started, typed1, typed2].compactMap(\.actionSeq)
        XCTAssertEqual(seqs.count, 3, "every echo carries its action_seq")
        XCTAssertEqual(seqs, seqs.sorted(), "action_seq rises a1 < a2 < a3")
        XCTAssertEqual(Set(seqs).count, 3)

        // Each line typed as a bracketed paste and submitted, the second after the first.
        let want1 = Data("\u{1b}[200~\(first)\u{1b}[201~".utf8), want2 = Data("\u{1b}[200~\(second)\u{1b}[201~".utf8)
        let typed = try await GoHubWait.until("both lines in the stub's input", within: 60) { () -> Data? in
            guard let bytes = FileManager.default.contents(atPath: phone.handoff.typed),
                  let one = bytes.range(of: want1), let two = bytes.range(of: want2, in: one.upperBound..<bytes.endIndex)
            else { return nil }
            return bytes.suffix(from: two.upperBound) == Data("\r".utf8) ? bytes : nil
        }
        XCTAssertFalse(typed.isEmpty)
    }

    /// A recording sent to a headless hub ends `failed not_supported`.
    func testRecordingOnAHeadlessHubIsNotSupported() async throws {
        let phone = try await linkedPhone()
        let file = phone.recordings.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data((0..<4_096).map { _ in UInt8.random(in: .min ... .max) }).write(to: file)
        let ended = Date()
        let row = try await phone.uploader.register(
            fileURL: file, startedAt: ended.addingTimeInterval(-5), endedAt: ended, titleHint: "Kit interop")
        let id = try XCTUnwrap(row?.id, "the capture registered")
        let failed = try await GoHubWait.until("the recording's final echo", within: 120) { () -> PhoneRecording? in
            _ = try await GoHubWait.step("the upload pass", quiet: true) { try await phone.uploader.uploadPending() }
            await phone.hub.sendNow()
            _ = try await GoHubWait.step("the mailbox poll", quiet: true) { try await phone.feed.pollOnce() }
            guard let row = try phone.replica.phoneRecording(id: id) else { return nil }
            if row.state == .delivered { throw GoHubInteropError.unexpected("a headless hub took the recording") }
            return row.state == .failed ? row : nil
        }
        XCTAssertNil(failed.failure, "the hub's verdict, not a local failure")
        // The Go hub's NotSupportedMessage (internal/hub/actions/handlers/recording.go); the Kit's payload
        // keeps no reason, so the message names not_supported.
        XCTAssertEqual(failed.errorMessage, "This host can't transcribe recordings. Your recording stays on your phone.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a failed echo keeps the audio on the phone")
    }
}

// MARK: - The handoff

struct GoHubEnvironment: Sendable {
    let origin: String
    let dir: URL
}

/// `hub.json` of the handoff folder.
struct GoHubHandoff: Decodable, Sendable {
    let mode: String
    let workbenchID: Int64
    let typed: String
    let ready: String

    enum CodingKeys: String, CodingKey {
        case mode
        case workbenchID = "workbench_id"
        case typed
        case ready
    }
}

enum GoHubInteropError: LocalizedError {
    case timedOut(String)
    case refused(String)
    case actionFailed(id: String, message: String?, reason: String?)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let what): return "timed out waiting for \(what)"
        case .refused(let line): return "the hub refused the link: \(line)"
        case let .actionFailed(id, message, reason):
            return "action \(id) failed: \(message ?? "no message") (\(reason ?? "no reason"))"
        case .unexpected(let what): return what
        }
    }
}

enum GoHubWait {
    /// `body`, its error named after `name` (a relay error alone does not say which call it answered).
    @discardableResult
    static func step<T>(_ name: String, quiet: Bool = false, _ body: () async throws -> T) async throws -> T {
        if !quiet { print("GoHubInteropTests: \(name)") }
        do {
            return try await body()
        } catch let error as GoHubInteropError {
            throw error
        } catch {
            throw GoHubInteropError.unexpected("\(name): \(error)")
        }
    }

    /// Calls `probe` every half second until it gives a value, for at most `seconds`.
    @discardableResult
    static func until<T>(_ what: String, within seconds: TimeInterval, _ probe: () async throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let value = try await probe() { return value }
            guard Date() < deadline else { throw GoHubInteropError.timedOut(what) }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// The one link of the class: made by the first test that asks, its error kept for the others.
actor GoHubPhoneCache {
    private var linking: Task<GoHubPhone, Error>?

    func phone(_ env: GoHubEnvironment) async throws -> GoHubPhone {
        if let linking { return try await linking.value }
        let task = Task { try await GoHubPhone.link(env) }
        linking = task
        return try await task.value
    }

    func close() async {
        guard let phone = try? await linking?.value else { return }
        await phone.close()
    }
}

// MARK: - The phone

/// One data-zone record the phone opened.
struct GoHubOpenedRecord: Sendable {
    let wireName: String
    let kind: String
}

/// A Kit phone linked to the script's hub.
final class GoHubPhone: @unchecked Sendable {
    let handoff: GoHubHandoff
    let payload: LinkPayload
    let deviceID: UUID
    let grant: DeviceGrant
    let hub: HostedRelayTransport
    let secure: SecureTransport
    let replica: ReplicaStore
    let outbox: ActionOutbox
    let uploader: RecordingUploader
    let feed: RelayFeed
    let recordings: URL
    private let opener: EnvelopeReplicaOpener
    private let directory: URL
    private let applied: OSAllocatedUnfairLock<[ActionRequestPayload]>

    private init(link: Link, grant: DeviceGrant) async {
        handoff = link.handoff
        payload = link.payload
        deviceID = link.deviceID
        self.grant = grant
        hub = link.hub
        secure = link.secure
        replica = link.replica
        opener = link.opener
        directory = link.directory
        recordings = link.directory.appendingPathComponent("recordings", isDirectory: true)
        let applied = OSAllocatedUnfairLock<[ActionRequestPayload]>(initialState: [])
        self.applied = applied
        outbox = ActionOutbox(
            transport: link.secure, store: link.replica, deviceID: link.deviceID.uuidString,
            route: .hostedRelay(macDeviceID: link.macDeviceID))
        uploader = RecordingUploader(
            transport: link.secure, store: link.replica, directory: recordings, deviceID: link.deviceID.uuidString)
        let hub = link.hub
        feed = RelayFeed(transport: link.secure, store: link.replica, outbox: outbox, uploads: uploader) {
            try await hub.pull()
        }
        await outbox.setHubID(link.payload.hubID)
        await outbox.setAppliedObserver { action in applied.withLock { $0.append(action) } }
    }

    /// What `link` builds before the grant is read.
    private struct Link {
        let handoff: GoHubHandoff
        let payload: LinkPayload
        let deviceID: UUID
        let macDeviceID: String
        let hub: HostedRelayTransport
        let secure: SecureTransport
        let replica: ReplicaStore
        let opener: EnvelopeReplicaOpener
        let directory: URL
    }

    func close() async {
        await outbox.drain()
        await hub.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The applied echoes, in the order the feed routed them.
    func appliedOrder() -> [ActionRequestPayload] {
        applied.withLock { $0 }
    }

    /// Polls the mailbox until `id`'s applied echo came; a failed echo throws with its message.
    func waitApplied(_ id: String) async throws -> ActionRequestPayload {
        try await GoHubWait.until("an applied echo for \(id)", within: 90) { () -> ActionRequestPayload? in
            _ = try await GoHubWait.step("the outbox flush", quiet: true) { try await outbox.flush() }
            _ = try await GoHubWait.step("the mailbox poll", quiet: true) { try await feed.pollOnce() }
            if let echo = appliedOrder().first(where: { $0.id == id }) { return echo }
            if let row = try replica.pendingActions().first(where: { $0.id == id }), row.state == .failed {
                throw GoHubInteropError.actionFailed(id: id, message: row.errorMessage, reason: row.reason?.rawValue)
            }
            return nil
        }
    }

    /// Pulls the data zone and opens every hub record in it as the replica does: the keybox of this phone
    /// to its `Keybox`, the rest with the epoch keys, each under the wire name the phone derives for it.
    /// Signals and other phones' keyboxes are left out (they open nowhere on this phone).
    func openDataZone() async throws -> [GoHubOpenedRecord] {
        try await hub.pull()
        var opened: [GoHubOpenedRecord] = []
        for record in try await secure.changes(in: .data, since: nil).changed {
            if record.kind == WireKind.signal { continue }
            if let owner = Self.keyboxOwner(record.recordName) {
                guard owner == deviceID else { continue }
                _ = try opener.openKeybox(wireName: record.recordName, envelope: record.payload)
                opened.append(GoHubOpenedRecord(wireName: record.recordName, kind: SliceKind.deviceGrant.rawValue))
                continue
            }
            let frame: InnerFrame
            do {
                frame = try opener.open(wireName: record.recordName, envelope: record.payload)
            } catch {
                throw GoHubInteropError.unexpected("\(record.recordName) does not open: \(error)")
            }
            let wire = try secure.wireName(plain: frame.id, zone: .data)
            guard wire == record.recordName else {
                throw GoHubInteropError.unexpected("\(frame.id) arrived as \(record.recordName), the phone names it \(wire)")
            }
            opened.append(GoHubOpenedRecord(wireName: record.recordName, kind: frame.kind))
        }
        return opened
    }

    private static func keyboxOwner(_ wireName: String) -> UUID? {
        guard wireName.hasPrefix("keybox-") else { return nil }
        return UUID(uuidString: String(wireName.dropFirst("keybox-".count)))
    }

    // MARK: Linking

    /// Links a fresh phone to the hub of `pair.url`: register and pay on the stand, open the slot, the
    /// hello with this phone's relay device id, the code to `pair.sas`, the linked keybox, `pair.result`,
    /// vouch, promote; then the hub-mode transport on the same store and the grant from the data zone.
    static func link(_ env: GoHubEnvironment) async throws -> GoHubPhone {
        let handoff = try await GoHubWait.until("hub.json", within: 30) { () -> GoHubHandoff? in
            guard let data = FileManager.default.contents(atPath: env.dir.appendingPathComponent("hub.json").path) else { return nil }
            return try JSONDecoder().decode(GoHubHandoff.self, from: data)
        }
        let payload = try await scannedPayload(env)
        guard let mac = payload.relayDeviceID, let authText = payload.relayAuthPub,
              let authPub = WireBytes.fromBase64URL(authText),
              let nonce = WireBytes.fromBase64URL(payload.nonce),
              let hubSigning = WireBytes.fromBase64URL(payload.hubSigningKey),
              let hubAgreement = WireBytes.fromBase64URL(payload.hubAgreementKey)
        else { throw GoHubInteropError.unexpected("the link code carries no relay device, key or hub keys") }

        // The phone's keys, and the hub's from the code (the link before the owner confirmed it).
        let keys = InMemoryPhoneKeyStore()
        let identity = try keys.identity()
        try keys.saveHubLink(HubLinkKeys(
            hubID: payload.hubID, hubSigningKey: hubSigning, hubAgreementKey: hubAgreement, linkNonce: nonce))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("go-hub-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        let opener = EnvelopeReplicaOpener(hubID: payload.hubID, deviceID: identity.deviceID, keys: keys)
        let replica = try ReplicaStore(path: directory.appendingPathComponent("replica.sqlite").path, opener: opener)
        let seq = SeqAllocator(
            load: { try replica.envelopeSeqCeiling() }, store: { try replica.setEnvelopeSeqCeiling($0) })
        let provider = try PhoneKeyProvider(store: keys, hubID: payload.hubID, seq: seq)
        let rollback = InMemoryRollbackGuard()
        let store = try TransportStore(path: directory.appendingPathComponent("transport.sqlite").path)

        let client = try await GoHubWait.step("register and pay") { try await payingPhone(env) }
        let session = HostedRelaySession(client: client)
        let pairer = HostedRelayPairing(session: session)
        let (slot, _) = try await GoHubWait.step("open_pairing") { try await pairer.open(mac: mac) }
        let pairing = try HostedRelayTransport(session: session, store: store, macDeviceID: mac, mode: .pairing(slot: slot))
        let pairSecure = SecureTransport(inner: pairing, keys: provider, rollback: rollback)

        try await sayHello(payload, identity: identity, relayDeviceID: client.deviceID, through: pairSecure)
        await pairing.sendNow()

        let code = PairingCode(
            hubID: try WireBytes.hubUUID(payload.hubID), linkNonce: nonce,
            hubSigning: try Curve25519.Signing.PublicKey(rawRepresentation: hubSigning),
            hubAgreement: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hubAgreement), device: identity)
        let boxKeys = try await waitForConfirmedKeybox(env, transport: pairing, secure: pairSecure, opener: opener, code: code)
        try saveKeys(boxKeys, in: keys, hubID: payload.hubID)
        // The script gives the grants, then writes the result; only then is the link the owner's.
        try await GoHubWait.until("pair.result", within: 60) { () -> String? in
            guard let line = try pairResult(env) else { return nil }
            guard line.contains("\"linked\"") else { throw GoHubInteropError.refused(line) }
            return line
        }

        try await GoHubWait.step("vouch_hub") { try await pairer.vouch(hubDeviceID: mac, authPub: authPub) }
        try await GoHubWait.step("promote_pairing") { try await pairer.promote(slot: slot) }
        await pairing.stop()

        let hub = try HostedRelayTransport(session: session, store: store, macDeviceID: mac, mode: .hub)
        let secure = SecureTransport(inner: hub, keys: provider, rollback: rollback)
        await hub.start()
        let grant = try await GoHubWait.until("the device_grant in the data zone", within: 120) { () -> DeviceGrant? in
            do {
                try await hub.pull()
            } catch HostedRelayError.server(code: .forbidden, _) {
                // The relay lets the phone read the data zone once the hub named it a reader
                // (`set_hub_readers`), which the hub does when it sees the promoted slot: until then, wait.
                return nil
            } catch {
                throw GoHubInteropError.unexpected("the first hub-mode pull: \(error)")
            }
            guard let box = try await keybox(in: secure, opener: opener, deviceID: identity.deviceID) else { return nil }
            let grant = box.grant
            return grant.linked && grant.typingAllowed && grant.mayStartSessions ? grant : nil
        }
        if grant.runsOrderedActions { try replica.enableOrderedActions() }
        let link = Link(
            handoff: handoff, payload: payload, deviceID: identity.deviceID, macDeviceID: mac, hub: hub, secure: secure,
            replica: replica, opener: opener, directory: directory)
        return await GoHubPhone(link: link, grant: grant)
    }

    /// The hello (mobile E2E spec §2.3) with this phone's relay device id, sealed to the hub's key.
    private static func sayHello(
        _ payload: LinkPayload, identity: DeviceIdentityKeys, relayDeviceID: String, through secure: SecureTransport
    ) async throws {
        let now = Date()
        let device = DevicePayload(
            deviceID: identity.deviceID.uuidString, name: "Kit Interop Phone", model: "iPhone18,1",
            appVersion: "0.0.0-interop", scope: .private, userRecordName: "", linkNonce: payload.nonce,
            typingRequested: true, startSessions: true, updatedAt: now)
        let hello = DeviceHello(
            device: device,
            signingKey: WireBytes.base64URL(identity.signing.publicKey.rawRepresentation),
            agreementKey: WireBytes.base64URL(identity.agreement.publicKey.rawRepresentation),
            relayDeviceID: relayDeviceID)
        try await secure.save([try CloudRecordFactory.record(for: hello, modifiedAt: now)])
    }

    /// What the four-digit code is computed from (the app's `ScannedHubKeys.code`), bar the hub's
    /// confirm nonce.
    private struct PairingCode {
        let hubID: UUID
        let linkNonce: Data
        let hubSigning: Curve25519.Signing.PublicKey
        let hubAgreement: Curve25519.KeyAgreement.PublicKey
        let device: DeviceIdentityKeys

        func code(confirmNonce: Data) -> String {
            KeyDerivation.sas(
                hubID: hubID, linkNonce: linkNonce, hubSigning: hubSigning, hubAgreement: hubAgreement,
                deviceSigning: device.signing.publicKey, deviceAgreement: device.agreement.publicKey,
                confirmNonce: confirmNonce)
        }
    }

    private static func scannedPayload(_ env: GoHubEnvironment) async throws -> LinkPayload {
        let text = try await GoHubWait.until("pair.url", within: 30) { () -> String? in
            guard let data = FileManager.default.contents(atPath: env.dir.appendingPathComponent("pair.url").path),
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return text
        }
        guard let url = URL(string: text) else { throw GoHubInteropError.unexpected("pair.url is not a URL") }
        switch LinkPayload.parse(url) {
        case .success(let payload): return payload
        case .failure(let error): throw GoHubInteropError.unexpected("the link code does not parse: \(error)")
        }
    }

    /// A fresh phone registered and logged in on the stand (attestation off there), its account paying.
    private static func payingPhone(_ env: GoHubEnvironment) async throws -> HostedRelayClient {
        let origin = try RelayOrigin(env.origin)
        let clock = SystemRelayClock()
        let client = HostedRelayClient(
            origin: origin, signer: Ed25519RelaySigner(Curve25519.Signing.PrivateKey()), kind: .phone,
            attestor: RelayAttestor(attest: FakeAppAttest(), keys: InMemoryAppAttestKeyStore(), clock: clock),
            http: URLSessionRelayHTTP(), sockets: URLSessionRelaySocketDialer(), clock: clock)
        _ = try await client.register()
        try await client.login()
        let control = HTTPRelayStandControl(origin: origin.url)
        let account = try await control.accountID(ofPhone: client.deviceID)
        try await control.setEntitlement(accountID: account, state: "active", for: .seconds(365 * 86_400))
        return client
    }

    /// Pulls the pair zone until the hub's keybox for this phone carries keys: a waiting keybox's
    /// confirm nonce gives the code, written once to `pair.sas`; a refusal (in the keybox or in
    /// `pair.result`) throws.
    private static func waitForConfirmedKeybox(
        _ env: GoHubEnvironment,
        transport: HostedRelayTransport,
        secure: SecureTransport,
        opener: EnvelopeReplicaOpener,
        code: PairingCode
    ) async throws -> KeyboxKeys {
        let linkCodeTag = KeyDerivation.linkCodeTag(linkNonce: code.linkNonce)
        var wroteCode = false
        return try await GoHubWait.until("the confirmed keybox in the pair zone", within: 600) { () -> KeyboxKeys? in
            if let line = try pairResult(env), !line.contains("\"linked\"") { throw GoHubInteropError.refused(line) }
            try await GoHubWait.step("the pair-zone pull") { try await transport.pull() }
            guard let box = try await keybox(in: secure, opener: opener, deviceID: code.device.deviceID) else { return nil }
            let grant = box.grant
            if let refusal = grant.linkRefused { throw GoHubInteropError.refused(refusal.rawValue) }
            if grant.linked, let keys = box.keys { return keys }
            if !wroteCode, grant.awaitingConfirmation == true, grant.linkCodeTag == linkCodeTag,
               let text = grant.confirmNonce, let confirm = WireBytes.fromBase64URL(text),
               confirm.count == KeyDerivation.confirmNonceLength {
                try writeAtomically(code.code(confirmNonce: confirm), to: env.dir.appendingPathComponent("pair.sas"))
                wroteCode = true
            }
            return nil
        }
    }

    /// This phone's keybox in the data lane (the pair zone while linking), opened; nil while there is none.
    private static func keybox(in secure: SecureTransport, opener: EnvelopeReplicaOpener, deviceID: UUID) async throws -> Keybox? {
        let records = try await secure.changes(in: .data, since: nil).changed
        guard let record = records.last(where: { keyboxOwner($0.recordName) == deviceID }) else { return nil }
        return try opener.openKeybox(wireName: record.recordName, envelope: record.payload)
    }

    /// The keybox's keys joined to the scanned link (the app's `HubLinkKeys.adding`).
    private static func saveKeys(_ box: KeyboxKeys, in keys: InMemoryPhoneKeyStore, hubID: String) throws {
        func key(_ text: String) throws -> Data {
            guard let bytes = WireBytes.fromBase64URL(text), bytes.count == 32 else {
                throw GoHubInteropError.unexpected("a keybox key is not 32 bytes")
            }
            return bytes
        }
        guard var link = try keys.hubLink(hubID) else { throw GoHubInteropError.unexpected("the scanned link is gone") }
        var epochs = [box.epoch: EpochKeys(epoch: box.epoch, dataKey: try key(box.dataKey), alertKey: try key(box.alertKey))]
        if let previous = box.previousEpoch, let data = box.previousDataKey, let alert = box.previousAlertKey {
            epochs[previous] = EpochKeys(epoch: previous, dataKey: try key(data), alertKey: try key(alert))
        }
        link.metaKey = try key(box.metaKey)
        link.epochs = epochs.values.sorted { $0.epoch < $1.epoch }
        try keys.saveHubLink(link)
    }

    private static func pairResult(_ env: GoHubEnvironment) throws -> String? {
        guard let data = FileManager.default.contents(atPath: env.dir.appendingPathComponent("pair.result").path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Temp file + rename: the script never reads half a code.
    private static func writeAtomically(_ text: String, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try Data(text.utf8).write(to: temp)
        guard rename(temp.path, url.path) == 0 else {
            throw GoHubInteropError.unexpected("rename to \(url.lastPathComponent) failed: errno \(errno)")
        }
    }
}
