import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// Settings → Mobile on the Mac (mobile POC spec §2.3, §8 I-1, §9, §10):
/// the toggle, the hub status, the QR gate and the phone list, over a real
/// hub and link center on fakes.
@MainActor
final class MobileSettingsViewModelTests: XCTestCase {
    private var fixture: MobileSettingsFixture!

    override func setUp() async throws {
        fixture = try MobileSettingsFixture()
    }

    override func tearDown() async throws {
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: - The toggle

    func testAnAdHocBuildDisablesTheToggleAndOffersNoCode() async throws {
        await fixture.startHub()
        let model = fixture.makeModel(entitlementPresent: false)
        await model.refresh()

        XCTAssertTrue(model.toggleDisabled)
        XCTAssertFalse(model.canShowCode)

        await model.setEnabled(true)
        XCTAssertEqual(fixture.host.setCalls, [], "a disabled toggle never turns the hub on")
        await model.setEnabled(false)
        XCTAssertEqual(fixture.host.setCalls, [false], "turning it off stays possible")
    }

    func testTheToggleDrivesTheAppsHubSwitch() async throws {
        fixture.host.isMobileSyncEnabled = false
        let model = fixture.makeModel()
        XCTAssertFalse(model.isOn)

        await model.setEnabled(true)
        XCTAssertEqual(fixture.host.setCalls, [true])
        XCTAssertTrue(model.isOn)

        await model.setEnabled(false)
        XCTAssertEqual(fixture.host.setCalls, [true, false])
        XCTAssertFalse(model.isOn)
    }

    func testTheCorpNoticeShowsOnlyInTheCorpFlavor() {
        XCTAssertTrue(fixture.makeModel(flavor: .corp).showsCorpNotice)
        XCTAssertFalse(fixture.makeModel(flavor: .default).showsCorpNotice)
    }

    // MARK: - iCloud and the QR gate

    func testAnAvailableAccountOnARunningHubOffersTheCode() async throws {
        await fixture.startHub()
        let model = fixture.makeModel()
        await model.refresh()

        XCTAssertEqual(model.account, .available)
        XCTAssertNil(model.accountMessage)
        XCTAssertTrue(model.canShowCode)
    }

    func testNoAccountAndRestrictedShowTheirSentencesAndNoCode() async throws {
        let cases: [(CloudAvailability, String)] = [
            (.noAccount, "Mobile isn't available on this Mac: iCloud is off."),
            (.restricted, "Mobile isn't available on this Mac: iCloud is restricted by your organization.")
        ]
        for (account, sentence) in cases {
            await fixture.tearDown()
            fixture = try MobileSettingsFixture(shareAccount: account)
            await fixture.startHub()
            let model = fixture.makeModel()
            await model.refresh()

            XCTAssertEqual(model.accountMessage, sentence)
            XCTAssertFalse(model.canShowCode, "\(account): no QR")
            model.showCode()
            XCTAssertNil(model.linkSheet)
        }
    }

    func testTheCodeNeedsTheHubOn() async throws {
        let model = fixture.makeModel()
        await model.refresh()
        XCTAssertEqual(fixture.hub.status, .off)
        XCTAssertFalse(model.canShowCode, "a hub that is not running shows no QR")
    }

    // MARK: - Hub status

    func testTheHubStatusLines() {
        XCTAssertEqual(MobileSettingsViewModel.statusLine(.off), "Off")
        XCTAssertEqual(MobileSettingsViewModel.statusLine(.running), "On")
        XCTAssertEqual(
            MobileSettingsViewModel.statusLine(.otherHub("Mac B")),
            "Mac B is your hub. Turn it off there, or Take over"
        )
        XCTAssertEqual(MobileSettingsViewModel.statusLine(.tookOver("Mac B")), "Another Mac took over")
        XCTAssertEqual(MobileSettingsViewModel.statusLine(.unavailable("offline")), "Unavailable: offline")
    }

    func testTheStatusReportsTheLastPublishAndTheBacklog() async throws {
        await fixture.startHub()
        let model = fixture.makeModel()
        await awaitHubCondition("the publisher's first pass") { self.fixture.hub.lastPublishAt != nil }
        await model.refresh()

        XCTAssertEqual(model.statusLine, "On")
        XCTAssertNotNil(model.lastPublishAt)
        XCTAssertEqual(model.relayBacklog, 0)
    }

    func testSixtyOneSecondsOfThrottlingShowTheSlowingLineAndFiftyNineDoNot() async throws {
        await fixture.startHub()
        let model = fixture.makeModel()

        fixture.transport.setThrottledSince(fixture.clock.now.addingTimeInterval(-59))
        await model.refresh()
        XCTAssertFalse(model.showsSlowingLine)

        fixture.clock.advance(2)
        await model.refresh()
        XCTAssertTrue(model.showsSlowingLine)
        XCTAssertEqual(MobileSettingsViewModel.slowingLine, "iCloud is slowing sync down")

        fixture.transport.setThrottledSince(nil)
        await model.refresh()
        XCTAssertFalse(model.showsSlowingLine, "a send that went through ends the line")
    }

    // MARK: - The QR sheet

    func testClosingTheSheetClosesTheLink() async throws {
        await fixture.startHub()
        let model = fixture.makeModel()
        await model.refresh()

        model.showCode()
        let sheet = try XCTUnwrap(model.linkSheet)
        await sheet.start()
        XCTAssertTrue(fixture.shares.isLinkOpen)
        XCTAssertNotNil(fixture.center.openCode)

        await model.linkSheetDismissed()

        XCTAssertNil(model.linkSheet)
        XCTAssertFalse(fixture.shares.isLinkOpen, "closeLink(.sheetClosed) closed the public link")
        XCTAssertNil(fixture.center.openCode)
        XCTAssertEqual(fixture.shares.calls.last { $0.hasPrefix("setPublicLink") }, "setPublicLink:false")
    }

    func testLeavingTheTabClosesAnOpenSheetsLink() async throws {
        await fixture.startHub()
        let model = fixture.makeModel()
        await model.refresh()
        model.showCode()
        await model.linkSheet?.start()
        XCTAssertTrue(fixture.shares.isLinkOpen)

        await model.disappeared()

        XCTAssertNil(model.linkSheet)
        XCTAssertFalse(fixture.shares.isLinkOpen)
    }

    // MARK: - The phone list

    func testAllowSetsTypingAllowedAndRevokeClearsIt() async throws {
        await fixture.tearDown()
        fixture = try MobileSettingsFixture(phones: [("phone-a", .private, "_owner-acme")])
        let model = fixture.makeModel()
        let phone = try XCTUnwrap(model.devices.first)
        XCTAssertFalse(phone.typingAllowed)

        model.requestAllow(phone)
        XCTAssertEqual(model.pendingAllow?.deviceID, "phone-a")
        XCTAssertFalse(try XCTUnwrap(fixture.sidecar.linkedDevice("phone-a")).typingAllowed, "Allow… asks first")

        model.confirmAllow()
        XCTAssertNil(model.pendingAllow)
        XCTAssertTrue(try XCTUnwrap(fixture.sidecar.linkedDevice("phone-a")).typingAllowed)
        XCTAssertTrue(try XCTUnwrap(model.devices.first).typingAllowed)

        model.revoke(try XCTUnwrap(model.devices.first))
        XCTAssertFalse(try XCTUnwrap(fixture.sidecar.linkedDevice("phone-a")).typingAllowed)
    }

    func testRemovingASameAppleIDPhoneSaysItCanStillRead() async throws {
        await fixture.tearDown()
        fixture = try MobileSettingsFixture(phones: [("phone-a", .private, "_owner-acme")])
        let model = fixture.makeModel()

        await model.remove(try XCTUnwrap(model.devices.first))

        XCTAssertNil(try fixture.sidecar.linkedDevice("phone-a"))
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(
            model.notice,
            "Removed. It is signed into your Apple ID, so it can still read synced data until you sign it out of iCloud"
        )
    }

    func testRemovingASharedPhoneDropsItsParticipant() async throws {
        try await useSharedPhoneFixture()
        let model = fixture.makeModel()

        await model.remove(try XCTUnwrap(model.devices.first))

        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(model.notice, "Removed iPhone.")
        XCTAssertEqual(fixture.shares.participantNames(in: .data), [])
    }

    func testAFailedShareRemovalStillRemovesThePhoneAndSaysSo() async throws {
        try await useSharedPhoneFixture()
        fixture.shares.setFailing(["removeParticipants"])
        let model = fixture.makeModel()

        await model.remove(try XCTUnwrap(model.devices.first))

        XCTAssertTrue(model.devices.isEmpty, "the gate refuses the phone at once")
        let notice = try XCTUnwrap(model.notice)
        XCTAssertTrue(notice.hasPrefix("Removed iPhone. iCloud sharing is cleaned up at the next code"), notice)
    }

    /// A `shared` phone of colleague A, a participant of both shares.
    private func useSharedPhoneFixture() async throws {
        await fixture.tearDown()
        fixture = try MobileSettingsFixture(phones: [("phone-b", .shared, "_colleague-a")])
        _ = try await fixture.shares.ensureShares()
        fixture.shares.join("_colleague-a")
    }
}
