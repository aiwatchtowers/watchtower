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
        center?.cancelSweepRetry()
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
        let codeNonce = try XCTUnwrap(WireBytes.fromBase64URL(code.nonce))
        XCTAssertEqual(firstBox.grant.linkCodeTag, KeyDerivation.linkCodeTag(linkNonce: codeNonce), "names its link code")
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
        XCTAssertEqual(
            replaced.grant.linkCodeTag, KeyDerivation.linkCodeTag(linkNonce: try XCTUnwrap(WireBytes.fromBase64URL(next.nonce))))
        let replacedCode = try await phoneSAS(identityA, scanned: next)
        XCTAssertEqual(center.pendingLinks.first?.sas, replacedCode)
    }

    /// The attempt cap: one code hands out at most `maxNoncesPerCode` confirm nonces. A further hello for it is
    /// refused (`too_many_requests`, sealed to its key) and never shown; a waiting phone re-sending its hello is not
    /// a new attempt; the owner's Refuse gives no try back (only a new code does).
    func testAFourthHelloForOneCodeIsRefusedAndNotShown() async throws {
        XCTAssertEqual(MobileLinkCenter.maxNoncesPerCode, 3)
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

        // The owner's Refuse gives no try back; a new code does.
        try await center.refuseLink(deviceID: phoneB)
        let identityE = TestHello.newPhone()
        try await handle(try hello(identityE, nonce: code.nonce))
        XCTAssertEqual(Set(center.pendingLinks.map(\.id)), [phoneA, phoneC])
        let spent = try await openedKeybox(identityE)
        XCTAssertEqual(spent.grant.linkRefused, .tooManyRequests)

        let next = try await center.issueCode()
        try await handle(try hello(identityD, nonce: next.nonce))
        XCTAssertTrue(center.pendingLinks.contains { $0.id == identityD.deviceID.uuidString }, "a new code, new tries")
    }

    /// Refusals are bounded (target 168): a hello can carry a fresh key at will, so one code publishes at most
    /// `maxRefusalsPerCode` refusals beyond its nonces; later fresh phones go unanswered. A phone already refused is
    /// rewritten in place, and the total stays under `maxLinkRefusals`.
    func testRefusalsPerCodeAreCapped() async throws {
        let code = try await center.issueCode()
        for phone in [identityA, identityB, identityC] {
            try await handle(try hello(phone, nonce: code.nonce))
        }
        let flood = (0 ..< MobileLinkCenter.maxRefusalsPerCode + 2).map { _ in TestHello.newPhone() }
        for phone in flood {
            try await handle(try hello(phone, nonce: code.nonce))
        }

        XCTAssertEqual(try sidecar.linkRefusals().count, MobileLinkCenter.maxRefusalsPerCode)
        let answered = try await openedKeybox(flood[0])
        XCTAssertEqual(answered.grant.linkRefused, .tooManyRequests)
        let unanswered = try await TestHello.keybox(for: try XCTUnwrap(flood.last), in: grantRecords(), keyring: keyring)
        XCTAssertNil(unanswered, "past the cap a hello gets no keybox")

        // An already-refused phone is answered again in place: no new row.
        try await handle(try hello(flood[0], nonce: code.nonce))
        XCTAssertEqual(try sidecar.linkRefusals().count, MobileLinkCenter.maxRefusalsPerCode)
    }

    func testRefusalsAreCappedInTotal() throws {
        let max = 3
        try sidecar.addLinkCode(nonce: "code-1", issuedAt: clock.now, exp: clock.now, keeping: 50)
        func refusal(_ id: String) -> HubSyncState.LinkRefusalRecord {
            HubSyncState.LinkRefusalRecord(
                deviceID: id, name: "iPhone", scope: .private, reason: .expiredCode, at: clock.now, agreementKey: nil)
        }
        for index in 0 ..< max {
            XCTAssertTrue(try sidecar.saveBoundedLinkRefusal(
                refusal("phone-\(index)"), codeNonce: "code-1", maxAnswersPerCode: 100, maxRefusals: max))
        }
        XCTAssertFalse(try sidecar.saveBoundedLinkRefusal(
            refusal("phone-new"), codeNonce: "code-1", maxAnswersPerCode: 100, maxRefusals: max))
        XCTAssertTrue(try sidecar.saveBoundedLinkRefusal(
            refusal("phone-0"), codeNonce: "code-1", maxAnswersPerCode: 100, maxRefusals: max), "a known phone is rewritten")
        XCTAssertEqual(try sidecar.linkRefusals().count, max)
    }

    /// A code pruned while its hello was being checked has no counter: its phone is still refused (it hears why
    /// instead of timing out), within the total cap.
    func testARefusalForACodeNoLongerKeptStillAnswers() throws {
        func refusal(_ id: String) -> HubSyncState.LinkRefusalRecord {
            HubSyncState.LinkRefusalRecord(
                deviceID: id, name: "iPhone", scope: .private, reason: .expiredCode, at: clock.now, agreementKey: nil)
        }
        XCTAssertTrue(try sidecar.saveBoundedLinkRefusal(
            refusal("phone-1"), codeNonce: "pruned-code", maxAnswersPerCode: 1, maxRefusals: 2))
        XCTAssertTrue(try sidecar.saveBoundedLinkRefusal(
            refusal("phone-2"), codeNonce: "pruned-code", maxAnswersPerCode: 1, maxRefusals: 2))
        XCTAssertFalse(try sidecar.saveBoundedLinkRefusal(
            refusal("phone-3"), codeNonce: "pruned-code", maxAnswersPerCode: 1, maxRefusals: 2), "the total cap holds")
    }

    /// Review I-1: the device id hashes only the signing key, so one device can re-roll its agreement key under one
    /// code. Each re-roll draws one of the code's nonces; the 4th gets none: the request stays the 3rd one, the
    /// keybox stays sealed to the 3rd key (the 4th cannot open it), and no fresh code is shown.
    func testReRollingTheAgreementKeyUnderOneCodeSpendsTheCodesNonces() async throws {
        let draws = NonceDraws()
        center = try makeCenter { draws.next() }
        let code = try await center.issueCode()
        let signing = Curve25519.Signing.PrivateKey()
        let rolls = (0 ..< 4).map { _ in DeviceIdentityKeys(signing: signing, agreement: Curve25519.KeyAgreement.PrivateKey()) }
        let deviceID = rolls[0].deviceID.uuidString
        var codes: [String] = []
        for roll in rolls.prefix(3) {
            try await handle(try hello(roll, nonce: code.nonce))
            let keybox = try await openedKeybox(roll)
            XCTAssertNotNil(keybox.grant.confirmNonce)
            codes.append(try XCTUnwrap(center.pendingLinks.first { $0.id == deviceID }?.sas))
        }
        XCTAssertEqual(draws.count, 3, "three re-rolls, three nonces")

        try await handle(try hello(rolls[3], nonce: code.nonce))

        XCTAssertEqual(draws.count, 4, "drawn before the save; the spent code throws it away")
        XCTAssertEqual(center.pendingLinks.map(\.id), [deviceID])
        XCTAssertEqual(center.pendingLinks.first?.sas, codes[2], "still the third request")
        XCTAssertEqual(
            try sidecar.pendingDevices().first?.agreementKey, rolls[2].agreement.publicKey.rawRepresentation)
        do {
            _ = try await openedKeybox(rolls[3])
            XCTFail("the 4th key must not open the keybox: it gets no nonce")
        } catch {}
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
