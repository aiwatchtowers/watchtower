import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
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
    /// fails on time, never hangs the suite), or throw once cancelled.
    private var failingCalls: Set<String> = []
    private var hangingCalls: Set<String> = []
    private var cancellationAware = false

    init(account: CloudAvailability = .available) {
        self.account = account
    }

    var created: Int { lock.withLock { createdCount } }
    var calls: [String] { lock.withLock { log } }
    var shares: [CloudZoneID: Share] { lock.withLock { shareByZone } }
    /// True only when both shares exist and their public link is open.
    var isLinkOpen: Bool { lock.withLock { shareByZone.count == 2 && shareByZone.values.allSatisfy(\.publicOpen) } }

    func setAccount(_ value: CloudAvailability) { lock.withLock { account = value } }
    /// Every share call throws (sharing impossible on this account).
    func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    func clearCalls() { lock.withLock { log = [] } }
    func setFailing(_ calls: Set<String>) { lock.withLock { failingCalls = calls } }
    func setHanging(_ calls: Set<String>) { lock.withLock { hangingCalls = calls } }
    /// Every call throws `CancellationError` when its task is cancelled
    /// (like a cancellation-aware CloudKit await).
    func setCancellationAware(_ value: Bool) { lock.withLock { cancellationAware = value } }

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
        let (fails, hangs, aware) = lock.withLock {
            log.append(call)
            return (failing || failingCalls.contains(name), hangingCalls.contains(name), cancellationAware)
        }
        if aware { try Task.checkCancellation() }
        if fails { throw URLError(.cannotConnectToHost) }
        if hangs { try await Task.sleep(for: .seconds(5)) }
    }

    func accountStatus() async -> CloudAvailability {
        lock.withLock {
            log.append("accountStatus")
            return account
        }
    }

    func ensureShares() async throws -> ShareURLs {
        try await record("ensureShares")
        return lock.withLock {
            for zone in [CloudZoneID.data, .relay] where shareByZone[zone] == nil {
                createdCount += 1
                shareByZone[zone] = Share(url: "https://www.icloud.com/share/\(zone.rawValue)-\(createdCount)")
            }
            return ShareURLs(data: shareByZone[.data]?.url ?? "", relay: shareByZone[.relay]?.url ?? "")
        }
    }

    func setPublicLink(open: Bool) async throws {
        try await record("setPublicLink:\(open)")
        lock.withLock {
            for zone in shareByZone.keys { shareByZone[zone]?.publicOpen = open }
        }
    }

    func participants(in zone: CloudZoneID) async throws -> [ShareParticipant] {
        try await record("participants:\(zone.rawValue)")
        return lock.withLock { shareByZone[zone]?.participants ?? [] }
    }

    func removeParticipants(in zone: CloudZoneID, where shouldRemove: @escaping @Sendable (ShareParticipant) -> Bool) async throws {
        try await record("removeParticipants:\(zone.rawValue)")
        lock.withLock { shareByZone[zone]?.participants.removeAll(where: shouldRemove) }
    }

    func deleteShares() async throws {
        try await record("deleteShares")
        lock.withLock { shareByZone = [:] }
    }
}

