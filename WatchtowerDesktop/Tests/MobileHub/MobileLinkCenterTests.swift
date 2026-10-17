import CloudKit
import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerE2ETesting
import WatchtowerSync

/// A settable clock shared by the center and the test.
final class LinkTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// The hub's two zone shares in memory: share creation, the public link,
/// participants, and a log of every call.
final class FakeShareService: ShareService, @unchecked Sendable {
    struct Share: Equatable {
        let url: String
        var publicOpen = false
        var participants: [ShareParticipant] = []
    }

    private let lock = NSLock()
    private var account: CloudAvailability
    private var shareByZone: [CloudZoneID: Share] = [:]
    private var createdCount = 0
    private var log: [String] = []
    private var failing = false
    /// Call names (before the `:`) that throw, or hang for 5 s (a regression
    /// fails on time, never hangs the suite).
    private var failingCalls: Set<String> = []
    private var hangingCalls: Set<String> = []
    private var cancellationAware = false
    /// Call names that park on their gate until the test releases it.
    private var gates: [String: SaveGate] = [:]
    /// Call names that throw for their next N calls.
    private var failCounts: [String: Int] = [:]
    private var linkCallsRunning = 0
    private var mostLinkCallsRunning = 0

    init(account: CloudAvailability = .available) {
        self.account = account
    }

    var created: Int { lock.withLock { createdCount } }
    var calls: [String] { lock.withLock { log } }
    var shares: [CloudZoneID: Share] { lock.withLock { shareByZone } }
    /// True only when both shares exist and their public link is open.
    var isLinkOpen: Bool { lock.withLock { shareByZone.count == 2 && shareByZone.values.allSatisfy(\.publicOpen) } }
    /// The most `setPublicLink` calls ever running at once.
    var maxConcurrentLinkCalls: Int { lock.withLock { mostLinkCallsRunning } }

    func setAccount(_ value: CloudAvailability) { lock.withLock { account = value } }
    /// Every share call throws (sharing impossible on this account).
    func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    func clearCalls() { lock.withLock { log = [] } }
    func setFailing(_ calls: Set<String>) { lock.withLock { failingCalls = calls } }
    func setHanging(_ calls: Set<String>) { lock.withLock { hangingCalls = calls } }
    /// The next `call` parks on `gate` (once).
    func gate(_ call: String, on gate: SaveGate) { lock.withLock { gates[call] = gate } }
    /// A call whose task was cancelled still takes effect, then throws
    /// `CancellationError` (like a cancelled CloudKit await: the server may
    /// have applied the save, the caller reads a failure).
    func setCancellationAware(_ value: Bool) { lock.withLock { cancellationAware = value } }
    /// The next `times` calls named `call` throw.
    func failNext(_ call: String, times: Int) { lock.withLock { failCounts[call] = times } }

    /// A participant (a phone, or a stranger who opened the URL) joins both shares.
    func join(_ userRecordName: String, accepted: Bool = true, zones: [CloudZoneID] = [.data, .relay]) {
        lock.withLock {
            for zone in zones {
                shareByZone[zone]?.participants.append(ShareParticipant(userRecordName: userRecordName, accepted: accepted))
            }
        }
    }

    func participantNames(in zone: CloudZoneID) -> [String] {
        lock.withLock { shareByZone[zone]?.participants.compactMap(\.userRecordName) ?? [] }
    }

    private func record(_ call: String) async throws {
        let name = String(call.prefix { $0 != ":" })
        let (fails, hangs, gate) = lock.withLock {
            log.append(call)
            let counted = (failCounts[name] ?? 0) > 0
            if counted { failCounts[name, default: 0] -= 1 }
            return (
                failing || failingCalls.contains(name) || counted, hangingCalls.contains(name), gates.removeValue(forKey: name)
            )
        }
        await gate?.park()
        if fails { throw URLError(.cannotConnectToHost) }
        if hangs { try await Task.sleep(for: .seconds(5)) }
    }

    /// After a call took effect: a cancelled one throws in cancellation-aware mode.
    private func settle() throws {
        if lock.withLock({ cancellationAware }) { try Task.checkCancellation() }
    }

    func accountStatus() async -> CloudAvailability {
        lock.withLock {
            log.append("accountStatus")
            return account
        }
    }

    func ensureShares() async throws -> ShareURLs {
        try await record("ensureShares")
        let urls = lock.withLock {
            for zone in [CloudZoneID.data, .relay] where shareByZone[zone] == nil {
                createdCount += 1
                shareByZone[zone] = Share(url: "https://www.icloud.com/share/\(zone.rawValue)-\(createdCount)")
            }
            return ShareURLs(data: shareByZone[.data]?.url ?? "", relay: shareByZone[.relay]?.url ?? "")
        }
        try settle()
        return urls
    }

    func setPublicLink(open: Bool) async throws {
        lock.withLock {
            linkCallsRunning += 1
            mostLinkCallsRunning = max(mostLinkCallsRunning, linkCallsRunning)
        }
        defer { lock.withLock { linkCallsRunning -= 1 } }
        try await record("setPublicLink:\(open)")
        lock.withLock {
            for zone in shareByZone.keys { shareByZone[zone]?.publicOpen = open }
        }
        try settle()
    }

    func participants(in zone: CloudZoneID) async throws -> [ShareParticipant] {
        try await record("participants:\(zone.rawValue)")
        let found = lock.withLock { shareByZone[zone]?.participants ?? [] }
        try settle()
        return found
    }

    func removeParticipants(in zone: CloudZoneID, where shouldRemove: @escaping @Sendable (ShareParticipant) -> Bool) async throws {
        try await record("removeParticipants:\(zone.rawValue)")
        lock.withLock { shareByZone[zone]?.participants.removeAll(where: shouldRemove) }
        try settle()
    }

    /// A test helper, not a protocol member: the zones and their shares are gone.
    func dropAll() { lock.withLock { shareByZone = [:] } }
}

/// The Mac side of linking (mobile POC spec §2.3, §4.13, §5.2 rule 4, §10;
/// mobile E2E spec §2.3: hellos, owner confirmation, keyboxes) on a fake
/// share service, a fake clock and an in-memory hub keyring.
@MainActor
final class MobileLinkCenterTests: XCTestCase {
    var sidecar: HubSyncState!
    var shares: FakeShareService!
    var clock: LinkTestClock!
    private var keyring: HubKeyring!
    var nudges: [Set<SliceKind>] = []
    private var sharing: [HubSharing] = []
    var center: MobileLinkCenter!

    override func setUp() async throws {
        sidecar = try HubSyncState.inMemory()
        shares = FakeShareService()
        clock = LinkTestClock()
        nudges = []
        sharing = []
        center = try makeCenter()
    }

    override func tearDown() async throws {
        // Ends the expiry timer of an open code.
        await center?.closeAfterLink?.value
        await center?.closeLink(reason: .sheetClosed)
        center?.cancelSweepRetry()
        center = nil
        keyring = nil
        sidecar = nil
        shares = nil
        clock = nil
    }

    /// The expiry timer and the sweep retries park (until cancelled) unless a test passes its own sleep; the
    /// answering close's grace is zero and does not park, so its sweep runs at once (`settleSweep`). A fresh keyring
    /// over the current sidecar; the hellos of the test are sealed to it.
    func makeCenter(
        sleep: (@Sendable (Duration) async -> Void)? = nil,
        shareTimeout: Duration = .seconds(30),
        answerGrace: Duration = .zero,
        ownerUser: (@Sendable () async -> String?)? = nil
    ) throws -> MobileLinkCenter {
        let clock = try XCTUnwrap(self.clock)
        keyring = try sidecar.testKeyring { clock.now }
        let made = MobileLinkCenter(
            sidecar: sidecar, shares: shares, macName: "Mac acme", ownerUser: ownerUser ?? { "_owner-acme" },
            keyring: keyring,
            nudge: { [weak self] in self?.nudges.append($0) },
            now: { clock.now },
            sleep: sleep ?? { duration in
                guard duration > .zero else { return }
                try? await Task.sleep(for: .seconds(3600))
            },
            shareTimeout: shareTimeout,
            answerGrace: answerGrace
        )
        made.onSharingChanged = { [weak self] in self?.sharing.append($0) }
        return made
    }

    /// The two test phones with relay keys (`TestE2E`): their ids are the hashes of their signing keys, and the
    /// relay tests' hub holds their relay keys. C and D are fresh phones.
    let identityA = TestE2E.deviceIdentity
    let identityB = TestE2E.strangerIdentity
    private let identityC = TestHello.newPhone()
    private let identityD = TestHello.newPhone()
    let phoneA = TestE2E.deviceID.uuidString
    let phoneB = TestE2E.strangerDeviceID.uuidString
    private let strangerID = TestE2E.strangerDeviceID.uuidString
    private var phoneC: String { identityC.deviceID.uuidString }
    private var phoneD: String { identityD.deviceID.uuidString }

    private func devicePayload(
        _ deviceID: String,
        nonce: String?,
        scope: DeviceScope = .private,
        user: String = "_owner-acme",
        name: String = "iPhone",
        unlinked: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        typingRequested: Bool = false,
        startSessions: Bool = true,
        permissionsRequested: Bool = false
    ) -> DevicePayload {
        DevicePayload(
            deviceID: deviceID, name: name, model: "iPhone18,1", appVersion: "0.0.0-test", scope: scope,
            userRecordName: user, linkNonce: nonce, unlinked: unlinked, typingRequested: typingRequested,
            startSessions: startSessions, permissionsRequested: permissionsRequested, updatedAt: clock.now
        )
    }

    /// A linked phone's own `device` record (no nonce: an unlink or a start-sessions choice).
    func deviceRecord(
        _ deviceID: String,
        nonce: String?,
        scope: DeviceScope = .private,
        user: String = "_owner-acme",
        creator: String? = nil,
        name: String = "iPhone",
        unlinked: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        typingRequested: Bool = false,
        startSessions: Bool = true,
        permissionsRequested: Bool = false
    ) throws -> CloudRecord {
        let payload = devicePayload(
            deviceID, nonce: nonce, scope: scope, user: user, name: name, unlinked: unlinked,
            typingRequested: typingRequested, startSessions: startSessions, permissionsRequested: permissionsRequested)
        let record = try CloudRecordFactory.record(for: payload, modifiedAt: clock.now)
        return CloudRecord(
            recordName: record.recordName, zone: record.zone, kind: record.kind, modifiedAt: record.modifiedAt,
            payload: record.payload, creatorUserRecordName: creator
        )
    }

