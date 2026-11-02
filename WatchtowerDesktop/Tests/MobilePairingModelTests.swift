import CoreImage
import Foundation
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// The pairing sheet over `hub pair --json --stream` (go hub plan 3 Task
/// 23). The behaviours of the deleted `MobileLinkSheetViewModelTests` that
/// still hold are pinned here, on the stream.
@MainActor
final class MobilePairingModelTests: XCTestCase {
    typealias Model = MobilePairingModel
    private let url = "watchtower://link?d=eyJ2IjoxfQ"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func qrLine(expiresIn seconds: Int) -> String {
        let expires = ISO8601DateFormatter().string(from: start.addingTimeInterval(TimeInterval(seconds)))
        return #"{"event":"qr","url":"\#(url)","expires_at":"\#(expires)"}"#
    }

    /// A model whose countdown never runs on its own (the test ticks it).
    private func makeModel(_ streamer: FakePairStreamer, clock: Clock) -> Model {
        Model(streamer: streamer, now: { clock.now }, sleep: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
    }

    func testPairingStreamDrivesSteps() async throws {
        let streamer = FakePairStreamer()
        let clock = Clock(start)
        let model = makeModel(streamer, clock: clock)
        XCTAssertEqual(model.step, .starting)
        await model.start()
        let session = try XCTUnwrap(streamer.sessions.first)

        session.push(qrLine(expiresIn: 600))
        await waitUntil("the QR") { if case .qr = model.step { true } else { false } }
        XCTAssertEqual(model.step, .qr(try XCTUnwrap(URL(string: url)), expires: start.addingTimeInterval(600)))
        XCTAssertNotNil(model.qrImage)
        XCTAssertTrue(model.showsCode)
        model.tick()
        XCTAssertEqual(model.countdownText, "Expires in 10:00")

        session.push(#"{"event":"waiting"}"#)
        await waitUntil("waiting") { model.step == .waiting }
        XCTAssertTrue(model.showsCode, "the QR stays while the phone is awaited")

        session.push(#"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"4827"}"#)
        await waitUntil("the code") { model.step == .sas(code: "4827", phone: "Phone A") }
        XCTAssertEqual(Model.linkQuestion("Phone A"), "Link \u{201C}Phone A\u{201D}?")

        await model.confirm(true)
        XCTAssertEqual(session.sent, [#"{"confirm":true}"#])
        XCTAssertFalse(model.showsCode)

        session.push(#"{"event":"linked","device_id":"AAAA0001"}"#)
        await waitUntil("linked") { model.step == .linked("Phone A") }
        XCTAssertEqual(Model.linkedTitle("Phone A"), "Linked Phone A")
        XCTAssertEqual(Model.linkedDetail, "It shows this Mac's board and sessions now.")
    }

    func testRefuseWritesConfirmFalse() async throws {
        let streamer = FakePairStreamer()
        let model = makeModel(streamer, clock: Clock(start))
        await model.start()
        let session = try XCTUnwrap(streamer.sessions.first)
        await model.confirm(false)
        XCTAssertTrue(session.sent.isEmpty, "no answer before a code is on screen")
        session.push(#"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"4827"}"#)
        await waitUntil("the code") { if case .sas = model.step { true } else { false } }
        await model.confirm(false)
        XCTAssertEqual(session.sent, [#"{"confirm":false}"#])
        session.push(#"{"event":"refused","reason":"not_confirmed"}"#)
        await waitUntil("refused") { model.step == .refused("not_confirmed") }
    }

    func testEveryRefusalHasItsLine() {
        let cases = [
            ("used_code", "This code was already used.", "Show a new code"),
            ("expired_code", "This code expired.", "Show a new code"),
            ("unknown_code", "The phone sent a code this Mac does not know.", "Show a new code"),
            ("not_confirmed", "Not linked: the code was not confirmed.", "Show a new code"),
            ("too_many_requests", "Too many phones tried this code.", "Show a new code"),
            ("something_new", "The phone could not be linked.", "Try again")
        ]
        for (reason, text, action) in cases {
            XCTAssertEqual(Model.refusalText(reason), text, reason)
            XCTAssertEqual(Model.refusalAction(reason), action, reason)
        }
    }

    func testCancelClosesTheStream() async throws {
        let streamer = FakePairStreamer()
        let model = makeModel(streamer, clock: Clock(start))
        await model.start()
        let session = try XCTUnwrap(streamer.sessions.first)
        model.cancel()
        XCTAssertTrue(session.stopped)
        session.push(qrLine(expiresIn: 600))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.step, .starting, "nothing shows after the sheet closed")
        await model.start()
        XCTAssertEqual(streamer.sessions.count, 1, "a closed sheet starts no stream")
    }

    /// At 0 the stream stops and the code reads as expired (today's sheet
    /// closed the link at 0); Show a new code starts a new stream.
    func testTheCountdownAtZeroEndsAsExpired() async throws {
        let streamer = FakePairStreamer()
        let clock = Clock(start)
        let model = makeModel(streamer, clock: clock)
        await model.start()
        let first = try XCTUnwrap(streamer.sessions.first)
        first.push(qrLine(expiresIn: 600))
        await waitUntil("the QR") { model.showsCode }
        clock.now = start.addingTimeInterval(599)
        XCTAssertTrue(model.tick())
        XCTAssertEqual(model.countdownText, "Expires in 0:01")
        clock.now = start.addingTimeInterval(600)
        XCTAssertFalse(model.tick())
        XCTAssertEqual(model.step, .refused("expired_code"))
        XCTAssertTrue(first.stopped)

        await model.start()
        XCTAssertEqual(streamer.sessions.count, 2)
        XCTAssertEqual(model.step, .starting)
    }

    /// New code: the old stream stops, a new one starts; a double start keeps one stream open.
    func testNewCodeReplacesTheStream() async throws {
        let streamer = FakePairStreamer()
        let model = makeModel(streamer, clock: Clock(start))
        await model.start()
        await model.start()
        XCTAssertEqual(streamer.sessions.count, 2)
        XCTAssertTrue(streamer.sessions[0].stopped)
        XCTAssertFalse(streamer.sessions[1].stopped)
        streamer.sessions[0].push(qrLine(expiresIn: 600))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.step, .starting, "the old stream's lines are dropped")
    }

    func testAFailedPairingSaysWhy() async throws {
        let streamer = FakePairStreamer()
        let model = makeModel(streamer, clock: Clock(start))
        await model.start()
        let session = try XCTUnwrap(streamer.sessions.first)
        session.failureText = "The hub is not running."
        session.end()
        await waitUntil("failed") { model.step == .failed("The hub is not running.") }

        await model.start()
        streamer.sessions[1].end()
        await waitUntil("ended with nothing") { model.step == .failed(Model.unknownRefusal) }

        streamer.startError = CLIRunnerError.binaryNotFound
        await model.start()
        XCTAssertEqual(model.step, .failed(CLIRunnerError.binaryNotFound.localizedDescription))

        let noBinary = Model(streamer: nil)
        await noBinary.start()
        XCTAssertEqual(noBinary.step, .failed(CLIRunnerError.binaryNotFound.localizedDescription))
    }

    func testCopy() {
        XCTAssertEqual(Model.title, "Use Watchtower on iPhone")
        XCTAssertEqual(Model.startingText, "Making a code…")
        XCTAssertEqual(Model.scanText, "Scan it with the iPhone camera or the Watchtower app.")
        XCTAssertEqual(Model.waitingText, "Waiting for your phone…")
        XCTAssertEqual(Model.checkCodeText, "Check that your iPhone shows the same code")
        XCTAssertEqual(Model.expiresText(581), "Expires in 9:41")
        XCTAssertEqual(HubPairCLIStreamer.args, ["hub", "pair", "--json", "--stream"])
    }

    func testTheQRImageScansBackToTheLinkURL() throws {
        let image = try XCTUnwrap(LinkQRCode.cgImage(for: url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(features.first?.messageString, url)
    }
}