/// The Mac side of linking (mobile POC spec §2.3, §4.13, §5.2 rule 4, §10)
/// on a fake share service and a fake clock.
@MainActor
final class MobileLinkCenterTests: XCTestCase {
    private var sidecar: HubSyncState!
    private var shares: FakeShareService!
    private var clock: LinkTestClock!
    private var nudges: [Set<SliceKind>] = []
    private var sharing: [HubSharing] = []
    private var center: MobileLinkCenter!

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
        center = nil
        sidecar = nil
        shares = nil
        clock = nil
    }

    /// The expiry timer parks (until cancelled) unless a test passes its own.
    private func makeCenter(
        sleep: (@Sendable (Duration) async -> Void)? = nil,
        shareTimeout: Duration = .seconds(30)
    ) throws -> MobileLinkCenter {
        let clock = try XCTUnwrap(self.clock)
        let made = MobileLinkCenter(
            sidecar: sidecar, shares: shares, macName: "Mac acme", ownerUser: { "_owner-acme" },
            nudge: { [weak self] in self?.nudges.append($0) },
            now: { clock.now },
            sleep: sleep ?? { _ in try? await Task.sleep(for: .seconds(3600)) },
            shareTimeout: shareTimeout
        )
        made.onSharingChanged = { [weak self] in self?.sharing.append($0) }
        return made
    }

    private func deviceRecord(
        _ deviceID: String,
        nonce: String?,
        scope: DeviceScope = .private,
        user: String = "_owner-acme",
        creator: String? = nil,
        name: String = "iPhone",
        unlinked: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        typingRequested: Bool = false,
        startSessions: Bool = true
    ) throws -> CloudRecord {
        let payload = DevicePayload(
            deviceID: deviceID, name: name, model: "iPhone18,1", appVersion: "0.0.0-test", scope: scope,
            userRecordName: user, linkNonce: nonce, unlinked: unlinked, typingRequested: typingRequested,
            startSessions: startSessions, updatedAt: clock.now
        )
        let record = try CloudRecordFactory.record(for: payload, modifiedAt: clock.now)
        return CloudRecord(
            recordName: record.recordName, zone: record.zone, kind: record.kind, modifiedAt: record.modifiedAt,
            payload: record.payload, creatorUserRecordName: creator
        )
    }

    /// One device record, and the close that follows a link.
    private func handle(_ record: CloudRecord) async throws {
        try await center.handleDevice(record)
        await center.closeAfterLink?.value
    }

    private func grants() throws -> [String: DeviceGrant] {
        try Dictionary(uniqueKeysWithValues: grantRecords().map {
            ($0.id, try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: $0.payload))
        })
    }

    private func grantRecords() throws -> [SliceRecord] {
        let hubID = try sidecar.ensureHubID()
        let clock = try XCTUnwrap(self.clock)
        let slice = DeviceGrantSlice(sidecar: sidecar, hubID: hubID) { clock.now }
        // The slice reads the sidecar; the main-DB handle is unused.
        return try DatabaseQueue().read { try slice.records($0) }
    }

    // MARK: - One link, idempotent

    func testAValidCodeLinksOnceAndTheSameQRScannedTwiceStaysOneLink() async throws {
        let code = try await center.issueCode()
        XCTAssertEqual(code.exp, code.iat + 600)
        let scan = try deviceRecord("phone-a", nonce: code.nonce)

        try await handle(scan)
        clock.advance(5)
        try await handle(scan)

        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a"])
        XCTAssertEqual(try sidecar.linkedDevices().count, 1)
        let grants = try grants()
        XCTAssertEqual(grants.count, 1)
        let grant = try XCTUnwrap(grants["phone-a"])
        XCTAssertTrue(grant.linked)
        XCTAssertNil(grant.linkRefused)
        XCTAssertEqual(grant.hubID, code.hubID)
        XCTAssertEqual(grant.scope, .private)
        XCTAssertFalse(grant.typingAllowed, "typing needs the owner's Allow")
        XCTAssertTrue(grant.startSessionsAllowed)
        XCTAssertEqual(try sidecar.linkCode(code.nonce)?.usedByDevice, "phone-a")
        XCTAssertTrue(nudges.contains([.deviceGrant]))
        XCTAssertNil(center.openCode, "the code is used")
    }

    // MARK: - Refusals

    func testAUsedExpiredOrMadeUpCodeIsRefusedWithItsReason() async throws {
        let used = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: used.nonce))
        try await handle(try deviceRecord("phone-b", nonce: used.nonce))

        let old = try await center.issueCode()
        clock.advance(601)
        try await handle(try deviceRecord("phone-c", nonce: old.nonce))
        try await handle(try deviceRecord("phone-d", nonce: LinkPayload.makeNonce()))

        let grants = try grants()
        XCTAssertEqual(grants["phone-b"]?.linkRefused, .usedCode)
        XCTAssertEqual(grants["phone-c"]?.linkRefused, .expiredCode)
        XCTAssertEqual(grants["phone-d"]?.linkRefused, .unknownCode)
        for id in ["phone-b", "phone-c", "phone-d"] {
            XCTAssertEqual(grants[id]?.linked, false, id)
            XCTAssertNil(grants[id]?.linkedAt, id)
        }
        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a"])
        XCTAssertNil(try sidecar.linkCode(old.nonce)?.usedByDevice, "an expired code is never used")
    }

    func testACodeIsStillValidAtExactly600Seconds() async throws {
        let code = try await center.issueCode()
        clock.advance(600)

        try await handle(try deviceRecord("phone-a", nonce: code.nonce))

        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a"])
    }

    func testALinkedPhoneKeepsItsLinkWhenItSendsAnUnknownCodeLater() async throws {
        let code = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: code.nonce))

        try await handle(try deviceRecord("phone-a", nonce: LinkPayload.makeNonce()))

        XCTAssertEqual(try grants()["phone-a"]?.linked, true)
        XCTAssertNil(try grants()["phone-a"]?.linkRefused)
    }

    func testARemovedPhoneIsNotLinkedAgainByItsOldCode() async throws {
        let code = try await center.issueCode()
        let scan = try deviceRecord("phone-a", nonce: code.nonce)
        try await handle(scan)
        try await center.remove(deviceID: "phone-a")

        try await handle(scan)

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try grants().isEmpty)
    }

    // MARK: - Two phones

    func testTwoPhonesWithTheirOwnCodesAreBothLinkedAndRemovingOneLeavesTheOtherApplied() async throws {
        let first = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: first.nonce))
        clock.advance(30)
        let second = try await center.issueCode()
        try await handle(try deviceRecord("phone-b", nonce: second.nonce))
        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a", "phone-b"])

        try await center.remove(deviceID: "phone-a")

        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-b"])
        XCTAssertEqual(Array(try grants().keys), ["phone-b"], "the removed phone's grant leaves the zone")
        let transport = StubHubTransport()
        let fromA = try probe(from: "phone-a")
        let fromB = try probe(from: "phone-b")
        try await transport.save([fromA, fromB])
        _ = try await RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        ).processOnce()

        XCTAssertEqual(try lastEcho(fromA, in: transport)?.reason, .deviceNotLinked)
        XCTAssertEqual(try lastEcho(fromB, in: transport)?.status, .applied)
    }

    private func probe(from deviceID: String, creator: String? = nil) throws -> CloudRecord {
        let action = ActionRequestPayload(
            id: UUID().uuidString, kind: .probe, entityID: nil, params: ["nonce": .string("n-\(deviceID)")],
            createdAt: Date(), deviceID: deviceID
        )
        let record = try CloudRecordFactory.record(for: action, modifiedAt: Date())
        return CloudRecord(
            recordName: record.recordName, zone: record.zone, kind: record.kind, modifiedAt: record.modifiedAt,
            payload: record.payload, creatorUserRecordName: creator
        )
    }

    private func lastEcho(_ record: CloudRecord, in transport: StubHubTransport) throws -> ActionRequestPayload? {
        try transport.saved.last { $0.record.recordName == record.recordName }.map { try decodeAction($0.record) }
    }

    // MARK: - Shared scope

    func testASharedPhoneThatAcceptedBothSharesIsLinked() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")

        try await handle(try deviceRecord(
            "phone-a", nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))

        XCTAssertEqual(center.devices.map(\.scope), [.shared])
        XCTAssertEqual(try grants()["phone-a"]?.linked, true)
    }

    func testASharedDeviceRecordFromAnotherCreatorIsRefusedWithNoGrant() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        shares.join("_stranger")

        try await handle(try deviceRecord(
            "phone-a", nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_stranger"
        ))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try grants().isEmpty, "no grant, not even a refusal")
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice, "the code stays usable for the owner's phone")
    }

    func testASharedPhoneThatDidNotAcceptBothSharesIsNotLinked() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a", zones: [.data])

        try await handle(try deviceRecord(
            "phone-a", nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice)
    }

    func testAPrivateDeviceRecordWrittenByAStrangerIsNotLinked() async throws {
        let code = try await center.issueCode()

        try await handle(try deviceRecord("phone-a", nonce: code.nonce, scope: .private, creator: "_stranger"))

        XCTAssertTrue(center.devices.isEmpty)
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
            id: UUID().uuidString, kind: .sessionReportRequest, entityID: "7", params: [:], createdAt: Date(), deviceID: "phone-x"
        )
        let transport = StubHubTransport()
        let record = try CloudRecordFactory.record(for: action, modifiedAt: Date())
        try await transport.save([record])

        _ = try await RelayProcessor(transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme").processOnce()

        let echo = try XCTUnwrap(try lastEcho(record, in: transport))
        XCTAssertEqual(echo.status, .failed)
        XCTAssertEqual(echo.reason, .deviceNotLinked)
        XCTAssertEqual(dispatched, 0)
    }

    func testASharedPhonesActionWrittenByAnotherCreatorFailsDeviceNotLinked() async throws {
        try sidecar.linkTestDevice("phone-a", scope: .shared, userRecordName: "_colleague-a")
        let transport = StubHubTransport()
        let forged = try probe(from: "phone-a", creator: "_stranger")
        let genuine = try probe(from: "phone-a", creator: "_colleague-a")
        let unknown = try probe(from: "phone-a")
        try await transport.save([forged, genuine, unknown])

        _ = try await RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        ).processOnce()

        XCTAssertEqual(try lastEcho(forged, in: transport)?.reason, .deviceNotLinked)
        XCTAssertEqual(try lastEcho(genuine, in: transport)?.status, .applied)
        XCTAssertEqual(try lastEcho(unknown, in: transport)?.reason, .deviceNotLinked, "a shared phone's record needs its creator")
    }

    func testTheRelayHandsDeviceRecordsToTheLinkCenter() async throws {
        let code = try await center.issueCode()
        let transport = StubHubTransport()
        try await transport.save([try deviceRecord("phone-a", nonce: code.nonce)])
        let center = try XCTUnwrap(self.center)
        let processor = RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme",
            deviceRecords: .init { try await center.handleDevice($0) }
        )

        _ = try await processor.processOnce()

        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a"])
    }

    // MARK: - Closing the link

    func testTheLinkClosesAtUseRemovingAnUnboundParticipantAndKeepingTheBoundOne() async throws {
        let code = try await center.issueCode()
        XCTAssertTrue(shares.isLinkOpen, "open while the QR is on screen")
        shares.join("_colleague-a")
        shares.join("_stranger")

        try await handle(try deviceRecord(
            "phone-a", nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))

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
        XCTAssertFalse(shares.isLinkOpen)
        XCTAssertNil(center.openCode)
        XCTAssertTrue(shares.participantNames(in: .relay).isEmpty)
    }

    func testTheExpiryTimerClosesTheLinkAfterTheCodesLifetime() async throws {
        let clock = try XCTUnwrap(self.clock)
        let slept = DurationBox()
        center = try makeCenter { duration in
            slept.set(duration)
            clock.advance(TimeInterval(duration.components.seconds))
        }

        _ = try await center.issueCode()

        await awaitHubCondition("the timer closes the link") { !self.shares.isLinkOpen }
        XCTAssertEqual(slept.value, .seconds(600))
        XCTAssertNil(center.openCode)
    }

    func testTheLinkClosesWhenTheSheetCloses() async throws {
        _ = try await center.issueCode()
        shares.join("_stranger")

        await center.closeLink(reason: .sheetClosed)

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

    // MARK: - Take over

    func testTakeOverDeletesTheSharesClearsDevicesAndTheNextCodeMakesNewShares() async throws {
        let first = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: first.nonce))
        XCTAssertEqual(shares.created, 2)

        await center.takeOverReset()

        XCTAssertTrue(shares.shares.isEmpty)
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        XCTAssertEqual(sharing.last, HubSharing.none)
        let next = try await center.issueCode()
        XCTAssertEqual(shares.created, 4, "new shares")
        XCTAssertNotEqual(next.dataShare, first.dataShare)
        XCTAssertNotEqual(next.relayShare, first.relayShare)
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
        try await handle(try deviceRecord("phone-a", nonce: first.nonce, name: "iPhone"))
        clock.advance(60)
        let second = try await center.issueCode()
        try await handle(try deviceRecord("phone-b", nonce: second.nonce, name: "iPhone"))

        XCTAssertEqual(center.devices.map(\.name), ["iPhone", "iPhone"])
        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a", "phone-b"])
        let dates = center.devices.map(\.linkedAt)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), 60)
    }

    func testASeventyEmojiNameIsClippedAtAGraphemeBoundary() async throws {
        let family = "👩‍👩‍👧‍👦"
        let code = try await center.issueCode()

        try await handle(try deviceRecord("phone-a", nonce: code.nonce, name: String(repeating: family, count: 70)))

        let name = try XCTUnwrap(center.devices.first?.name)
        XCTAssertEqual(name, String(repeating: family, count: 60))
        XCTAssertEqual(try grants()["phone-a"]?.name, name)
    }

    // MARK: - Same Apple ID

    func testAPrivatePhoneLinksWithoutAnyShareWhenSharingFails() async throws {
        shares.setFailing(true)

        let code = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: code.nonce))

        XCTAssertNil(code.dataShare)
        XCTAssertNil(code.relayShare)
        XCTAssertEqual(sharing, [.unavailable])
        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a"])
        XCTAssertEqual(shares.calls, ["accountStatus", "ensureShares"], "no link opened, so none to close")
    }

    func testLinkingAPrivatePhoneMakesNoParticipantCall() async throws {
        let code = try await center.issueCode()
        shares.clearCalls()

        try await handle(try deviceRecord("phone-a", nonce: code.nonce))

        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a"])
        XCTAssertFalse(shares.calls.contains { $0.hasPrefix("participants") })
    }

    // MARK: - Grants (Settings → Mobile)

    func testAllowAndRevokeSetTheGrantsTheSessionHandlersRead() async throws {
        let code = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: code.nonce))
        XCTAssertEqual(MobileLinkCenter.sessionGrant(sidecar, deviceID: "phone-a"), .specDefaults)
        clock.advance(10)

        try center.setTypingAllowed(true, deviceID: "phone-a")
        try center.setStartSessionsAllowed(false, deviceID: "phone-a")

        let device = try XCTUnwrap(center.devices.first)
        XCTAssertTrue(device.typingAllowed)
        XCTAssertFalse(device.startSessionsAllowed)
        XCTAssertEqual(device.decidedAt, clock.now)
        XCTAssertEqual(try grants()["phone-a"]?.typingAllowed, true)
        XCTAssertEqual(try grants()["phone-a"]?.decidedAt, clock.now)
        XCTAssertEqual(
            MobileLinkCenter.sessionGrant(sidecar, deviceID: "phone-a"),
            .init(typingAllowed: true, startSessionsAllowed: false)
        )
        XCTAssertEqual(MobileLinkCenter.sessionGrant(sidecar, deviceID: "phone-x"), .denied)
    }

    func testRemovingASharedPhoneRemovesItsParticipantFromBothShares() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        try await handle(try deviceRecord(
            "phone-a", nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))

        try await center.remove(deviceID: "phone-a")

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
        let service = CloudKitShareService { false }

        let account = await service.accountStatus()
        XCTAssertEqual(account, .unavailable("missing iCloud entitlement (unsigned dev build?)"))
        do {
            _ = try await service.ensureShares()
            XCTFail("ensureShares must refuse")
        } catch ShareServiceError.noEntitlement {}
        do {
            try await service.deleteShares()
            XCTFail("deleteShares must refuse")
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

        try await center.handleDevice(try deviceRecord(
            "phone-a", nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "bounded, not the 5 s hang")
        XCTAssertTrue(center.devices.isEmpty, "an unverified phone is not linked")
        XCTAssertNil(try sidecar.linkCode(code.nonce)?.usedByDevice)
    }

    /// The close after a link runs outside the relay pass, bounded.
    func testAHungCloseAfterALinkDoesNotHoldTheRelayPass() async throws {
        center = try makeCenter(shareTimeout: .milliseconds(100))
        let code = try await center.issueCode()
        shares.setHanging(["setPublicLink"])
        let started = Date()

        try await center.handleDevice(try deviceRecord("phone-a", nonce: code.nonce))

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a"])
        await center.closeAfterLink?.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the close is bounded too")
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "1", "the timed-out close stays pending")
    }

    /// A Remove whose participant removal fails is swept by the next close.
    func testAFailedParticipantRemovalIsSweptByTheNextClose() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        try await handle(try deviceRecord(
            "phone-a", nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"
        ))
        shares.setFailing(["removeParticipants"])

        do {
            try await center.remove(deviceID: "phone-a")
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
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        ).processOnce()
        return try lastEcho(record, in: transport)
    }

    private func linkSharedPhone(_ deviceID: String = "phone-a", user: String = "_colleague-a") async throws {
        let code = try await center.issueCode()
        shares.join(user)
        try await handle(try deviceRecord(deviceID, nonce: code.nonce, scope: .shared, user: user, creator: user))
        XCTAssertEqual(center.devices.map(\.deviceID), [deviceID])
    }

    /// #1: the phone's own unlink (`unlinked: true`, no nonce) removes it.
    func testAPhonesOwnUnlinkRemovesItAndItsLaterActionsFailDeviceNotLinked() async throws {
        let code = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: code.nonce))

        try await handle(try deviceRecord("phone-a", nonce: nil, unlinked: true))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertNil(try sidecar.linkedDevice("phone-a"))
        XCTAssertTrue(try grants().isEmpty, "its grant leaves the zone")
        let echo = try await relayedProbe(from: "phone-a")
        XCTAssertEqual(echo?.reason, .deviceNotLinked)
    }

    /// #1: in `shared` scope the phone has left the shares before the hub
    /// reads its unlink; the missing participant is no error.
    func testASharedPhonesUnlinkAfterItLeftTheSharesRemovesIt() async throws {
        try await linkSharedPhone()
        for zone in [CloudZoneID.data, .relay] {
            try await shares.removeParticipants(in: zone) { _ in true }
        }

        try await handle(try deviceRecord(
            "phone-a", nonce: nil, scope: .shared, user: "_colleague-a", creator: "_colleague-a", unlinked: true
        ))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        let echo = try await relayedProbe(from: "phone-a", creator: "_colleague-a")
        XCTAssertEqual(echo?.reason, .deviceNotLinked)
    }

    /// #1: a share failure after the phone's unlink still removes it and is
    /// swept by the next close; it never fails the relay pass.
    func testASharedUnlinkWhoseParticipantRemovalFailsStillRemovesThePhone() async throws {
        try await linkSharedPhone()
        shares.setFailing(["removeParticipants"])

        try await handle(try deviceRecord(
            "phone-a", nonce: nil, scope: .shared, user: "_colleague-a", creator: "_colleague-a", unlinked: true
        ))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "1")
    }

    /// #1: an unlink another iCloud user wrote removes nothing.
    func testAForgedUnlinkInSharedScopeRemovesNothing() async throws {
        try await linkSharedPhone()
        shares.join("_stranger")

        try await handle(try deviceRecord(
            "phone-a", nonce: nil, scope: .shared, user: "_colleague-a", creator: "_stranger", unlinked: true
        ))
        try await handle(try deviceRecord(
            "phone-a", nonce: nil, scope: .shared, user: "_stranger", creator: "_stranger", unlinked: true
        ))

        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-a"])
        XCTAssertEqual(try grants()["phone-a"]?.linked, true)
        let echo = try await relayedProbe(from: "phone-a", creator: "_colleague-a")
        XCTAssertEqual(echo?.status, .applied)
    }

    /// #1: once unlinked, a later stale code of the same Mac is refused with
    /// its reason, not swallowed as "already linked".
    func testAPhoneThatUnlinkedGetsTheRefusalOfAnExpiredCodeLater() async throws {
        let first = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: first.nonce))
        try await handle(try deviceRecord("phone-a", nonce: nil, unlinked: true))

        let second = try await center.issueCode()
        clock.advance(601)
        try await handle(try deviceRecord("phone-a", nonce: second.nonce))

        XCTAssertEqual(try grants()["phone-a"]?.linkRefused, .expiredCode)
    }

    /// #3: the phone's start-sessions toggle (a nonce-less rewrite) reaches
    /// the grant; `typing_requested` is not stored (R6).
    func testALinkedPhonesStartSessionsToggleIsMirroredAndTypingRequestIsNot() async throws {
        let code = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: code.nonce))
        clock.advance(10)

        try await handle(try deviceRecord("phone-a", nonce: nil, typingRequested: true, startSessions: false))

        let device = try XCTUnwrap(center.devices.first)
        XCTAssertFalse(device.startSessionsAllowed)
        XCTAssertFalse(device.typingAllowed, "a typing request is never a grant")
        XCTAssertEqual(device.decidedAt, clock.now)
        let grant = try XCTUnwrap(try grants()["phone-a"])
        XCTAssertFalse(grant.startSessionsAllowed)
        XCTAssertFalse(grant.typingAllowed)
        XCTAssertEqual(MobileLinkCenter.sessionGrant(sidecar, deviceID: "phone-a").startSessionsAllowed, false)

        clock.advance(10)
        try await handle(try deviceRecord("phone-a", nonce: nil, startSessions: true))
        XCTAssertEqual(center.devices.first?.startSessionsAllowed, true)
        XCTAssertEqual(center.devices.first?.decidedAt, clock.now)
    }

    /// #3: an unchanged choice stamps nothing new.
    func testAnUnchangedStartSessionsChoiceLeavesTheGrantAlone() async throws {
        let code = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: code.nonce))
        nudges = []

        try await handle(try deviceRecord("phone-a", nonce: nil, startSessions: true))

        XCTAssertNil(center.devices.first?.decidedAt)
        XCTAssertTrue(nudges.isEmpty)
    }

    /// #3: a nonce-less record of a phone that is not linked changes nothing.
    func testAnUnlinkedDevicesNonceLessRecordChangesNothing() async throws {
        nudges = []

        try await handle(try deviceRecord("phone-x", nonce: nil, startSessions: false))
        try await handle(try deviceRecord("phone-x", nonce: nil, unlinked: true))

        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        XCTAssertTrue(try sidecar.linkRefusals().isEmpty)
        XCTAssertTrue(nudges.isEmpty)
    }

    /// #3: a start-sessions rewrite another iCloud user wrote is ignored.
    func testAForgedStartSessionsRewriteInSharedScopeIsIgnored() async throws {
        try await linkSharedPhone()

        try await handle(try deviceRecord(
            "phone-a", nonce: nil, scope: .shared, user: "_colleague-a", creator: "_stranger", startSessions: false
        ))

        XCTAssertEqual(center.devices.first?.startSessionsAllowed, true)
    }

    /// #5: two refusals at different times publish different payloads, so
    /// the phone sees the second one as an answer.
    func testTwoRefusalsAtDifferentTimesPublishDifferentPayloads() async throws {
        let code = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: code.nonce))
        let scan = try deviceRecord("phone-b", nonce: code.nonce)

        try await handle(scan)
        let first = try XCTUnwrap(try grantRecords().first { $0.id == "phone-b" })
        clock.advance(5)
        try await handle(scan)
        let second = try XCTUnwrap(try grantRecords().first { $0.id == "phone-b" })

        XCTAssertNotEqual(first.payload, second.payload)
        let grant = try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: second.payload)
        XCTAssertEqual(grant.linkRefused, .usedCode)
        XCTAssertEqual(grant.decidedAt, Date(timeIntervalSince1970: clock.now.timeIntervalSince1970.rounded(.down)))
    }

    /// #7: New code retires the code it replaces.
    func testANewCodeRetiresThePreviousUnusedCode() async throws {
        let first = try await center.issueCode()
        let second = try await center.issueCode()

        try await handle(try deviceRecord("phone-a", nonce: first.nonce))
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(try grants()["phone-a"]?.linkRefused, .expiredCode)

        try await handle(try deviceRecord("phone-b", nonce: second.nonce))
        XCTAssertEqual(center.devices.map(\.deviceID), ["phone-b"])
    }
}

/// The last `Duration` the expiry timer asked to sleep.
final class DurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Duration?

    var value: Duration? { lock.withLock { stored } }
    func set(_ duration: Duration) { lock.withLock { stored = duration } }
}