    /// `phone`'s hello for the code `nonce`, as the relay hands it over (still sealed).
    func hello(
        _ phone: DeviceIdentityKeys,
        nonce: String,
        scope: DeviceScope = .private,
        user: String = "_owner-acme",
        creator: String? = nil,
        name: String = "iPhone",
        deviceID: String? = nil,
        signer: Curve25519.Signing.PrivateKey? = nil,
        wire: Bool = false,
        typingRequested: Bool = false,
        startSessions: Bool = true
    ) throws -> CloudRecord {
        let id = deviceID ?? phone.deviceID.uuidString
        return try TestHello.record(
            devicePayload(
                id, nonce: nonce, scope: scope, user: user, name: name, typingRequested: typingRequested,
                startSessions: startSessions),
            from: phone, to: keyring, nonce: nonce,
            signer: signer, senderID: deviceID.flatMap(UUID.init(uuidString:)), creator: creator, wire: wire)
    }

    /// Waits for the deferred sweep of an answering close (zero grace here) to end; only where it succeeds.
    func settleSweep() async {
        await center.sweepRetry?.value
    }

    /// One hello, still waiting for the owner.
    func handle(_ record: CloudRecord) async throws {
        try await center.handleHello(record)
    }

    /// One hello the owner confirms, and the close that follows the link.
    func link(_ record: CloudRecord) async throws {
        try await center.handleHello(record)
        let deviceID = String(record.recordName.dropFirst("hello-".count))
        try await confirm(deviceID)
        await center.closeAfterLink?.value
    }

    /// The owner's Link on the waiting request of `deviceID`, with the code it shows.
    private func confirm(_ deviceID: String) async throws {
        let sas = try XCTUnwrap(center.pendingLinks.first { $0.id == deviceID }?.sas, "no request waits for \(deviceID)")
        try await center.confirmLink(deviceID: deviceID, sas: sas)
    }

    /// The code `phone` computes from the QR it scanned, its own public keys and the confirm nonce its waiting
    /// keybox carries (SAS v2).
    private func phoneSAS(_ phone: DeviceIdentityKeys, scanned code: LinkPayload) async throws -> String {
        let keybox = try await openedKeybox(phone)
        let confirmNonce = try XCTUnwrap(keybox.grant.confirmNonce.flatMap(WireBytes.fromBase64URL), "no confirm nonce")
        return try TestHello.sas(phone, scanned: code, confirmNonce: confirmNonce)
    }

    /// One linked phone's own device record, and the close that may follow.
    func handleDevice(_ record: CloudRecord) async throws {
        try await center.handleDevice(record)
        await center.closeAfterLink?.value
    }

    func grants() throws -> [String: DeviceGrant] {
        try Dictionary(uniqueKeysWithValues: grantRecords().map {
            ($0.id, try RelayCoder.makeDecoder().decode(Keybox.self, from: $0.payload).grant)
        })
    }

    private func grantRecords() throws -> [SliceRecord] {
        let hubID = try sidecar.ensureHubID()
        let clock = try XCTUnwrap(self.clock)
        let slice = DeviceGrantSlice(sidecar: sidecar, hubID: hubID, keyring: keyring) { clock.now }
        // The slice reads the sidecar; the main-DB handle is unused.
        return try DatabaseQueue().read { try slice.records($0) }
    }

    /// `phone`'s keybox as the phone reads it: sealed by the hub, opened with the phone's own key, signature checked.
    func openedKeybox(_ phone: DeviceIdentityKeys) async throws -> Keybox {
        let keybox = try await TestHello.keybox(for: phone, in: grantRecords(), keyring: keyring)
        return try XCTUnwrap(keybox, "no keybox for \(phone.deviceID)")
    }

    // MARK: - Hellos, the owner's confirmation and keyboxes (mobile E2E spec §2.3)

    func testTheQRCarriesTheHubsPublicKeys() async throws {
        let code = try await center.issueCode()

        guard case .success(let scanned) = LinkPayload.parse(code.url()) else { return XCTFail("the phone refuses the QR") }
        XCTAssertEqual(scanned.v, 3)
        XCTAssertEqual(WireBytes.fromBase64URL(scanned.hubSigningKey), keyring.signingPublicKey.rawRepresentation)
        XCTAssertEqual(WireBytes.fromBase64URL(scanned.hubAgreementKey), keyring.agreementPublicKey.rawRepresentation)
    }

