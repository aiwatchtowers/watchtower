import CoreImage
import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// The QR sheet (mobile POC spec §2.3): the code, its 10-minute countdown,
/// New code, and closing the link at 0 and when the sheet closes.
@MainActor
final class MobileLinkSheetViewModelTests: XCTestCase {
    private var fixture: MobileSettingsFixture!

    override func setUp() async throws {
        fixture = try MobileSettingsFixture()
    }

    override func tearDown() async throws {
        await fixture?.tearDown()
        fixture = nil
    }

    /// The countdown's sleep moves the fake clock by what it was asked to wait.
    private func makeSheet(
        sleep: (@Sendable (Duration) async -> Void)? = nil
    ) -> MobileLinkSheetViewModel {
        let clock = fixture.clock
        return MobileLinkSheetViewModel(
            center: fixture.center,
            now: { clock.now },
            sleep: sleep ?? { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
    }

    func testStartShowsACodeWithTenMinutesLeft() async throws {
        let sheet = makeSheet()
        await sheet.start()

        guard case .showing(let code) = sheet.phase else { return XCTFail("phase \(sheet.phase)") }
        XCTAssertEqual(code, fixture.center.openCode)
        XCTAssertEqual(sheet.remainingSeconds, 600)
        XCTAssertEqual(sheet.countdownText, "10:00")
        XCTAssertTrue(fixture.shares.isLinkOpen)
        await sheet.close()
    }

    func testTheCountdownAtZeroShowsANewCodeOfferAndClosesTheLink() async throws {
        let sheet = makeSheet()
        await sheet.start()
        fixture.clock.advance(599)
        await sheet.tick()
        XCTAssertEqual(sheet.countdownText, "0:01")
        XCTAssertTrue(fixture.shares.isLinkOpen)

        fixture.clock.advance(1)
        await sheet.tick()

        XCTAssertEqual(sheet.phase, .expired)
        XCTAssertFalse(fixture.shares.isLinkOpen, "closeLink(.expired) closed the public link")
        XCTAssertNil(fixture.center.openCode)
    }

    func testTheCountdownLoopRunsToZeroOnItsOwn() async throws {
        let clock = fixture.clock
        let sheet = makeSheet { duration in
            clock.advance(TimeInterval(duration.components.seconds))
            await Task.yield()
        }
        await sheet.start()

        await awaitHubCondition("the countdown reached 0") { sheet.phase == .expired }
        XCTAssertFalse(fixture.shares.isLinkOpen)
    }

    func testNewCodeReplacesTheCodeAndRestartsTheCountdown() async throws {
        let sheet = makeSheet()
        await sheet.start()
        let first = fixture.center.openCode
        fixture.clock.advance(600)
        await sheet.tick()
        XCTAssertEqual(sheet.phase, .expired)

        await sheet.newCode()

        guard case .showing(let code) = sheet.phase else { return XCTFail("phase \(sheet.phase)") }
        XCTAssertNotEqual(code.nonce, first?.nonce)
        XCTAssertEqual(sheet.remainingSeconds, 600)
        XCTAssertTrue(fixture.shares.isLinkOpen)
        await sheet.close()
    }

    func testCloseClosesTheLink() async throws {
        let sheet = makeSheet()
        await sheet.start()
        XCTAssertTrue(fixture.shares.isLinkOpen)

        await sheet.close()

        XCTAssertFalse(fixture.shares.isLinkOpen, "closeLink(.sheetClosed)")
        XCTAssertNil(fixture.center.openCode)
    }

    func testAUsedCodeShowsThePhoneAsLinked() async throws {
        let sheet = makeSheet()
        await sheet.start()
        guard case .showing(let code) = sheet.phase else { return XCTFail("phase \(sheet.phase)") }
        let payload = DevicePayload(
            deviceID: "phone-a", name: "iPhone of colleague A", model: "iPhone18,1", appVersion: "0.0.0-test",
            scope: .private, userRecordName: "_owner-acme", linkNonce: code.nonce, typingRequested: false,
            startSessions: true, updatedAt: fixture.clock.now
        )
        try await fixture.center.handleDevice(try CloudRecordFactory.record(for: payload, modifiedAt: fixture.clock.now))
        await fixture.center.closeAfterLink?.value

        await sheet.tick()

        XCTAssertEqual(sheet.phase, .linked("iPhone of colleague A"))
    }

    func testAnAccountRefusalShowsItsSentence() async throws {
        fixture.shares.setAccount(.noAccount)
        let sheet = makeSheet()
        await sheet.start()

        XCTAssertEqual(sheet.phase, .failed("Mobile isn't available on this Mac: iCloud is off."))
        XCTAssertFalse(fixture.shares.isLinkOpen)
    }

    func testTheQRImageScansBackToTheLinkURL() throws {
        let url = "watchtower://link?d=eyJ2IjoxfQ"
        let image = try XCTUnwrap(LinkQRCode.cgImage(for: url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(features.first?.messageString, url)
    }
}
