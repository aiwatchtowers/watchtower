import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerE2ETesting
import WatchtowerSync

/// Pairing code v2 (final review I-1, ask #97): the hub's confirm nonce drawn after the hello, the attempt cap per
/// code, and display names cleaned. `MobileLinkCenterTests` holds the rest of linking.
@MainActor
final class MobileLinkPairingCodeTests: XCTestCase {
    private var sidecar: HubSyncState!
    private var clock: LinkTestClock!
    private var keyring: HubKeyring!
    private var center: MobileLinkCenter!

    private let identityA = TestE2E.deviceIdentity
    private let identityB = TestE2E.strangerIdentity
    private let identityC = TestHello.newPhone()
    private let identityD = TestHello.newPhone()
    private let phoneA = TestE2E.deviceID.uuidString
    private let phoneB = TestE2E.strangerDeviceID.uuidString
    private var phoneC: String { identityC.deviceID.uuidString }

    override func setUp() async throws {
        sidecar = try HubSyncState.inMemory()
        clock = LinkTestClock()
        center = try makeCenter()
    }

    override func tearDown() async throws {
        await center?.closeAfterLink?.value
        await center?.closeLink(reason: .sheetClosed)
        center = nil
        keyring = nil
        sidecar = nil
        clock = nil
    }

    /// The expiry timer parks until cancelled; `confirmNonce` replaces the random source.
    private func makeCenter(confirmNonce: @escaping @Sendable () -> Data = MobileLinkCenter.randomConfirmNonce) throws
        -> MobileLinkCenter {
        let clock = try XCTUnwrap(self.clock)
        keyring = try sidecar.testKeyring { clock.now }
        return MobileLinkCenter(
            sidecar: sidecar, shares: FakeShareService(), macName: "Mac acme", ownerUser: { "_owner-acme" },
            keyring: keyring, nudge: { _ in }, now: { clock.now },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }, confirmNonce: confirmNonce)
    }

    /// `phone`'s hello for the code `nonce` (private scope, the owner's user), as the relay hands it over.
    private func hello(_ phone: DeviceIdentityKeys, nonce: String, name: String = "iPhone") throws -> CloudRecord {
        let device = DevicePayload(
            deviceID: phone.deviceID.uuidString, name: name, model: "iPhone18,1", appVersion: "0.0.0-test",
            scope: .private, userRecordName: "_owner-acme", linkNonce: nonce, unlinked: nil, typingRequested: false,
            startSessions: true, updatedAt: clock.now)
        return try TestHello.record(device, from: phone, to: keyring, nonce: nonce)
    }

    private func handle(_ record: CloudRecord) async throws {
        try await center.handleHello(record)
    }

    /// `phone`'s keybox as the phone reads it (sealed by the hub, opened with its key, signature checked).
    private func openedKeybox(_ phone: DeviceIdentityKeys) async throws -> Keybox {
        let keybox = try await TestHello.keybox(for: phone, in: grantRecords(), keyring: keyring)
        return try XCTUnwrap(keybox, "no keybox for \(phone.deviceID)")
    }

    private func grantRecords() throws -> [SliceRecord] {
        let clock = try XCTUnwrap(self.clock)
        let slice = DeviceGrantSlice(sidecar: sidecar, hubID: try sidecar.ensureHubID(), keyring: keyring) { clock.now }
        // The slice reads the sidecar; the main-DB handle is unused.
        return try DatabaseQueue().read { try slice.records($0) }
    }

    /// The code `phone` shows once its waiting keybox brought the nonce.
    private func phoneSAS(_ phone: DeviceIdentityKeys, scanned code: LinkPayload) async throws -> String {
        let keybox = try await openedKeybox(phone)
        let confirmNonce = try XCTUnwrap(keybox.grant.confirmNonce.flatMap(WireBytes.fromBase64URL), "no confirm nonce")
        return try TestHello.sas(phone, scanned: code, confirmNonce: confirmNonce)
    }

    /// The grind of final review I-1: an attacker who photographed the QR and sees the owner's phone's code picks
    /// keys offline whose code matches it. Under SAS v2 the code also hashes a nonce the hub draws only after it
    /// accepted the hello (so after the keys are committed): keys ground for any guessed nonce do not carry the
    /// code to the Mac.
    func testGroundKeysDoNotReproduceTheOwnersCodeBecauseTheHubDrawsTheNonceAfterTheHello() async throws {
        let draws = NonceDraws()
        center = try makeCenter { draws.next() }
        let code = try await center.issueCode()
        try await handle(try hello(identityA, nonce: code.nonce, name: "Owner iPhone"))
        XCTAssertEqual(draws.count, 1, "one nonce, drawn for the accepted hello")
        let ownerCode = try await phoneSAS(identityA, scanned: code)
        XCTAssertEqual(center.pendingLinks.first { $0.id == phoneA }?.sas, ownerCode)

        // Offline: every input but the hub's nonce is in the QR; the attacker grinds keys against a guessed nonce.
        let guessed = Data(repeating: 0, count: KeyDerivation.confirmNonceLength)
        var ground: DeviceIdentityKeys?
        for _ in 0 ..< 200_000 {
            let candidate = TestHello.newPhone()
            if try TestHello.sas(candidate, scanned: code, confirmNonce: guessed) == ownerCode {
                ground = candidate
                break
            }
        }
        let attacker = try XCTUnwrap(ground, "the grind found keys for the guessed nonce")

        try await handle(try hello(attacker, nonce: code.nonce, name: "Owner iPhone"))

        XCTAssertEqual(draws.count, 2, "a fresh nonce for the second hello, drawn after it")
        let shown = try XCTUnwrap(center.pendingLinks.first { $0.id == attacker.deviceID.uuidString }?.sas)
        let attackerBox = try await openedKeybox(attacker)
        let drawn = try XCTUnwrap(attackerBox.grant.confirmNonce.flatMap(WireBytes.fromBase64URL))
        XCTAssertNotEqual(drawn, guessed)
        XCTAssertEqual(shown, try TestHello.sas(attacker, scanned: code, confirmNonce: drawn), "the Mac's code uses the drawn nonce")
        try XCTSkipIf(shown == ownerCode, "the drawn nonce collided by chance (1 in 10 000)")
        XCTAssertNotEqual(shown, ownerCode, "the ground keys do not show the owner's code")
    }

    /// The waiting keybox carries the nonce (sealed to the phone, signed by the hub); a hello re-sent unchanged keeps
    /// its nonce and its code, a hello under another code gets a new one.
    func testTheWaitingKeyboxCarriesTheConfirmNonceAndAResentHelloKeepsIt() async throws {
        let code = try await center.issueCode()
        let scan = try hello(identityA, nonce: code.nonce)
        try await handle(scan)
        let firstBox = try await openedKeybox(identityA)
        let first = try XCTUnwrap(firstBox.grant.confirmNonce)
        XCTAssertEqual(WireBytes.fromBase64URL(first)?.count, KeyDerivation.confirmNonceLength)
        let shown = try XCTUnwrap(center.pendingLinks.first?.sas)

        try await handle(scan)

        let resent = try await openedKeybox(identityA)
        XCTAssertEqual(resent.grant.confirmNonce, first)
        XCTAssertEqual(center.pendingLinks.first?.sas, shown)

        let next = try await center.issueCode()
        try await handle(try hello(identityA, nonce: next.nonce))
        let replaced = try await openedKeybox(identityA)
        XCTAssertNotEqual(replaced.grant.confirmNonce, first)
        let replacedCode = try await phoneSAS(identityA, scanned: next)
        XCTAssertEqual(center.pendingLinks.first?.sas, replacedCode)
    }

    /// The attempt cap: at most `maxPendingPerCode` phones wait on one code. A further hello for it is refused
    /// (`too_many_requests`, sealed to its key) and never shown; a waiting phone re-sending its hello is not a new
    /// attempt.
    func testAFourthHelloForOneCodeIsRefusedAndNotShown() async throws {
        XCTAssertEqual(MobileLinkCenter.maxPendingPerCode, 3)
        let code = try await center.issueCode()
        for phone in [identityA, identityB, identityC] {
            try await handle(try hello(phone, nonce: code.nonce))
        }
        XCTAssertEqual(Set(center.pendingLinks.map(\.id)), [phoneA, phoneB, phoneC])

        try await handle(try hello(identityD, nonce: code.nonce))

        XCTAssertEqual(Set(center.pendingLinks.map(\.id)), [phoneA, phoneB, phoneC], "the fourth is not shown")
        let refused = try await openedKeybox(identityD)
        XCTAssertEqual(refused.grant.linkRefused, .tooManyRequests)
        XCTAssertNil(refused.grant.confirmNonce)
        XCTAssertNil(refused.keys)

        try await handle(try hello(identityA, nonce: code.nonce))
        XCTAssertEqual(Set(center.pendingLinks.map(\.id)), [phoneA, phoneB, phoneC], "a re-sent hello is no new attempt")
        let stillWaiting = try await openedKeybox(identityA)
        XCTAssertEqual(stillWaiting.grant.awaitingConfirmation, true)

        // The owner's Refuse frees a place.
        try await center.refuseLink(deviceID: phoneB)
        let identityE = TestHello.newPhone()
        try await handle(try hello(identityE, nonce: code.nonce))
        XCTAssertEqual(Set(center.pendingLinks.map(\.id)), [phoneA, phoneC, identityE.deviceID.uuidString])
    }

    /// Display names: control and format characters (newlines, bidi overrides, zero-width marks) never reach the
    /// sheet; the 60-grapheme clip stays.
    func testAHellosNameIsSanitisedForDisplay() async throws {
        let code = try await center.issueCode()
        try await handle(try hello(identityA, nonce: code.nonce, name: "Owner\u{202E}s\niPhone\u{200B}\u{0007}"))
        try await handle(try hello(identityB, nonce: code.nonce, name: String(repeating: "x", count: 80)))
        try await handle(try hello(identityC, nonce: code.nonce, name: " \n\u{202E} "))

        let names = Dictionary(uniqueKeysWithValues: center.pendingLinks.map { ($0.id, $0.name) })
        XCTAssertEqual(names[phoneA], "Owners iPhone")
        XCTAssertEqual(names[phoneB], String(repeating: "x", count: DevicePayload.maxNameLength))
        XCTAssertEqual(names[phoneC], "iPhone", "an empty name reads iPhone")
        XCTAssertEqual(MobileLinkCenter.displayName("Family 👨‍👩‍👧 phone"), "Family 👨‍👩‍👧 phone", "emoji joiners stay")
    }
}

/// The hub's confirm nonces in order (1, 2, …, repeated to 32 bytes), and how many were drawn.
final class NonceDraws: @unchecked Sendable {
    private let lock = NSLock()
    private var drawn = 0

    var count: Int { lock.withLock { drawn } }

    func next() -> Data {
        lock.withLock {
            drawn += 1
            return Data(repeating: UInt8(truncatingIfNeeded: drawn), count: KeyDerivation.confirmNonceLength)
        }
    }
}