    func testAValidHelloWaitsForTheOwnerAndPublishesNoKeys() async throws {
        let code = try await center.issueCode()
        nudges = []

        try await handle(try hello(identityA, nonce: code.nonce, name: "Acme iPhone"))

        XCTAssertEqual(center.pendingLinks.map(\.id), [phoneA])
        XCTAssertEqual(center.pendingLinks.first?.name, "Acme iPhone")
        XCTAssertEqual(center.pendingLinks.first?.sas.count, 4)
        XCTAssertTrue(nudges.contains([.deviceGrant]))
        let keybox = try await openedKeybox(identityA)
        XCTAssertEqual(keybox.grant.awaitingConfirmation, true)
        XCTAssertFalse(keybox.grant.linked)
        XCTAssertNil(keybox.grant.linkRefused)
        XCTAssertNil(keybox.keys, "no key before the owner's Link")
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice, "the code is not consumed")
        XCTAssertNotNil(center.openCode, "the QR stays open while the owner decides")
    }

    func testTheSameHelloTwiceIsOneRequest() async throws {
        let code = try await center.issueCode()
        let scan = try hello(identityA, nonce: code.nonce)
        try await handle(scan)
        let first = try XCTUnwrap(center.pendingLinks.first)
        nudges = []
        clock.advance(5)

        try await handle(scan)

        XCTAssertEqual(center.pendingLinks, [first])
        XCTAssertTrue(nudges.isEmpty)
    }

    func testConfirmLinksAndPublishesASignedKeyboxWithTheCurrentEpoch() async throws {
        let code = try await center.issueCode()
        try await handle(try hello(identityA, nonce: code.nonce))

        try await confirm(phoneA)
        await center.closeAfterLink?.value

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertEqual(try sidecar.linkCode(code.nonce)?.usedByDevice, phoneA)
        let row = try XCTUnwrap(try sidecar.deviceKeyRow(phoneA))
        XCTAssertEqual(row.agreementKey, identityA.agreement.publicKey.rawRepresentation)
        XCTAssertEqual(row.linkNonce, code.nonce)
        let keybox = try await openedKeybox(identityA)
        XCTAssertTrue(keybox.grant.linked)
        XCTAssertNil(keybox.grant.awaitingConfirmation)
        let keys = try XCTUnwrap(keybox.keys)
        let epoch = try keyring.currentEpoch()
        XCTAssertEqual(keys.epoch, epoch)
        let epochKeys = try keyring.epochKeys(epoch)
        XCTAssertEqual(WireBytes.fromBase64URL(keys.dataKey), epochKeys.dataKey)
        XCTAssertEqual(WireBytes.fromBase64URL(keys.alertKey), epochKeys.alertKey)
        XCTAssertEqual(WireBytes.fromBase64URL(keys.metaKey), try keyring.metaKey().withUnsafeBytes { Data($0) })
        XCTAssertNil(center.openCode, "the post-link close ran")
        XCTAssertFalse(shares.isLinkOpen)
    }

    /// Review Focus 5 (F17): a photographed QR races the owner's phone. Both requests show, each with its own code;
    /// only the confirmed one gets keys, the other reads `used_code` without keys, and no key is ever wrapped for it.
    func testTwoHellosForOneCodeShowTwoCodesAndOnlyTheConfirmedOneGetsKeys() async throws {
        let code = try await center.issueCode()
        try await handle(try hello(identityA, nonce: code.nonce, name: "Owner iPhone"))
        try await handle(try hello(identityB, nonce: code.nonce, name: "Other iPhone"))

        XCTAssertEqual(center.pendingLinks.count, 2)
        XCTAssertEqual(Set(center.pendingLinks.map(\.id)), [phoneA, phoneB], "one row per device")
        for (phone, id) in [(identityA, phoneA), (identityB, phoneB)] {
            let phoneCode = try await phoneSAS(phone, scanned: code)
            XCTAssertEqual(
                center.pendingLinks.first { $0.id == id }?.sas, phoneCode,
                "each row shows the code its own phone computes")
        }
        for phone in [identityA, identityB] {
            let waiting = try await openedKeybox(phone)
            XCTAssertEqual(waiting.grant.awaitingConfirmation, true)
            XCTAssertNil(waiting.keys)
        }

        try await confirm(phoneA)
        await center.closeAfterLink?.value

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
        let linked = try await openedKeybox(identityA)
        XCTAssertNotNil(linked.keys)
        let refused = try await openedKeybox(identityB)
        XCTAssertEqual(refused.grant.linkRefused, .usedCode)
        XCTAssertFalse(refused.grant.linked)
        XCTAssertNil(refused.keys, "never a key for an unconfirmed device")
        XCTAssertTrue(center.pendingLinks.isEmpty, "B's request is gone")
        XCTAssertNil(try sidecar.deviceKeyRow(phoneB))
    }

    /// F4: the hub does not know which kept code a phone scanned, so it tries each kept code's nonce.
    func testAHelloIsOpenedWithTheMatchingKeptNonce() async throws {
        let older = try await center.issueCode()
        clock.advance(10)
        let newer = try await center.issueCode()

        try await handle(try hello(identityA, nonce: older.nonce))
        try await handle(try hello(identityB, nonce: newer.nonce))

        XCTAssertEqual(try grants()[phoneA]?.linkRefused, .expiredCode, "decided against the older (retired) code")
        XCTAssertEqual(center.pendingLinks.map(\.id), [phoneB], "the newer code's request waits")

        nudges = []
        try await handle(try hello(identityC, nonce: LinkPayload.makeNonce()))

        XCTAssertNil(try grants()[phoneC], "a hello under no kept code is unanswerable")
        XCTAssertTrue(try sidecar.linkRefusals().allSatisfy { $0.deviceID != phoneC })
        XCTAssertEqual(center.pendingLinks.map(\.id), [phoneB])
        XCTAssertTrue(nudges.isEmpty, "nothing published")
    }

    /// F5: a refusal keybox is sealed to the refused hello's key.
    func testARefusedHelloGetsARefusalKeyboxSealedToItsKey() async throws {
        let code = try await center.issueCode()
        clock.advance(601)

        try await handle(try hello(identityA, nonce: code.nonce))

        let refusal = try XCTUnwrap(try sidecar.linkRefusals().first { $0.deviceID == phoneA })
        XCTAssertEqual(refusal.agreementKey, identityA.agreement.publicKey.rawRepresentation)
        let keybox = try await openedKeybox(identityA)
        XCTAssertEqual(keybox.grant.linkRefused, .expiredCode)
        XCTAssertNil(keybox.keys)
        XCTAssertTrue(center.pendingLinks.isEmpty)
    }

    func testClosingTheSheetRefusesPendingRequestsBeforeTheSweep() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        try await handle(try hello(identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"))
        XCTAssertEqual(center.pendingLinks.map(\.id), [phoneA])
        let gate = SaveGate()
        shares.gate("setPublicLink", on: gate)

        let close = Task { await center.closeLink(reason: .sheetClosed) }
        await fulfillment(of: [gate.arrived], timeout: 5)

        XCTAssertEqual(try grants()[phoneA]?.linkRefused, .notConfirmed, "refused before the share calls")
        XCTAssertEqual(shares.participantNames(in: .relay), ["_colleague-a"], "not swept yet")
        gate.release()
        await close.value
        await settleSweep()
        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertTrue(shares.participantNames(in: .relay).isEmpty, "swept after the refusal")
        let keybox = try await openedKeybox(identityA)
        XCTAssertEqual(keybox.grant.linkRefused, .notConfirmed)
        XCTAssertNil(keybox.keys)
    }

    func testRefuseAnswersNotConfirmedAndKeepsTheCodeOpen() async throws {
        let code = try await center.issueCode()
        try await handle(try hello(identityA, nonce: code.nonce))

        try await center.refuseLink(deviceID: phoneA)

        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(try grants()[phoneA]?.linkRefused, .notConfirmed)
        XCTAssertEqual(center.openCode, code, "the owner's own phone can still scan it")
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice)
    }

    func testTheCodesExpiryRefusesWaitingRequestsWithExpiredCode() async throws {
        let code = try await center.issueCode()
        try await handle(try hello(identityA, nonce: code.nonce))

        clock.advance(600)
        await center.closeLinkIfExpired()

        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertEqual(try grants()[phoneA]?.linkRefused, .expiredCode)
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice)
    }

    func testAConfirmAfterTheCodeExpiredRefusesWithExpiredCode() async throws {
        let code = try await center.issueCode()
        try await handle(try hello(identityA, nonce: code.nonce))
        clock.advance(601)

        try await confirm(phoneA)

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(center.pendingLinks.isEmpty)
        let keybox = try await openedKeybox(identityA)
        XCTAssertEqual(keybox.grant.linkRefused, .expiredCode)
        XCTAssertNil(keybox.keys)
    }

    func testAHelloWhoseDeviceIDIsNotItsKeyHashIsIgnored() async throws {
        let code = try await center.issueCode()
        nudges = []

        // Phone A's keys under phone C's id: the id is not the hash of the signing key.
        try await handle(try hello(identityA, nonce: code.nonce, deviceID: phoneC))

        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        XCTAssertTrue(nudges.isEmpty)
    }

    /// The key-auth twin of the creator checks: the right creator and scope, but the envelope is signed by another
    /// key than the one the hello carries.
    func testAHelloSignedByAnotherKeyIsIgnored() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        nudges = []

        try await handle(try hello(
            identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a",
            signer: identityB.signing))

        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        XCTAssertTrue(nudges.isEmpty)
    }

    func testTheSASMatchesThePhonesComputation() async throws {
        let code = try await center.issueCode()
        try await handle(try hello(identityA, nonce: code.nonce))

        let phoneCode = try await phoneSAS(identityA, scanned: code)
        XCTAssertEqual(center.pendingLinks.first?.sas, phoneCode)
    }

    /// Link binds the code the owner compared: a request replaced meanwhile (a new code, so a new SAS) is not linked
    /// and waits for a fresh decision.
    func testLinkingARequestWhoseCodeChangedLinksNothingAndKeepsTheRequest() async throws {
        let first = try await center.issueCode()
        try await handle(try hello(identityA, nonce: first.nonce))
        let seen = try XCTUnwrap(center.pendingLinks.first?.sas)
        let second = try await center.issueCode()
        try await handle(try hello(identityA, nonce: second.nonce))
        let now = try await phoneSAS(identityA, scanned: second)
        XCTAssertEqual(center.pendingLinks.map(\.sas), [now], "the request was replaced")
        try XCTSkipIf(now == seen, "the two codes collided (1 in 10 000)")

        do {
            try await center.confirmLink(deviceID: phoneA, sas: seen)
            XCTFail("a replaced request must not link")
        } catch let error as MobileLinkError {
            XCTAssertEqual(error, .linkCodeChanged)
        }

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(center.pendingLinks.map(\.sas), [now], "kept for a fresh decision")
        XCTAssertNil(try sidecar.linkCode(second.nonce)?.usedByDevice)
        XCTAssertNil(try sidecar.deviceKeyRow(phoneA))

        try await center.confirmLink(deviceID: phoneA, sas: now)
        await center.closeAfterLink?.value
        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
    }

    func testTheRelayHandsHellosToTheLinkCenter() async throws {
        let code = try await center.issueCode()
        let transport = StubHubTransport()
        try await transport.save([try hello(identityA, nonce: code.nonce, wire: true)])
        let center = try XCTUnwrap(self.center)
        let processor = RelayProcessor(
            transport: MobileHubStorage.sealing(transport, keyring: keyring, sidecar: sidecar), sidecar: sidecar,
            dispatcher: MobileHubCommandDispatcher(), hubID: try sidecar.ensureHubID(), deviceRecords: center.relayRoute
        )

        let pass = try await processor.processOnce()

        XCTAssertEqual(pass, .init(handled: 1, remaining: 0), "budgeted (target 168), unlike a device record")
        XCTAssertEqual(center.pendingLinks.map(\.id), [phoneA])
        XCTAssertNotNil(processor.lastActivityAt)
    }

    func testHygieneAgesOutAWeekOldHello() async throws {
        let code = try await center.issueCode()
        let transport = StubHubTransport()
        let stale = try hello(identityA, nonce: code.nonce, wire: true)
        clock.advance(RelayProcessor.actionMaxAge + 60)
        let fresh = try hello(identityB, nonce: code.nonce, wire: true)
        try await transport.save([stale, fresh])
        let clock = try XCTUnwrap(self.clock)
        let processor = RelayProcessor(
            transport: MobileHubStorage.sealing(transport, keyring: keyring, sidecar: sidecar), sidecar: sidecar,
            dispatcher: MobileHubCommandDispatcher(), hubID: try sidecar.ensureHubID()
        ) { clock.now }

        try await processor.runHygieneIfDue()

        let left = try await transport.changes(in: .relay, since: nil).changed.map(\.recordName)
        XCTAssertEqual(left, [fresh.recordName])
    }

    func testAUsedCodeRecordedUnderAnotherSpellingIsStillThisDevices() {
        let code = HubSyncState.LinkCode(nonce: "n", issuedAt: Date(), exp: Date(), usedByDevice: phoneA.lowercased())

        XCTAssertEqual(HubSyncState.LinkDecision.of(code, deviceID: phoneA, now: Date()), .alreadyUsedByThisDevice)
        XCTAssertEqual(HubSyncState.LinkDecision.of(code, deviceID: phoneB, now: Date()), .refused(.usedCode))
    }

    /// #64 review F3: the phone reads a deleted grant as its removal, so no
    /// linked phone's grant is ever capped; refusals fill only the room left
    /// under 20, the latest first.
    func testEveryLinkedPhonesGrantIsPublishedAndOnlyRefusalsAreCapped() throws {
        let now = try XCTUnwrap(clock).now
        // Inside the refusals' lifetime on the test clock.
        let refuse = { (id: String, ago: TimeInterval) in
            try self.sidecar.saveLinkRefusal(HubSyncState.LinkRefusalRecord(
                deviceID: id, name: "iPhone", scope: .private, reason: .expiredCode, at: now.addingTimeInterval(-ago)
            ))
        }
        for index in 0..<18 { try sidecar.linkTestDevice("phone-\(index)") }
        try refuse("refused-old", 300)
        try refuse("refused-mid", 200)
        try refuse("refused-new", 100)
        var published = try grants()
        XCTAssertEqual(published.values.filter(\.linked).count, 18)
        XCTAssertEqual(Set(published.values.filter { !$0.linked }.map(\.deviceID)), ["refused-new", "refused-mid"])

        for index in 18..<21 { try sidecar.linkTestDevice("phone-\(index)") }
        published = try grants()
        XCTAssertEqual(published.count, 21, "21 linked phones, every grant published")
        XCTAssertTrue(published.values.allSatisfy(\.linked), "no room left for a refusal")
    }

    // MARK: - One link, idempotent

    func testAValidCodeLinksOnceAndTheSameQRScannedTwiceStaysOneLink() async throws {
        let code = try await center.issueCode()
        XCTAssertEqual(code.exp, code.iat + 600)
        let scan = try hello(identityA, nonce: code.nonce)

        try await link(scan)
        clock.advance(5)
        try await handle(scan)

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
        XCTAssertTrue(center.pendingLinks.isEmpty, "the same QR again is no new request")
        XCTAssertEqual(try sidecar.linkedDevices().count, 1)
        let grants = try grants()
        XCTAssertEqual(grants.count, 1)
        let grant = try XCTUnwrap(grants[phoneA])
        XCTAssertTrue(grant.linked)
        XCTAssertNil(grant.linkRefused)
        XCTAssertEqual(grant.hubID, code.hubID)
        XCTAssertEqual(grant.scope, .private)
        XCTAssertFalse(grant.typingAllowed, "typing needs the owner's Allow")
        XCTAssertTrue(grant.startSessionsAllowed)
        XCTAssertEqual(try sidecar.linkCode(code.nonce)?.usedByDevice, phoneA)
        XCTAssertTrue(nudges.contains([.deviceGrant]))
        XCTAssertNil(center.openCode, "the code is used")
    }

    // MARK: - Refusals

    /// F4 changed one answer: a made-up code opens under no kept nonce, so it is unanswerable (no `unknown_code`).
    func testAUsedExpiredOrMadeUpCodeIsRefusedWithItsReason() async throws {
        let used = try await center.issueCode()
        try await link(try hello(identityA, nonce: used.nonce))
        try await handle(try hello(identityB, nonce: used.nonce))

        let old = try await center.issueCode()
        clock.advance(601)
        try await handle(try hello(identityC, nonce: old.nonce))
        try await handle(try hello(identityD, nonce: LinkPayload.makeNonce()))

        let grants = try grants()
        XCTAssertEqual(grants[phoneB]?.linkRefused, .usedCode)
        XCTAssertEqual(grants[phoneC]?.linkRefused, .expiredCode)
        XCTAssertNil(grants[phoneD], "unknown_code is unanswerable: the hello opens under no kept code")
        for id in [phoneB, phoneC] {
            XCTAssertEqual(grants[id]?.linked, false, id)
            XCTAssertNil(grants[id]?.linkedAt, id)
        }
        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertNil(try sidecar.linkCode(old.nonce)?.usedByDevice, "an expired code is never used")
    }

    func testACodeIsStillValidAtExactly600Seconds() async throws {
        let code = try await center.issueCode()
        clock.advance(600)

        try await link(try hello(identityA, nonce: code.nonce))

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
    }

    func testALinkedPhoneKeepsItsLinkWhenItSendsAnUnknownCodeLater() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        let later = try await center.issueCode()
        clock.advance(601)

        try await handle(try hello(identityA, nonce: LinkPayload.makeNonce()))
        try await handle(try hello(identityA, nonce: later.nonce))

        XCTAssertEqual(try grants()[phoneA]?.linked, true)
        XCTAssertNil(try grants()[phoneA]?.linkRefused)
    }

    func testARemovedPhoneIsNotLinkedAgainByItsOldCode() async throws {
        let code = try await center.issueCode()
        let scan = try hello(identityA, nonce: code.nonce)
        try await link(scan)
        try await center.remove(deviceID: phoneA)

        try await handle(scan)

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(center.pendingLinks.isEmpty)
        // Task 14 (D9): the only answer is the removal's revoked keybox; no link, no request.
        XCTAssertEqual(Array(try grants().keys), [phoneA])
        XCTAssertEqual(try grants()[phoneA]?.revoked, true)
        XCTAssertEqual(try grants()[phoneA]?.linked, false)
    }

    // MARK: - Two phones

    func testTwoPhonesWithTheirOwnCodesAreBothLinkedAndRemovingOneLeavesTheOtherApplied() async throws {
        try await linkPhonesAAndB()

        try await center.remove(deviceID: phoneA)

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneB])
        // Task 14 (D9): the removed phone's keybox reads revoked instead of leaving the zone.
        XCTAssertEqual(Set(try grants().keys), [phoneA, phoneB])
        XCTAssertEqual(try grants()[phoneA]?.revoked, true)
        XCTAssertEqual(try grants()[phoneB]?.linked, true)
        let transport = StubHubTransport()
        let fromA = try probe(from: phoneA)
        let fromB = try probe(from: phoneB)
        try await transport.save([fromA, fromB])
        _ = try await RelayProcessor(
            transport: relaySide(transport), sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        ).processOnce()

        XCTAssertEqual(try lastEcho(fromA, in: transport)?.reason, .deviceNotLinked)
        XCTAssertEqual(try lastEcho(fromB, in: transport)?.status, .applied)
    }

    /// The hub's sealing transport over `transport`, holding both test phones' relay keys: the sidecar alone
    /// decides which of them is linked.
    private func relaySide(_ transport: StubHubTransport) -> SecureTransport {
        let keys = TestE2E.hub()
        keys.link(TestE2E.strangerIdentity)
        return testSecureTransport(transport, keys: keys)
    }

    /// A probe naming `deviceID`, sealed by the test phone of that id (the paired phone for any other id).
    private func probe(from deviceID: String, creator: String? = nil) throws -> CloudRecord {
        let action = ActionRequestPayload(
            id: UUID().uuidString, kind: .probe, entityID: nil, params: ["nonce": .string("n-\(deviceID)")],
            createdAt: Date(), deviceID: deviceID
        )
        let record = try CloudRecordFactory.record(for: action, modifiedAt: Date())
        return try TestRelayPhone.seal(
            CloudRecord(
                recordName: record.recordName, zone: record.zone, kind: record.kind, modifiedAt: record.modifiedAt,
                payload: record.payload, creatorUserRecordName: creator
            ),
            as: deviceID == phoneB ? TestE2E.strangerIdentity : TestE2E.deviceIdentity)
    }

    private func lastEcho(_ record: CloudRecord, in transport: StubHubTransport) throws -> ActionRequestPayload? {
        try transport.saved.last { $0.record.recordName == record.recordName && $0.record != record }
            .map { try decodeAction($0.record) }
    }

    // MARK: - Shared scope

    func testASharedPhoneThatAcceptedBothSharesIsLinked() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")

        try await link(try hello(identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"))

        XCTAssertEqual(center.devices.map(\.scope), [.shared])
        XCTAssertEqual(try grants()[phoneA]?.linked, true)
    }

    func testASharedDeviceRecordFromAnotherCreatorIsRefusedWithNoGrant() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        shares.join("_stranger")

        try await handle(try hello(identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_stranger"))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertTrue(try grants().isEmpty, "no grant, not even a refusal")
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice, "the code stays usable for the owner's phone")
    }

    func testASharedPhoneThatDidNotAcceptBothSharesIsNotLinked() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a", zones: [.data])

        try await handle(try hello(identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice)
    }

    func testAPrivateDeviceRecordWrittenByAStrangerIsNotLinked() async throws {
        let code = try await center.issueCode()

        try await handle(try hello(identityA, nonce: code.nonce, scope: .private, creator: "_stranger"))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(center.pendingLinks.isEmpty)
    }

    // MARK: - The device gate

    func testAnActionFromAnUnlinkedDeviceFailsDeviceNotLinkedAndIsNeverDispatched() async throws {
        let dispatcher = MobileHubCommandDispatcher()
        var dispatched = 0
        dispatcher.register(.sessionReportRequest) { _ in
            dispatched += 1
            return .applied()
        }
        let action = ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionReportRequest, entityID: "7", params: [:], createdAt: Date(), deviceID: strangerID
        )
        let transport = StubHubTransport()
        let record = try TestRelayPhone.seal(
            try CloudRecordFactory.record(for: action, modifiedAt: Date()), as: TestE2E.strangerIdentity)
        try await transport.save([record])

        _ = try await RelayProcessor(
            transport: relaySide(transport), sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme"
        ).processOnce()

        let echo = try XCTUnwrap(try lastEcho(record, in: transport))
        XCTAssertEqual(echo.status, .failed)
        XCTAssertEqual(echo.reason, .deviceNotLinked)
        XCTAssertEqual(dispatched, 0)
    }

    func testASharedPhonesActionWrittenByAnotherCreatorFailsDeviceNotLinked() async throws {
        try sidecar.linkTestDevice(phoneA, scope: .shared, userRecordName: "_colleague-a")
        let transport = StubHubTransport()
        let forged = try probe(from: phoneA, creator: "_stranger")
        let genuine = try probe(from: phoneA, creator: "_colleague-a")
        let unknown = try probe(from: phoneA)
        try await transport.save([forged, genuine, unknown])

        _ = try await RelayProcessor(
            transport: relaySide(transport), sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        ).processOnce()

        XCTAssertEqual(try lastEcho(forged, in: transport)?.reason, .deviceNotLinked)
        XCTAssertEqual(try lastEcho(genuine, in: transport)?.status, .applied)
        XCTAssertEqual(try lastEcho(unknown, in: transport)?.reason, .deviceNotLinked, "a shared phone's record needs its creator")
    }

    /// A linked phone's sealed device record (its unlink or start-sessions choice) reaches the link center.
    func testTheRelayHandsDeviceRecordsToTheLinkCenter() async throws {
        try await linkPhonesAAndB()
        let transport = StubHubTransport()
        try await transport.save([try TestRelayPhone.seal(try deviceRecord(phoneA, nonce: nil, startSessions: false))])

        try await relayDeviceRecords(over: transport)

        XCTAssertEqual(try grants()[phoneA]?.startSessionsAllowed, false)
    }

    /// A device record carrying a code links nothing: a link request is a hello.
    func testADeviceRecordWithACodeLinksNothing() async throws {
        let code = try await center.issueCode()

        try await handleDevice(try deviceRecord(phoneA, nonce: code.nonce))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice)
    }

    /// One relay pass over `transport` whose device records go to the link center.
    private func relayDeviceRecords(over transport: StubHubTransport) async throws {
        let center = try XCTUnwrap(self.center)
        let processor = RelayProcessor(
            transport: relaySide(transport), sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme",
            deviceRecords: .init { try await center.handleDevice($0) }
        )
        _ = try await processor.processOnce()
        await center.closeAfterLink?.value
    }

    /// Both test phones linked through their own codes.
    private func linkPhonesAAndB() async throws {
        let first = try await center.issueCode()
        try await link(try hello(identityA, nonce: first.nonce))
        clock.advance(30)
        let second = try await center.issueCode()
        try await link(try hello(identityB, nonce: second.nonce))
        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA, phoneB])
    }

    /// A sealed device record acts only for the phone whose key opened it: phone A writing phone B's unlink is
    /// dropped, B stays linked with its grant.
    func testAPhoneCannotUnlinkAnotherLinkedPhone() async throws {
        try await linkPhonesAAndB()
        let before = try grants()[phoneB]
        let transport = StubHubTransport()
        try await transport.save([try TestRelayPhone.seal(try deviceRecord(phoneB, nonce: nil, unlinked: true))])

        try await relayDeviceRecords(over: transport)

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA, phoneB], "B stays linked")
        XCTAssertEqual(try grants()[phoneB], before, "B's grant is unchanged")
        XCTAssertNotNil(try sidecar.linkedDevice(phoneB))
    }

    /// The same for the start-sessions choice: only B's own record changes B's grant.
    func testAPhoneCannotChangeAnotherPhonesStartSessionsGrant() async throws {
        try await linkPhonesAAndB()
        XCTAssertEqual(try grants()[phoneB]?.startSessionsAllowed, true)
        let transport = StubHubTransport()
        try await transport.save([try TestRelayPhone.seal(try deviceRecord(phoneB, nonce: nil, startSessions: false))])

        try await relayDeviceRecords(over: transport)

        XCTAssertEqual(try grants()[phoneB]?.startSessionsAllowed, true, "A's record for B changes nothing")

        try await transport.save([
            try TestRelayPhone.seal(try deviceRecord(phoneB, nonce: nil, startSessions: false), as: TestE2E.strangerIdentity)
        ])
        try await relayDeviceRecords(over: transport)

        XCTAssertEqual(try grants()[phoneB]?.startSessionsAllowed, false, "B's own record is applied")
    }

    /// Device ids match ignoring case everywhere: removing a phone by a differently spelled id unlinks it.
    func testRemoveWithADifferentlyCasedIDUnlinksThePhone() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        XCTAssertNotNil(try sidecar.linkedDevice(phoneA.lowercased()))

        try await center.remove(deviceID: phoneA.lowercased())

        XCTAssertNil(try sidecar.linkedDevice(phoneA))
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty, "no row is left under either spelling")
        XCTAssertTrue(center.devices.isEmpty)
    }

    // MARK: - Rotation on Remove and unlink (Task 14, spec §2.2, D9, D10)

    /// The hub's DataZone sealing over the real keyring (signed, current epoch).
    private func hubSecure() -> SecureTransport {
        SecureTransport(inner: InMemoryCloudTransport(), keys: keyring, rollback: keyring, names: sidecar)
    }

    private func sealedSample(_ id: String) async throws -> CloudRecord {
        let record = SliceRecord(kind: .workbench, id: id, modifiedAt: clock.now, payload: Data("{\"id\":\"\(id)\"}".utf8))
        return try await hubSecure().seal(CloudRecordFactory.record(for: record))
    }

    /// A DataZone envelope opened the way a phone opens it (hub signature checked) with `key` for its epoch.
    private func openData(_ wire: CloudRecord, key: (UInt32) throws -> Data) throws -> InnerFrame {
        try EnvelopeSealer.openSymmetric(
            wire.payload, accepting: [.data], context: EnvelopeContext(zone: .data, wireName: wire.recordName),
            verifier: keyring.signingPublicKey
        ) { header in SymmetricKey(data: try key(header.epoch)) }.frame
    }

    /// `phone`'s keybox keys; fails when its keybox carries none.
    private func openedKeyboxKeys(_ phone: DeviceIdentityKeys) async throws -> KeyboxKeys {
        let keybox = try await openedKeybox(phone)
        return try XCTUnwrap(keybox.keys, "no keys in the keybox of \(phone.deviceID)")
    }

    private static func keyBytes(_ text: String?) throws -> Data {
        try XCTUnwrap(WireBytes.fromBase64URL(try XCTUnwrap(text)))
    }

    func testRemoveRotatesAndTheRemovedPhoneCannotOpenNewRecords() async throws {
        try await linkPhonesAAndB()
        let keysA = try await openedKeyboxKeys(identityA)
        XCTAssertEqual(keysA.epoch, 1)
        let dataKeyA = try Self.keyBytes(keysA.dataKey)
        let before = try await sealedSample("before")
        nudges = []

        try await center.remove(deviceID: phoneA)

        XCTAssertEqual(try keyring.currentEpoch(), 2)
        XCTAssertTrue(nudges.contains { $0.contains(.deviceGrant) })
        XCTAssertTrue(
            try sidecar.hashes(forKind: .deviceGrant).values.allSatisfy(\.isEmpty), "the window is republished")
        let after = try await sealedSample("after")
        XCTAssertEqual(try openData(before) { _ in dataKeyA }.id, "workbench-before", "A keeps what it already had")
        XCTAssertThrowsError(try openData(after) { _ in dataKeyA }, "A's key opens no epoch-2 record") {
            XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed)
        }

        let keysB = try await openedKeyboxKeys(identityB)
        XCTAssertEqual(keysB.epoch, 2)
        XCTAssertEqual(keysB.previousEpoch, 1)
        XCTAssertEqual(keysB.previousDataKey, keysA.dataKey, "B gets the retired epoch's keys too")
        XCTAssertEqual(keysB.metaKey, keysA.metaKey, "K_meta does not rotate (D5)")
        let keyOfB: (UInt32) throws -> Data = { epoch in
            try Self.keyBytes(epoch == keysB.epoch ? keysB.dataKey : epoch == keysB.previousEpoch ? keysB.previousDataKey : nil)
        }
        XCTAssertEqual(try openData(after, key: keyOfB).id, "workbench-after")
        XCTAssertEqual(try openData(before, key: keyOfB).id, "workbench-before")
    }

    /// D9: the removed phone's keybox stays, sealed to it and signed, reading `revoked` without keys for 7 days.
    func testTheRemovedPhonesKeyboxReadsRevokedForSevenDays() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))

        try await center.remove(deviceID: phoneA)

        let keybox = try await openedKeybox(identityA)
        XCTAssertEqual(keybox.grant.revoked, true)
        XCTAssertFalse(keybox.grant.linked)
        XCTAssertNil(keybox.grant.linkRefused)
        XCTAssertNil(keybox.keys, "a removed phone gets no key")
        clock.advance(7 * 86_400 - 1)
        XCTAssertEqual(try grants()[phoneA]?.revoked, true)
        clock.advance(1)
        XCTAssertNil(try grants()[phoneA], "unpublished after 7 days")
        center.pruneExpiredAnswers()
        XCTAssertNil(try keyring.keyboxRecipient(deviceID: identityA.deviceID))
    }

    func testAPhonesOwnUnlinkRotatesLikeRemove() async throws {
        try await linkPhonesAAndB()
        let keysA = try await openedKeyboxKeys(identityA)

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, unlinked: true))

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneB])
        XCTAssertEqual(try keyring.currentEpoch(), 2)
        let removed = try await openedKeybox(identityA)
        XCTAssertEqual(removed.grant.revoked, true)
        XCTAssertNil(removed.keys)
        let keysB = try await openedKeyboxKeys(identityB)
        XCTAssertEqual(keysB.epoch, 2)
        XCTAssertNotEqual(keysB.dataKey, keysA.dataKey)
        XCTAssertEqual(keysB.previousDataKey, keysA.dataKey)
    }

    /// D9: after Remove the hub has no relay key for the phone: its records of the current and the previous epoch
    /// are dropped, never echoed, never ledgered, and its `relay_seen` rows are gone (F3).
    func testRelayRecordsOfTheRemovedPhoneAreDroppedNotEchoed() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityC, nonce: code.nonce))
        let hubID = try WireBytes.hubUUID(try sidecar.ensureHubID())
        let nonce = try XCTUnwrap(WireBytes.fromBase64URL(code.nonce))
        let secure = hubSecure()
        let now = clock.now
        let phone = identityC
        let hubAgreement = keyring.agreementPublicKey
        /// A probe sealed by phone C at `epoch` with the relay key C derives itself; its wire record and plain name.
        func probe(_ label: String, epoch: UInt32) throws -> (wire: CloudRecord, plain: String) {
            let action = ActionRequestPayload(
                id: "probe-\(label)", kind: .probe, entityID: nil, params: ["nonce": .string(label)], createdAt: now,
                deviceID: phone.deviceID.uuidString)
            let plain = try CloudRecordFactory.record(for: action, modifiedAt: now)
            let wire = try secure.wireName(plain: plain.recordName, zone: .relay)
            let key = try KeyDerivation.relayKey(
                agreementPrivate: phone.agreement, peerPublic: hubAgreement, linkNonce: nonce,
                hubID: hubID, deviceID: phone.deviceID, epoch: epoch, direction: .phoneToHub)
            let envelope = try EnvelopeSealer.sealSymmetric(
                InnerFrame(kind: plain.kind, id: plain.recordName, payload: plain.payload), envelopeClass: .relayToHub,
                key: key, hubID: hubID, senderID: phone.deviceID, epoch: epoch, seq: UInt64(epoch) * 100,
                context: EnvelopeContext(zone: .relay, wireName: wire), signer: nil)
            return (CloudRecord(recordName: wire, zone: .relay, kind: WireKind.envelope, modifiedAt: now, payload: envelope),
                    plain.recordName)
        }
        let transport = StubHubTransport()
        let processor = RelayProcessor(
            transport: MobileHubStorage.sealing(transport, keyring: keyring, sidecar: sidecar), sidecar: sidecar,
            dispatcher: MobileHubCommandDispatcher(), hubID: try sidecar.ensureHubID())

        // Control: while linked, C's probe is echoed.
        let linked = try probe("linked", epoch: 1)
        try await transport.save([linked.wire])
        _ = try await processor.processOnce()
        XCTAssertEqual(transport.saved.count, 2, "the probe and its echo")
        XCTAssertEqual(try sidecar.relayPhase(linked.plain), .done)
        XCTAssertNotNil(try sidecar.relaySeen(wireName: linked.wire.recordName, senderID: phoneC))

        try await center.remove(deviceID: phoneC)
        XCTAssertNil(try sidecar.relaySeen(wireName: linked.wire.recordName, senderID: phoneC))
        let previous = try probe("previous", epoch: 1)
        let current = try probe("current", epoch: 2)
        try await transport.save([previous.wire, current.wire])
        _ = try await processor.processOnce()

        XCTAssertEqual(transport.saved.count, 4, "no echo for either record")
        XCTAssertNil(try sidecar.relayPhase(previous.plain))
        XCTAssertNil(try sidecar.relayPhase(current.plain))
    }

    /// Final review (Kit I2, Desktop I-1, Phone I-2): a phone re-linked through a new code without Remove (a
    /// reinstall, or a seq floor lost across wipes) restarts its seqs at 1 under the same epoch. The re-link clears
    /// its rollback marks and `last_seq`, so its fixed-name records (its `device` record, a held recording
    /// re-sealed under the same upload id) are processed again, not refused as `.older`.
    func testARelinkWithoutRemoveForgetsThePhonesRollbackMarks() async throws {
        let firstCode = try await center.issueCode()
        try await link(try hello(identityC, nonce: firstCode.nonce))
        let hubID = try WireBytes.hubUUID(try sidecar.ensureHubID())
        let secure = hubSecure()
        let phone = identityC
        let hubAgreement = keyring.agreementPublicKey
        /// `plain` sealed by phone C under the link nonce `nonce` at epoch 1, `seq`.
        func seal(_ plain: CloudRecord, nonce: String, seq: UInt64) throws -> CloudRecord {
            let wire = try secure.wireName(plain: plain.recordName, zone: .relay)
            let key = try KeyDerivation.relayKey(
                agreementPrivate: phone.agreement, peerPublic: hubAgreement,
                linkNonce: try XCTUnwrap(WireBytes.fromBase64URL(nonce)),
                hubID: hubID, deviceID: phone.deviceID, epoch: 1, direction: .phoneToHub)
            let envelope = try EnvelopeSealer.sealSymmetric(
                InnerFrame(kind: plain.kind, id: plain.recordName, asset: plain.asset, payload: plain.payload),
                envelopeClass: .relayToHub, key: key, hubID: hubID, senderID: phone.deviceID, epoch: 1, seq: seq,
                context: EnvelopeContext(zone: .relay, wireName: wire), signer: nil)
            return CloudRecord(
                recordName: wire, zone: .relay, kind: WireKind.envelope, modifiedAt: plain.modifiedAt, payload: envelope,
                assetFileURL: plain.assetFileURL)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let upload = RecordingUploadPayload(
            id: "R-relink", startedAt: clock.now.addingTimeInterval(-600), endedAt: clock.now.addingTimeInterval(-300),
            durationSec: 300, titleHint: "Acme standup", sampleFormat: "aac-64k-mono", eventID: nil, deviceID: phoneC)
        /// The held recording as the phone seals it: the same upload id, a freshly sealed asset.
        func uploadRecord(nonce: String, seq: UInt64) throws -> CloudRecord {
            let plainAudio = dir.appendingPathComponent("plain-\(UUID().uuidString)")
            try Data(repeating: 0xCD, count: 128).write(to: plainAudio)
            let sealedAudio = dir.appendingPathComponent("sealed-\(UUID().uuidString)")
            let descriptor = try ChunkedAssetCipher.encryptFile(at: plainAudio, to: sealedAudio)
            let plain = try CloudRecordFactory.record(for: upload, modifiedAt: clock.now, assetFileURL: sealedAudio)
            return try seal(
                CloudRecord(
                    recordName: plain.recordName, zone: plain.zone, kind: plain.kind, modifiedAt: plain.modifiedAt,
                    payload: plain.payload, assetFileURL: sealedAudio, asset: descriptor),
                nonce: nonce, seq: seq)
        }
        let transport = StubHubTransport()
        let center = try XCTUnwrap(self.center)
        let uploads = RelayProcessor.RecordingUploads { _, _ in }
        let processor = RelayProcessor(
            transport: MobileHubStorage.sealing(transport, keyring: keyring, sidecar: sidecar), sidecar: sidecar,
            dispatcher: MobileHubCommandDispatcher(), hubID: try sidecar.ensureHubID(),
            recordingUploads: uploads,
            deviceRecords: .init { try await center.handleDevice($0) })
        let uploadName = upload.recordName
        let uploadWire = try secure.wireName(plain: uploadName, zone: .relay)
        func echoCount() -> Int { transport.saved.filter { $0.record.recordName == uploadWire }.count }

        // The first install: high seqs, the recording ingested and echoed, start-sessions turned off.
        try await transport.save([
            try seal(try deviceRecord(phoneC, nonce: nil, startSessions: false), nonce: firstCode.nonce, seq: 5_000),
            try uploadRecord(nonce: firstCode.nonce, seq: 5_001)
        ])
        _ = try await processor.processOnce()
        await center.closeAfterLink?.value
        XCTAssertEqual(try grants()[phoneC]?.startSessionsAllowed, false)
        XCTAssertEqual(try sidecar.relayOutcome(uploadName), RecordingUploadStatus.received.rawValue)
        XCTAssertEqual(try sidecar.deviceLastSeq(phoneC), 5_001)
        let echoesBefore = echoCount()

        // Reinstalled: the same identity scans a new code and the owner clicks Link again, with no Remove.
        clock.advance(30)
        let secondCode = try await center.issueCode()
        try await link(try hello(identityC, nonce: secondCode.nonce))
        XCTAssertNil(try sidecar.deviceLastSeq(phoneC), "the re-link resets the seq high-water mark")
        XCTAssertNil(try sidecar.relaySeen(wireName: uploadWire, senderID: phoneC), "and forgets the rollback marks")

        // Its seqs restart at 1, under the same epoch.
        try await transport.save([
            try seal(try deviceRecord(phoneC, nonce: nil, startSessions: true), nonce: secondCode.nonce, seq: 1),
            try uploadRecord(nonce: secondCode.nonce, seq: 2)
        ])
        _ = try await processor.processOnce()
        await center.closeAfterLink?.value

        XCTAssertEqual(try grants()[phoneC]?.startSessionsAllowed, true, "the device record is applied")
        XCTAssertGreaterThan(echoCount(), echoesBefore + 1, "the re-sealed recording is answered received again")
        XCTAssertEqual(try sidecar.relayOutcome(uploadName), RecordingUploadStatus.received.rawValue)
    }

    // MARK: - Closing the link

    func testTheLinkClosesAtUseRemovingAnUnboundParticipantAndKeepingTheBoundOne() async throws {
        let code = try await center.issueCode()
        XCTAssertTrue(shares.isLinkOpen, "open while the QR is on screen")
        shares.join("_colleague-a")
        shares.join("_stranger")

        try await link(try hello(identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"))
        await settleSweep()

        XCTAssertFalse(shares.isLinkOpen)
        for zone in [CloudZoneID.data, .relay] {
            XCTAssertEqual(shares.participantNames(in: zone), ["_colleague-a"], zone.rawValue)
        }
        XCTAssertEqual(sharing, [.available])
    }

    func testTheLinkClosesAt600Seconds() async throws {
        _ = try await center.issueCode()
        shares.join("_stranger")

        clock.advance(599)
        await center.closeLinkIfExpired()
        XCTAssertTrue(shares.isLinkOpen)
        XCTAssertNotNil(center.openCode)

        clock.advance(1)
        await center.closeLinkIfExpired()
        await settleSweep()
        XCTAssertFalse(shares.isLinkOpen)
        XCTAssertEqual(center.lastCloseReason, .expired)
        XCTAssertNil(center.openCode)
        XCTAssertTrue(shares.participantNames(in: .relay).isEmpty)
    }

    func testTheExpiryTimerClosesTheLinkAfterTheCodesLifetime() async throws {
        let clock = try XCTUnwrap(self.clock)
        let slept = DurationBox()
        center = try makeCenter { duration in
            // The close's zero grace is not the code's lifetime.
            if duration > .zero { slept.set(duration) }
            clock.advance(TimeInterval(duration.components.seconds))
        }

        _ = try await center.issueCode()

        await awaitHubCondition("the timer closes the link") { !self.shares.isLinkOpen }
        XCTAssertEqual(slept.value, .seconds(600))
        XCTAssertEqual(center.lastCloseReason, .expired)
        XCTAssertNil(center.openCode)
    }

    func testTheLinkClosesWhenTheSheetCloses() async throws {
        _ = try await center.issueCode()
        shares.join("_stranger")

        await center.closeLink(reason: .sheetClosed)
        await settleSweep()

        XCTAssertFalse(shares.isLinkOpen)
        XCTAssertTrue(shares.participantNames(in: .data).isEmpty)
        XCTAssertNil(center.openCode)
    }

    func testALinkLeftOpenByAnEarlierRunIsClosedAtTheNextBuild() async throws {
        _ = try await center.issueCode()
        let next = try makeCenter()

        await next.closeLink(reason: .restart)

        XCTAssertFalse(shares.isLinkOpen)
        shares.clearCalls()
        await next.closeLink(reason: .restart)
        XCTAssertTrue(shares.calls.isEmpty, "a closed link needs no share call")
    }

    // MARK: - Account

    func testNoAccountOrRestrictedRefusesTheCodeAndCreatesNoShare() async throws {
        for account in [CloudAvailability.noAccount, .restricted] {
            shares.setAccount(account)
            do {
                _ = try await center.issueCode()
                XCTFail("\(account) must refuse")
            } catch let error as MobileLinkError {
                XCTAssertEqual(error, .account(account))
            }
            let availability = await center.accountAvailability()
            XCTAssertEqual(availability, account)
        }
        XCTAssertEqual(shares.created, 0)
        XCTAssertEqual(Set(shares.calls), ["accountStatus"])
        XCTAssertTrue(try sidecar.linkCodes().isEmpty)
        XCTAssertNil(center.openCode)
    }

    // MARK: - Hub zones deleted (multi-hub spec §3.3)

    func testHubZonesDeletedForgetsCodesAndPhonesAndTheNextCodeMakesNewShares() async throws {
        let first = try await center.issueCode()
        try await link(try hello(identityA, nonce: first.nonce))
        shares.dropAll()

        try center.hubZonesDeleted()

        XCTAssertNil(center.openCode)
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        XCTAssertEqual(sharing.last, HubSharing.none)
        let next = try await center.issueCode()
        XCTAssertEqual(shares.created, 4, "new shares")
        XCTAssertNotEqual(next.dataShare, first.dataShare)
        XCTAssertNotEqual(next.relayShare, first.relayShare)
    }

    /// Final review m2: phones that could not be forgotten are reported, so
    /// the hub keeps its zone delete pending; the rest is still done.
    func testHubZonesDeletedThrowsWhenThePhonesCannotBeForgotten() async throws {
        let disk = try HubSyncState.onDiskPerHub()
        defer { try? FileManager.default.removeItem(at: disk.dir) }
        sidecar = disk.state
        center = try makeCenter()
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        _ = try await center.issueCode()
        try await disk.raw.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_forget BEFORE DELETE ON devices BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }

        XCTAssertThrowsError(try center.hubZonesDeleted())

        XCTAssertNil(center.openCode, "the open code is still forgotten")
        XCTAssertEqual(sharing.last, HubSharing.none)
        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA], "the phone row stayed")
    }

    func testTheCloudKitShareServiceAddressesTheHubsOwnZones() {
        let service = CloudKitShareService(hubID: "hub-acme") { false }
        XCTAssertEqual(service.shareID(.data).zoneID.zoneName, "DataZone-hub-acme")
        XCTAssertEqual(service.shareID(.relay).zoneID.zoneName, "RelayZone-hub-acme")
        XCTAssertEqual(service.shareID(.relay).recordName, CKRecordNameZoneWideShare)
    }

    // MARK: - Pruning

    func testLinkCodesKeepTheFiftyNewestAfterSixtyIssues() async throws {
        var issued: [String] = []
        for _ in 0..<60 {
            issued.append(try await center.issueCode().nonce)
            clock.advance(1)
        }

        XCTAssertEqual(try sidecar.linkCodes().map(\.nonce), Array(issued.suffix(50).reversed()))
    }

    // MARK: - Names (review focus 4)

    func testTwoPhonesNamedIPhoneAreBothListedByLinkDate() async throws {
        let first = try await center.issueCode()
        try await link(try hello(identityA, nonce: first.nonce, name: "iPhone"))
        clock.advance(60)
        let second = try await center.issueCode()
        try await link(try hello(identityB, nonce: second.nonce, name: "iPhone"))

        XCTAssertEqual(center.devices.map(\.name), ["iPhone", "iPhone"])
        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA, phoneB])
        let dates = center.devices.map(\.linkedAt)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), 60)
    }

    func testASeventyEmojiNameIsClippedAtAGraphemeBoundary() async throws {
        let family = "👩‍👩‍👧‍👦"
        let code = try await center.issueCode()

        try await link(try hello(identityA, nonce: code.nonce, name: String(repeating: family, count: 70)))

        let name = try XCTUnwrap(center.devices.first?.name)
        XCTAssertEqual(name, String(repeating: family, count: 60))
        XCTAssertEqual(try grants()[phoneA]?.name, name)
    }

    // MARK: - Same Apple ID

    func testAPrivatePhoneLinksWithoutAnyShareWhenSharingFails() async throws {
        shares.setFailing(true)

        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))

        XCTAssertNil(code.dataShare)
        XCTAssertNil(code.relayShare)
        XCTAssertEqual(sharing, [.unavailable])
        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
        XCTAssertEqual(shares.calls, ["accountStatus", "ensureShares"], "no link opened, so none to close")
    }

    func testLinkingAPrivatePhoneMakesNoParticipantCall() async throws {
        let code = try await center.issueCode()
        shares.clearCalls()

        try await link(try hello(identityA, nonce: code.nonce))

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
        XCTAssertFalse(shares.calls.contains { $0.hasPrefix("participants") })
    }

    // MARK: - Grants (Settings → Mobile)

    func testAllowAndRevokeSetTheGrantsTheSessionHandlersRead() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        XCTAssertEqual(MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA), .specDefaults)
        clock.advance(10)

        try center.setTypingAllowed(true, deviceID: phoneA)
        try center.setStartSessionsAllowed(false, deviceID: phoneA)

        let device = try XCTUnwrap(center.devices.first)
        XCTAssertTrue(device.typingAllowed)
        XCTAssertFalse(device.startSessionsAllowed)
        XCTAssertEqual(device.decidedAt, clock.now)
        XCTAssertEqual(try grants()[phoneA]?.typingAllowed, true)
        XCTAssertEqual(try grants()[phoneA]?.decidedAt, clock.now)
        XCTAssertEqual(
            MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA),
            .init(typingAllowed: true, startSessionsAllowed: false)
        )
        XCTAssertEqual(MobileLinkCenter.sessionGrant(sidecar, deviceID: "phone-x"), .denied)
    }

    func testRemovingASharedPhoneRemovesItsParticipantFromBothShares() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        try await link(try hello(
            identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))

        try await center.remove(deviceID: phoneA)

        XCTAssertTrue(shares.participantNames(in: .data).isEmpty)
        XCTAssertTrue(shares.participantNames(in: .relay).isEmpty)
    }

    // MARK: - Review fixes (round 1)

    /// The timer's close must not cancel itself: the share calls of a
    /// close run by the expiry timer still land.
    func testTheExpiryTimersCloseIsNotCancelledByItself() async throws {
        let clock = try XCTUnwrap(self.clock)
        center = try makeCenter { duration in clock.advance(TimeInterval(duration.components.seconds)) }
        shares.setCancellationAware(true)
        _ = try await center.issueCode()
        shares.join("_stranger")

        await awaitHubCondition("the timer closes the link and sweeps") {
            !self.shares.isLinkOpen && self.shares.participantNames(in: .relay).isEmpty
        }
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "0")
    }

    /// An unsigned dev build never reaches `CKContainer` (it would crash).
    func testWithoutTheEntitlementTheCloudKitShareServiceTouchesNoContainer() async throws {
        let service = CloudKitShareService(hubID: "hub-acme") { false }

        let account = await service.accountStatus()
        XCTAssertEqual(account, .unavailable("missing iCloud entitlement (unsigned dev build?)"))
        do {
            _ = try await service.ensureShares()
            XCTFail("ensureShares must refuse")
        } catch ShareServiceError.noEntitlement {}

        let center = MobileLinkCenter(
            sidecar: sidecar, shares: service, macName: "Mac acme", ownerUser: { "_owner-acme" },
            nudge: { _ in }
        )
        do {
            _ = try await center.issueCode()
            XCTFail("no QR without the entitlement")
        } catch let error as MobileLinkError {
            XCTAssertEqual(error, .account(account))
        }
    }

    /// A hung share call inside the relay pass is cut at the share timeout.
    func testAHungParticipantLookupDoesNotHoldTheRelayPass() async throws {
        center = try makeCenter(shareTimeout: .milliseconds(100))
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        shares.setHanging(["participants"])
        let started = Date()

        try await center.handleHello(try hello(
            identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "bounded, not the 5 s hang")
        XCTAssertTrue(center.devices.isEmpty, "an unverified phone is not linked")
        XCTAssertTrue(center.pendingLinks.isEmpty, "nor waits for the owner")
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice)
    }

    /// The close after a link runs outside the relay pass, bounded.
    func testAHungCloseAfterALinkDoesNotHoldTheRelayPass() async throws {
        center = try makeCenter(shareTimeout: .milliseconds(100))
        let code = try await center.issueCode()
        shares.setHanging(["setPublicLink"])
        let started = Date()

        try await center.handleHello(try hello(identityA, nonce: code.nonce))
        try await confirm(phoneA)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
        await center.closeAfterLink?.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the close is bounded too")
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "1", "the timed-out close stays pending")
    }

    /// A Remove whose participant removal fails is swept by the next close.
    func testAFailedParticipantRemovalIsSweptByTheNextClose() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        try await link(try hello(
            identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))
        shares.setFailing(["removeParticipants"])

        do {
            try await center.remove(deviceID: phoneA)
            XCTFail("the failed removal is reported")
        } catch {}
        XCTAssertTrue(center.devices.isEmpty, "the gate refuses the phone at once")
        XCTAssertEqual(shares.participantNames(in: .relay), ["_colleague-a"])

        shares.setFailing([])
        await center.closeLink(reason: .restart)

        XCTAssertTrue(shares.participantNames(in: .data).isEmpty)
        XCTAssertTrue(shares.participantNames(in: .relay).isEmpty)
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "0")
    }
    // MARK: - Final-review fixes

    /// Relays one probe from `deviceID` (creator `creator`) and returns its echo.
    private func relayedProbe(from deviceID: String, creator: String? = nil) async throws -> ActionRequestPayload? {
        let transport = StubHubTransport()
        let record = try probe(from: deviceID, creator: creator)
        try await transport.save([record])
        _ = try await RelayProcessor(
            transport: relaySide(transport), sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        ).processOnce()
        return try lastEcho(record, in: transport)
    }

    private func linkSharedPhone(_ identity: DeviceIdentityKeys? = nil, user: String = "_colleague-a") async throws {
        let identity = identity ?? identityA
        let code = try await center.issueCode()
        shares.join(user)
        try await link(try hello(identity, nonce: code.nonce, scope: .shared, user: user, creator: user))
        XCTAssertEqual(center.devices.map(\.deviceID), [identity.deviceID.uuidString])
    }

    /// #1: the phone's own unlink (`unlinked: true`, no nonce) removes it.
    func testAPhonesOwnUnlinkRemovesItAndItsLaterActionsFailDeviceNotLinked() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, unlinked: true))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertNil(try sidecar.linkedDevice(phoneA))
        // Task 14 (D9): its keybox reads revoked instead of leaving the zone.
        XCTAssertEqual(Array(try grants().keys), [phoneA])
        XCTAssertEqual(try grants()[phoneA]?.revoked, true)
        let echo = try await relayedProbe(from: phoneA)
        XCTAssertEqual(echo?.reason, .deviceNotLinked)
    }

    /// #1: in `shared` scope the phone has left the shares before the hub
    /// reads its unlink; the missing participant is no error.
    func testASharedPhonesUnlinkAfterItLeftTheSharesRemovesIt() async throws {
        try await linkSharedPhone(identityA)
        for zone in [CloudZoneID.data, .relay] {
            try await shares.removeParticipants(in: zone) { _ in true }
        }

        try await handleDevice(try deviceRecord(
            phoneA, nonce: nil, scope: .shared, user: "_colleague-a", creator: "_colleague-a", unlinked: true
        ))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(try grants()[phoneA]?.revoked, true, "Task 14 (D9): revoked, not gone")
        let echo = try await relayedProbe(from: phoneA, creator: "_colleague-a")
        XCTAssertEqual(echo?.reason, .deviceNotLinked)
    }

    /// #1: a share failure after the phone's unlink still removes it and is
    /// swept by the next close; it never fails the relay pass.
    func testASharedUnlinkWhoseParticipantRemovalFailsStillRemovesThePhone() async throws {
        try await linkSharedPhone()
        shares.setFailing(["removeParticipants"])

        try await handleDevice(try deviceRecord(
            phoneA, nonce: nil, scope: .shared, user: "_colleague-a", creator: "_colleague-a", unlinked: true
        ))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "1")
    }

    /// #1: an unlink another iCloud user wrote removes nothing.
    func testAForgedUnlinkInSharedScopeRemovesNothing() async throws {
        try await linkSharedPhone(identityA)
        shares.join("_stranger")

        try await handleDevice(try deviceRecord(
            phoneA, nonce: nil, scope: .shared, user: "_colleague-a", creator: "_stranger", unlinked: true
        ))
        try await handleDevice(try deviceRecord(
            phoneA, nonce: nil, scope: .shared, user: "_stranger", creator: "_stranger", unlinked: true
        ))

        XCTAssertEqual(center.devices.map(\.deviceID), [phoneA])
        XCTAssertEqual(try grants()[phoneA]?.linked, true)
        let echo = try await relayedProbe(from: phoneA, creator: "_colleague-a")
        XCTAssertEqual(echo?.status, .applied)
    }

    /// #1: once unlinked, a later stale code of the same Mac is refused with
    /// its reason, not swallowed as "already linked".
    func testAPhoneThatUnlinkedGetsTheRefusalOfAnExpiredCodeLater() async throws {
        let first = try await center.issueCode()
        try await link(try hello(identityA, nonce: first.nonce))
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, unlinked: true))

        let second = try await center.issueCode()
        clock.advance(601)
        try await handle(try hello(identityA, nonce: second.nonce))

        XCTAssertEqual(try grants()[phoneA]?.linkRefused, .expiredCode)
    }

    /// #3: the phone's start-sessions toggle (a nonce-less rewrite) reaches
    /// the grant; its typing request is stored (PROJ-16) and is never a
    /// grant.
    func testALinkedPhonesStartSessionsToggleIsMirroredAndATypingRequestIsStoredNotGranted() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        clock.advance(10)

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, typingRequested: true, startSessions: false))

        let device = try XCTUnwrap(center.devices.first)
        XCTAssertFalse(device.startSessionsAllowed)
        XCTAssertTrue(device.typingRequested, "the request is kept for Settings → Mobile")
        XCTAssertFalse(device.typingAllowed, "a typing request is never a grant")
        XCTAssertEqual(device.decidedAt, clock.now)
        let grant = try XCTUnwrap(try grants()[phoneA])
        XCTAssertFalse(grant.startSessionsAllowed)
        XCTAssertFalse(grant.typingAllowed)
        XCTAssertEqual(MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA).startSessionsAllowed, false)

        clock.advance(10)
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, startSessions: true))
        XCTAssertEqual(center.devices.first?.startSessionsAllowed, true)
        XCTAssertEqual(center.devices.first?.typingRequested, false)
        XCTAssertEqual(center.devices.first?.decidedAt, clock.now)
    }

    /// Spec §10 (OD-2): a phone turning typing on asks the owner once; the
    /// same request again does not ask twice, and an allowed phone is not
    /// asked. E2E: the phone links through a confirmed hello; its later
    /// toggles are its own sealed `device` rewrites.
    func testATypingRequestAsksTheOwnerOnce() async throws {
        var asked: [String] = []
        center.onTypingRequested = { asked.append($0.name) }
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce, name: "Colleague A's iPhone"))

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, name: "Colleague A's iPhone", typingRequested: true))
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, name: "Colleague A's iPhone", typingRequested: true))

        XCTAssertEqual(asked, ["Colleague A's iPhone"])
        try center.setTypingAllowed(true, deviceID: phoneA)
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, typingRequested: false))
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, typingRequested: true))
        XCTAssertEqual(asked.count, 2, "turned off and on again, it asks again")
    }

    /// A phone linking with typing already on asks at once: the hello's
    /// request rides in the waiting request and the owner's Link stores it.
    func testAPhoneLinkingWithTypingOnAsks() async throws {
        var asked: [String] = []
        center.onTypingRequested = { asked.append($0.deviceID) }
        let code = try await center.issueCode()

        try await handle(try hello(identityA, nonce: code.nonce, typingRequested: true))
        XCTAssertTrue(asked.isEmpty, "nothing is asked before the owner links the phone")
        try await confirm(phoneA)
        await center.closeAfterLink?.value

        XCTAssertEqual(asked, [phoneA])
        XCTAssertEqual(center.devices.first?.typingRequested, true)
        XCTAssertEqual(center.devices.first?.typingAllowed, false, "a request is never a grant")
    }

    /// Spec §10: the phone's toggle off revokes the grant, and Revoke and
    /// Remove tell `onTypingRevoked` (the held lines fail, PROJ-16).
    func testThePhonesToggleOffRevokesAndRevokeAndRemoveAreReported() async throws {
        var revoked: [String] = []
        center.onTypingRevoked = { revoked.append($0) }
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce, typingRequested: true))
        try center.setTypingAllowed(true, deviceID: phoneA)

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, typingRequested: false))

        XCTAssertEqual(center.devices.first?.typingAllowed, false)
        XCTAssertEqual(MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA).typingAllowed, false)
        XCTAssertEqual(revoked, [phoneA])
        try await center.remove(deviceID: phoneA)
        XCTAssertEqual(revoked, [phoneA, phoneA])
    }

    /// A rewrite for another toggle (start sessions) with typing off keeps
    /// a grant the owner gave: only the request going from on to off
    /// revokes it.
    func testAnUnrelatedRewriteKeepsTheTypingGrant() async throws {
        var revoked: [String] = []
        center.onTypingRevoked = { revoked.append($0) }
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        try center.setTypingAllowed(true, deviceID: phoneA)

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, typingRequested: false, startSessions: false))

        XCTAssertEqual(center.devices.first?.typingAllowed, true)
        XCTAssertEqual(center.devices.first?.startSessionsAllowed, false)
        XCTAssertTrue(revoked.isEmpty)
    }

    /// #3: an unchanged choice stamps nothing new.
    func testAnUnchangedStartSessionsChoiceLeavesTheGrantAlone() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        nudges = []

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, startSessions: true))

        XCTAssertNil(center.devices.first?.decidedAt)
        XCTAssertTrue(nudges.isEmpty)
    }

    /// #3: a nonce-less record of a phone that is not linked changes nothing.
    func testAnUnlinkedDevicesNonceLessRecordChangesNothing() async throws {
        nudges = []

        try await handleDevice(try deviceRecord("phone-x", nonce: nil, startSessions: false))
        try await handleDevice(try deviceRecord("phone-x", nonce: nil, unlinked: true))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        XCTAssertTrue(try sidecar.linkRefusals().isEmpty)
        XCTAssertTrue(nudges.isEmpty)
    }

    /// #3: a start-sessions rewrite another iCloud user wrote is ignored.
    func testAForgedStartSessionsRewriteInSharedScopeIsIgnored() async throws {
        try await linkSharedPhone()

        try await handleDevice(try deviceRecord(
            phoneA, nonce: nil, scope: .shared, user: "_colleague-a", creator: "_stranger", startSessions: false
        ))

        XCTAssertEqual(center.devices.first?.startSessionsAllowed, true)
    }

    /// #5: two refusals at different times publish different payloads, so
    /// the phone sees the second one as an answer.
    func testTwoRefusalsAtDifferentTimesPublishDifferentPayloads() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        let scan = try hello(identityB, nonce: code.nonce)

        try await handle(scan)
        let first = try XCTUnwrap(try grantRecords().first { $0.id == phoneB })
        clock.advance(5)
        try await handle(scan)
        let second = try XCTUnwrap(try grantRecords().first { $0.id == phoneB })

        XCTAssertNotEqual(first.payload, second.payload)
        let grant = try RelayCoder.makeDecoder().decode(Keybox.self, from: second.payload).grant
        XCTAssertEqual(grant.linkRefused, .usedCode)
        XCTAssertEqual(grant.decidedAt, Date(timeIntervalSince1970: clock.now.timeIntervalSince1970.rounded(.down)))
    }

    // MARK: - Link tails (#65, #66)

    /// #65: after the iCloud account changed, the next QR names the new user.
    func testAnAccountChangeLooksTheOwnerUpAgainForTheNextCode() async throws {
        let owner = OwnerUserBox("_owner-acme")
        center = try makeCenter { owner.value }
        let first = try await center.issueCode()
        owner.set("_owner-new")
        let issued1 = try await center.issueCode()
        XCTAssertEqual(issued1.ownerUser, "_owner-acme", "cached while the account stays")

        center.accountChanged()
        let next = try await center.issueCode()

        XCTAssertEqual(first.ownerUser, "_owner-acme")
        XCTAssertEqual(next.ownerUser, "_owner-new")
    }

    /// #65: a lookup still running when the account changes may answer
    /// with the old user; it is not cached, and the code is refused.
    func testAnOwnerLookupRunningAcrossAnAccountChangeIsNotCached() async throws {
        let owner = OwnerUserBox("_owner-acme")
        let gate = SaveGate()
        center = try makeCenter {
            let answer = owner.value
            await gate.park()
            return answer
        }
        let issuing = Task { try await center.issueCode() }
        await fulfillment(of: [gate.arrived], timeout: 5)

        owner.set("_owner-new")
        center.accountChanged()
        gate.release()

        do {
            _ = try await issuing.value
            XCTFail("a code naming the old user is not shown")
        } catch {
            XCTAssertEqual(error as? MobileLinkError, .ownerUnknown)
        }
        let next = try await center.issueCode()
        XCTAssertEqual(next.ownerUser, "_owner-new")
    }

    /// #65: a new code waits for the account change's close, so that close
    /// never shuts the new code's link.
    func testANewCodeWaitsForTheAccountChangesClose() async throws {
        _ = try await center.issueCode()
        let gate = SaveGate()
        shares.gate("setPublicLink", on: gate)
        center.accountChanged()
        await fulfillment(of: [gate.arrived], timeout: 5)

        let issuing = Task { try await center.issueCode() }
        gate.release()
        let code = try await issuing.value

        XCTAssertEqual(center.openCode, code)
        XCTAssertTrue(shares.isLinkOpen)
    }

    /// #65: a code still being made when the account changes is closed, not shown.
    func testACodeBeingIssuedAcrossAnAccountChangeIsClosed() async throws {
        let gate = SaveGate()
        shares.gate("setPublicLink", on: gate)
        let issuing = Task { try await center.issueCode() }
        await fulfillment(of: [gate.arrived], timeout: 5)

        center.accountChanged()
        gate.release()

        do {
            _ = try await issuing.value
            XCTFail("the code is refused")
        } catch {
            XCTAssertEqual(error as? MobileLinkError, .accountChanged)
        }
        XCTAssertNil(center.openCode)
        XCTAssertFalse(shares.isLinkOpen)
        XCTAssertEqual(center.lastCloseReason, .accountChanged)
    }

    /// #65: a QR on screen names the old user, so an account change closes it.
    func testAnAccountChangeClosesTheOpenCodeAndItsLink() async throws {
        _ = try await center.issueCode()
        XCTAssertTrue(shares.isLinkOpen)

        center.accountChanged()

        await awaitHubCondition("the link closes") { !shares.isLinkOpen }
        XCTAssertNil(center.openCode)
        XCTAssertEqual(sharing.last, HubSharing.none, "the new account has no shares yet")
    }

    /// #66.3: a Remove that fails while a close is suspended keeps the sweep
    /// pending; the suspended close does not clear it.
    func testARemoveFailingDuringASuspendedCloseKeepsTheSweepPending() async throws {
        try await linkSharedPhone()
        _ = try await center.issueCode()
        let gate = SaveGate()
        shares.gate("setPublicLink", on: gate)
        let close = Task { await center.closeLink(reason: .sheetClosed) }
        await fulfillment(of: [gate.arrived], timeout: 5)

        shares.setFailing(["removeParticipants"])
        do {
            try await center.remove(deviceID: phoneA)
            XCTFail("the failed removal is reported")
        } catch {}
        shares.setFailing([])
        gate.release()
        await close.value

        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "1")
    }

    /// #66.3: when even the sweep mark cannot be written, the removal's own
    /// error is the one reported.
    func testARemoveWhoseSweepMarkFailsReportsTheRemovalError() async throws {
        let disk = try HubSyncState.onDiskPerHub()
        defer { try? FileManager.default.removeItem(at: disk.dir) }
        sidecar = disk.state
        center = try makeCenter()
        try await linkSharedPhone()
        await center.closeAfterLink?.value
        shares.setFailing(["removeParticipants"])
        try await disk.raw.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_mark BEFORE UPDATE ON hub_meta BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }

        do {
            try await center.remove(deviceID: phoneA)
            XCTFail("the failed removal is reported")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    /// #66.4: a code that could not be stored closes the link it opened.
    func testACodeThatCannotBeStoredClosesTheLinkItOpened() async throws {
        let disk = try HubSyncState.onDiskPerHub()
        defer { try? FileManager.default.removeItem(at: disk.dir) }
        sidecar = disk.state
        center = try makeCenter()
        try await disk.raw.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_code BEFORE INSERT ON link_codes BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }

        do {
            _ = try await center.issueCode()
            XCTFail("the store failure is reported")
        } catch {}

        XCTAssertFalse(shares.isLinkOpen)
        XCTAssertNil(center.openCode)
    }

    /// #7: New code retires the code it replaces.
    func testANewCodeRetiresThePreviousUnusedCode() async throws {
        let first = try await center.issueCode()
        let second = try await center.issueCode()

        try await handle(try hello(identityA, nonce: first.nonce))
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(try grants()[phoneA]?.linkRefused, .expiredCode)

        try await link(try hello(identityB, nonce: second.nonce))
        XCTAssertEqual(center.devices.map(\.deviceID), [phoneB])
    }

    // MARK: - Linked-phone gate (board #724)

    /// `hasLinkedDevice` reads the devices table: empty → false, a row →
    /// true; `hasLinkedPhone` follows it, and fails open (true) once the
    /// sidecar cannot be read, then follows it again once it can.
    func testTheLinkedPhoneGateFollowsTheSidecarAndFailsOpen() throws {
        let (state, raw, dir) = try HubSyncState.onDiskPerHub()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(try state.hasLinkedDevice())
        XCTAssertFalse(MobileLinkCenter.hasLinkedPhone(state))

        try raw.write { db in
            try db.execute(sql: """
                INSERT INTO devices (device_id, name, scope, user_record_name, linked_at)
                VALUES ('device-a', 'Phone A', 'private', '_user-a', 0)
                """)
        }
        XCTAssertTrue(try state.hasLinkedDevice())
        XCTAssertTrue(MobileLinkCenter.hasLinkedPhone(state))

        try raw.write { db in try db.execute(sql: "DELETE FROM devices") }
        XCTAssertFalse(MobileLinkCenter.hasLinkedPhone(state))
        try raw.write { db in try db.execute(sql: "ALTER TABLE devices RENAME TO devices_gone") }
        XCTAssertThrowsError(try state.hasLinkedDevice())
        XCTAssertTrue(MobileLinkCenter.hasLinkedPhone(state), "an unreadable sidecar counts as linked")
        XCTAssertTrue(MobileLinkCenter.hasLinkedPhone(state), "still failing open")

        try raw.write { db in try db.execute(sql: "ALTER TABLE devices_gone RENAME TO devices") }
        XCTAssertFalse(MobileLinkCenter.hasLinkedPhone(state), "readable again: no phone")
    }
}

/// The iCloud user the lookup returns; the test switches it.
final class OwnerUserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(_ value: String) {
        stored = value
    }

    var value: String { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}

/// The last `Duration` the expiry timer asked to sleep.
final class DurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Duration?

    var value: Duration? { lock.withLock { stored } }
    func set(_ duration: Duration) { lock.withLock { stored = duration } }
}
