import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// Settings → Mobile and the QR sheet as rendered (ViewInspector), over the
/// same real hub and link center on fakes as the model tests.
@MainActor
final class MobileSettingsViewTests: XCTestCase {
    private var fixture: MobileSettingsFixture!

    override func setUp() async throws {
        fixture = try MobileSettingsFixture()
    }

    override func tearDown() async throws {
        await fixture?.tearDown()
        fixture = nil
    }

    private static let codeButton = "Use Watchtower on iPhone"

    func testAnAdHocBuildShowsNeedsASignedBuildWithTheToggleDisabled() async throws {
        let model = fixture.makeModel(entitlementPresent: false)
        let view = MobileSettingsView(model: model)

        XCTAssertNoThrow(try view.inspect().find(text: "Needs a signed build"))
        XCTAssertTrue(try view.inspect().find(ViewType.Toggle.self).isDisabled())
    }

    func testASignedBuildHasAnEnabledToggleAndNoSignedBuildLine() throws {
        let view = MobileSettingsView(model: fixture.makeModel())

        XCTAssertThrowsError(try view.inspect().find(text: "Needs a signed build"))
        XCTAssertFalse(try view.inspect().find(ViewType.Toggle.self).isDisabled())
    }

    func testTheCorpFlavorShowsTheNoticeAndTheDefaultFlavorDoesNot() throws {
        let notice = "Work data from this Mac will be stored in your personal iCloud account."
        let corp = MobileSettingsView(model: fixture.makeModel(flavor: .corp))
        XCTAssertNoThrow(try corp.inspect().find(text: notice))

        let plain = MobileSettingsView(model: fixture.makeModel(flavor: .default))
        XCTAssertThrowsError(try plain.inspect().find(text: notice))
    }

    func testAnAvailableAccountShowsTheCodeButton() async throws {
        await fixture.startHub()
        let model = fixture.makeModel()
        await model.refresh()
        let view = MobileSettingsView(model: model)

        try view.inspect().find(button: Self.codeButton).tap()
        XCTAssertNotNil(model.linkSheet)
    }

    func testNoAccountAndRestrictedShowTheirSentencesAndNoCodeButton() async throws {
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
            let view = MobileSettingsView(model: model)

            XCTAssertNoThrow(try view.inspect().find(text: sentence))
            XCTAssertThrowsError(try view.inspect().find(button: Self.codeButton), "\(account): no QR button")
        }
    }

    func testSixtyOneSecondsOfThrottlingShowTheSlowingLine() async throws {
        await fixture.startHub()
        let model = fixture.makeModel()
        fixture.transport.setThrottledSince(fixture.clock.now.addingTimeInterval(-59))
        await model.refresh()
        XCTAssertThrowsError(try MobileSettingsView(model: model).inspect().find(text: "iCloud is slowing sync down"))

        fixture.clock.advance(2)
        await model.refresh()
        XCTAssertNoThrow(try MobileSettingsView(model: model).inspect().find(text: "iCloud is slowing sync down"))
    }

    func testThePhoneListShowsScopeTypingAndItsButtons() async throws {
        await fixture.tearDown()
        fixture = try MobileSettingsFixture(phones: [
            ("phone-a", .private, "_owner-acme"),
            ("phone-b", .shared, "_colleague-a")
        ])
        let model = fixture.makeModel()
        try fixture.center.setTypingAllowed(true, deviceID: "phone-b")
        let view = MobileSettingsView(model: model)

        XCTAssertNoThrow(try view.inspect().find(text: "Same Apple ID"))
        XCTAssertNoThrow(try view.inspect().find(text: "Shared"))
        XCTAssertNoThrow(try view.inspect().find(text: "Typing off"))
        XCTAssertNoThrow(try view.inspect().find(text: "Typing allowed"))
        let removes = try view.inspect().findAll(ViewType.Button.self) { try $0.labelView().text().string() == "Remove" }
        XCTAssertEqual(removes.count, 2)

        try view.inspect().find(button: "Allow…").tap()
        XCTAssertEqual(model.pendingAllow?.deviceID, "phone-a")

        try view.inspect().find(button: "Revoke").tap()
        XCTAssertFalse(try XCTUnwrap(fixture.sidecar.linkedDevice("phone-b")).typingAllowed)
    }

    // MARK: - The QR sheet

    func testTheSheetAtZeroShowsShowANewCode() async throws {
        let clock = fixture.clock
        let sheet = MobileLinkSheetViewModel(
            center: fixture.center, now: { clock.now }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
        await sheet.start()
        XCTAssertNoThrow(try MobileLinkSheet(model: sheet) {}.inspect().find(button: "New code"))
        XCTAssertNoThrow(try MobileLinkSheet(model: sheet) {}.inspect().find(text: "Expires in 10:00"))

        clock.advance(600)
        await sheet.tick()

        let view = MobileLinkSheet(model: sheet) {}
        XCTAssertNoThrow(try view.inspect().find(button: "Show a new code"))
        XCTAssertThrowsError(try view.inspect().find(button: "New code"))
        XCTAssertFalse(fixture.shares.isLinkOpen)
    }

    func testDoneOnTheSheetDismissesIt() throws {
        let clock = fixture.clock
        let sheet = MobileLinkSheetViewModel(center: fixture.center, now: { clock.now }, sleep: { _ in })
        var dismissed = false
        let view = MobileLinkSheet(model: sheet) { dismissed = true }

        try view.inspect().find(button: "Done").tap()
        XCTAssertTrue(dismissed)
    }
}
