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

    /// #66.2: a double click on New code issues one code, not two.
    func testADoubleClickOnNewCodeIssuesOneCode() async throws {
        let sheet = makeSheet()
        await sheet.start()
        fixture.shares.clearCalls()

        let first = Task { await sheet.newCode() }
        let second = Task { await sheet.newCode() }
        await first.value
        await second.value

        XCTAssertEqual(fixture.shares.calls.filter { $0 == "ensureShares" }.count, 1)
        guard case .showing(let code) = sheet.phase else { return XCTFail("phase \(sheet.phase)") }
        XCTAssertEqual(code, fixture.center.openCode)
        await sheet.close()
    }

    /// #65: a code closed by an account change says so, not "expired".
    func testAnAccountChangeShowsWhyTheCodeClosed() async throws {
        let sheet = makeSheet()
        await sheet.start()

        fixture.center.accountChanged()
        await awaitHubCondition("the center closed the code") { fixture.center.lastCloseReason == .accountChanged }
        await sheet.tick()

        XCTAssertEqual(sheet.phase, .failed("This Mac's iCloud account changed. Show a new code."))
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
        let phone = try await fixture.pendingHello(name: "iPhone of colleague A")
        let sas = try XCTUnwrap(fixture.center.pendingLinks.first?.sas)
        try await fixture.center.confirmLink(deviceID: phone.deviceID.uuidString, sas: sas)
        await fixture.center.closeAfterLink?.value

        await sheet.tick()

        XCTAssertEqual(sheet.phase, .linked("iPhone of colleague A"))
    }

    // MARK: - The owner's confirmation (mobile E2E spec §2.3)

    func testAPendingRequestReplacesTheQRWithItsCodeAndButtons() async throws {
        let sheet = makeSheet()
        await sheet.start()
        XCTAssertTrue(sheet.pendingLinks.isEmpty)

        let phone = try await fixture.pendingHello(name: "Acme iPhone")
        await sheet.tick()

        guard case .showing = sheet.phase else { return XCTFail("phase \(sheet.phase)") }
        XCTAssertEqual(sheet.pendingLinks.map(\.id), [phone.deviceID.uuidString])
        XCTAssertEqual(sheet.pendingLinks.first?.name, "Acme iPhone")
        XCTAssertEqual(sheet.pendingLinks.first?.sas, fixture.center.pendingLinks.first?.sas)
        XCTAssertEqual(sheet.pendingLinks.first?.sas.count, 4)
        await sheet.close()
        XCTAssertTrue(sheet.pendingLinks.isEmpty, "closing the sheet refuses the request")
        XCTAssertEqual(try fixture.sidecar.linkRefusals().first?.reason, .notConfirmed)
    }

    func testLinkAndRefuseCallTheCenter() async throws {
        let sheet = makeSheet()
        await sheet.start()
        let refused = try await fixture.pendingHello(name: "Other iPhone")
        let linked = try await fixture.pendingHello(name: "Acme iPhone")
        let requests = Dictionary(uniqueKeysWithValues: sheet.pendingLinks.map { ($0.name, $0) })

        await sheet.refuse(try XCTUnwrap(requests["Other iPhone"]))

        XCTAssertEqual(sheet.pendingLinks.map(\.id), [linked.deviceID.uuidString])
        XCTAssertEqual(try fixture.sidecar.linkRefusals().map(\.deviceID), [refused.deviceID.uuidString])
        XCTAssertEqual(try fixture.sidecar.linkRefusals().first?.reason, .notConfirmed)

        await sheet.confirm(try XCTUnwrap(requests["Acme iPhone"]))
        await fixture.center.closeAfterLink?.value
        await sheet.tick()

        XCTAssertTrue(sheet.pendingLinks.isEmpty)
        XCTAssertNil(sheet.decisionError)
        XCTAssertEqual(fixture.center.devices.map(\.deviceID), [linked.deviceID.uuidString])
        XCTAssertEqual(sheet.phase, .linked("Acme iPhone"))
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
