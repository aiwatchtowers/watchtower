import CoreImage
import Foundation
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop
import WatchtowerTestSupport

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

    /// Waits, with no deadline, until the model's observable state meets `condition`.
    private func waitUntil(_ what: String, _ condition: @escaping @MainActor () -> Bool) async {
        await untilObserved(condition)
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
        XCTAssertEqual(session.sent, [#"{"code":"4827","confirm":true,"moves_to_relay":false}"#], "an older CLI's line: no move")
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
        XCTAssertEqual(session.sent, [#"{"code":"4827","confirm":false,"moves_to_relay":false}"#])
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
        let reader = try XCTUnwrap(model.reader)
        model.cancel()
        XCTAssertTrue(session.stopped)
        session.push(qrLine(expiresIn: 600))
        await reader.value // the stream's reader has ended
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
        let oldReader = try XCTUnwrap(model.reader)
        await model.start()
        XCTAssertEqual(streamer.sessions.count, 2)
        XCTAssertTrue(streamer.sessions[0].stopped)
        XCTAssertFalse(streamer.sessions[1].stopped)
        streamer.sessions[0].push(qrLine(expiresIn: 600))
        await oldReader.value // the old stream's reader has ended
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
        XCTAssertEqual(
            Model.relayMoveWarning("Work Mac"),
            "Linking this iPhone moves Work Mac to Relay. "
                + "iPhones linked over iCloud without Relay lose their connection until they subscribe."
        )
        for blank in ["", "  "] {
            XCTAssertEqual(
                Model.relayMoveWarning(blank),
                "Linking this iPhone moves this Mac to Relay. "
                    + "iPhones linked over iCloud without Relay lose their connection until they subscribe.",
                "a hub status without a name: \"\(blank)\""
            )
        }
    }

    /// #2191 Task 4 contract: the hub prints a new `sas` line when the phone's
    /// request changes its code or `moves_to_relay`, and reprints the current
    /// one before it waits for another answer (`code_changed`, an ambiguous
    /// yes). Every `sas` line means "answer this one": the latest is shown,
    /// also after Link, and each answer carries that line's code and
    /// `moves_to_relay` and `request` (the final Task 4 contract).
    func testEverySASLineAsksAndTheAnswerCarriesWhatWasShown() async throws {
        let streamer = FakePairStreamer()
        let model = Model(streamer: streamer, macName: "Work Mac", now: { self.start }, sleep: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        await model.start()
        let session = try XCTUnwrap(streamer.sessions.first)
        let first = #"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"4827","moves_to_relay":false,"request":"0123456789abcdef"}"#
        let second = #"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"1093","moves_to_relay":true,"request":"fedcba9876543210"}"#
        let firstYes = #"{"code":"4827","confirm":true,"moves_to_relay":false,"request":"0123456789abcdef"}"#
        let secondYes = #"{"code":"1093","confirm":true,"moves_to_relay":true,"request":"fedcba9876543210"}"#

        model.receive(first)
        XCTAssertEqual(model.step, .sas(code: "4827", phone: "Phone A"))
        XCTAssertNil(model.relayMoveWarning)

        // A changed request before the answer: the new code and warning replace the shown ones.
        model.receive(second)
        XCTAssertEqual(model.step, .sas(code: "1093", phone: "Phone A"))
        XCTAssertEqual(model.relayMoveWarning, Model.relayMoveWarning("Work Mac"))

        // An identical reprint while asking changes nothing and sends nothing.
        model.receive(second)
        XCTAssertEqual(model.step, .sas(code: "1093", phone: "Phone A"))
        XCTAssertEqual(model.relayMoveWarning, Model.relayMoveWarning("Work Mac"))
        XCTAssertTrue(session.sent.isEmpty)

        await model.confirm(true)
        XCTAssertEqual(session.sent, [secondYes], "the answer names the line on screen")
        XCTAssertEqual(model.step, .waiting)
        await model.confirm(true)
        XCTAssertEqual(session.sent.count, 1, "a second press while waiting sends nothing")

        // An identical reprint after Link (an ambiguous yes): asked again with
        // the same values; the next answer goes out, nothing is lost.
        model.receive(second)
        XCTAssertEqual(model.step, .sas(code: "1093", phone: "Phone A"))
        XCTAssertEqual(model.relayMoveWarning, Model.relayMoveWarning("Work Mac"))
        await model.confirm(true)
        XCTAssertEqual(session.sent, [secondYes, secondYes])

        // The request changed after Link (code_changed): the new line asks
        // again with its own values. Not a failure.
        model.receive(first)
        XCTAssertEqual(model.step, .sas(code: "4827", phone: "Phone A"))
        XCTAssertNil(model.relayMoveWarning, "the newest line moves nothing")
        await model.confirm(true)
        XCTAssertEqual(session.sent, [secondYes, secondYes, firstYes])

        model.receive(second)
        await model.confirm(false)
        XCTAssertEqual(
            session.sent.last, #"{"code":"1093","confirm":false,"moves_to_relay":true,"request":"fedcba9876543210"}"#,
            "a no carries them too"
        )

        // A name-only change is no replacement: the new name shows, the same request is answered.
        model.receive(first.replacingOccurrences(of: "Phone A", with: "Phone A (renamed)"))
        XCTAssertEqual(model.step, .sas(code: "4827", phone: "Phone A (renamed)"))
        await model.confirm(true)
        XCTAssertEqual(session.sent.last, firstYes)

        model.receive(#"{"event":"linked","device_id":"AAAA0001"}"#)
        XCTAssertEqual(model.step, .linked("Phone A (renamed)"))
        XCTAssertNil(model.relayMoveWarning)
    }

    /// Q6 (#2191): the `sas` line's `moves_to_relay` decides the warning; an
    /// older CLI without the key warns nothing, and every later step clears it.
    func testTheRelayLinkWarningShowsOnlyWithICloudPhones() async throws {
        let streamer = FakePairStreamer()
        let clock = Clock(start)
        let model = Model(streamer: streamer, macName: "Work Mac", now: { clock.now }, sleep: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let warning = "Linking this iPhone moves Work Mac to Relay. "
            + "iPhones linked over iCloud without Relay lose their connection until they subscribe."
        let sas = #"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"4827""#
        XCTAssertNil(model.relayMoveWarning)

        model.receive(sas + #","moves_to_relay":true}"#)
        XCTAssertEqual(model.relayMoveWarning, warning)
        model.receive(#"{"event":"linked","device_id":"AAAA0001"}"#)
        XCTAssertNil(model.relayMoveWarning, "linked clears it")

        model.receive(sas + #","moves_to_relay":true}"#)
        model.receive(#"{"event":"refused","reason":"not_confirmed"}"#)
        XCTAssertNil(model.relayMoveWarning, "refused clears it")

        model.receive(sas + #","moves_to_relay":false}"#)
        XCTAssertNil(model.relayMoveWarning)
        model.receive(sas + "}")
        XCTAssertNil(model.relayMoveWarning, "an older CLI without the key")

        model.receive(sas + #","moves_to_relay":true}"#)
        XCTAssertEqual(model.relayMoveWarning, warning)
        model.markConfirmed()
        XCTAssertEqual(model.step, .waiting)
        XCTAssertNil(model.relayMoveWarning, "the busy step after Link warns nothing")

        model.receive(sas + #","moves_to_relay":true}"#)
        model.streamEnded("The hub is not running.")
        XCTAssertNil(model.relayMoveWarning, "a failure clears it")

        model.receive(sas + #","moves_to_relay":true}"#)
        await model.start()
        XCTAssertNil(model.relayMoveWarning, "a new code clears it")
    }

    func testTheQRImageScansBackToTheLinkURL() throws {
        let image = try XCTUnwrap(LinkQRCode.cgImage(for: url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(features.first?.messageString, url)
    }
}
