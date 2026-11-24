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

        model.confirm(true, answering: try XCTUnwrap(model.question))
        XCTAssertEqual(
            session.sent, [#"{"code":"4827","confirm":true,"moves_to_relay":false,"request":""}"#], "an older CLI's line: no move, no request"
        )
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
        XCTAssertNil(model.question, "no question before a code is on screen")
        model.confirm(false, answering: Model.Question(code: "4827", movesToRelay: false, request: ""))
        XCTAssertTrue(session.sent.isEmpty, "no answer before a code is on screen")
        session.push(#"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"4827"}"#)
        await waitUntil("the code") { if case .sas = model.step { true } else { false } }
        model.confirm(false, answering: try XCTUnwrap(model.question))
        XCTAssertEqual(session.sent, [#"{"code":"4827","confirm":false,"moves_to_relay":false,"request":""}"#])
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
    /// request changes, and reprints the current one before it waits for
    /// another answer. Every new line asks again, also after Link; an answer
    /// names the question the owner saw (`code`, `moves_to_relay`, `request`)
    /// and goes out only while that question is still on screen.
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
        XCTAssertEqual(model.question, Model.Question(code: "4827", movesToRelay: false, request: "0123456789abcdef"))
        XCTAssertNil(model.relayMoveWarning)
        let drawnOnFirst = try XCTUnwrap(model.question)

        // A changed request before the answer: the new code and warning replace the shown ones.
        model.receive(second)
        XCTAssertEqual(model.step, .sas(code: "1093", phone: "Phone A"))
        XCTAssertEqual(model.relayMoveWarning, Model.relayMoveWarning("Work Mac"))

        // A Link click on the first line that runs after the second arrived answers nothing.
        model.confirm(true, answering: drawnOnFirst)
        XCTAssertTrue(session.sent.isEmpty, "a yes for a request the owner no longer sees")
        XCTAssertEqual(model.step, .sas(code: "1093", phone: "Phone A"))

        // An identical reprint while asking changes nothing and sends nothing.
        model.receive(second)
        XCTAssertEqual(model.step, .sas(code: "1093", phone: "Phone A"))
        XCTAssertEqual(model.relayMoveWarning, Model.relayMoveWarning("Work Mac"))
        XCTAssertTrue(session.sent.isEmpty)

        // A double click: one answer.
        let drawnOnSecond = try XCTUnwrap(model.question)
        model.confirm(true, answering: drawnOnSecond)
        model.confirm(true, answering: drawnOnSecond)
        XCTAssertEqual(session.sent, [secondYes], "the answer names the line on screen, once")
        XCTAssertEqual(model.step, .waiting)

        // A reprint of the request just answered: that answer is still on its way, keep waiting.
        model.receive(second)
        XCTAssertEqual(model.step, .waiting)
        XCTAssertNil(model.relayMoveWarning)
        XCTAssertEqual(session.sent, [secondYes])

        // The request changed after Link (code_changed): the new line asks
        // again with its own values. Not a failure.
        model.receive(first)
        XCTAssertEqual(model.step, .sas(code: "4827", phone: "Phone A"))
        XCTAssertNil(model.relayMoveWarning, "the newest line moves nothing")
        model.confirm(true, answering: try XCTUnwrap(model.question))
        XCTAssertEqual(session.sent, [secondYes, firstYes])

        // Refuse follows the same rule: a stale no sends nothing; the shown one carries the keys.
        model.receive(second)
        let refuseDrawn = try XCTUnwrap(model.question)
        model.receive(first.replacingOccurrences(of: "Phone A", with: "Phone A (renamed)"))
        XCTAssertEqual(model.step, .sas(code: "4827", phone: "Phone A (renamed)"), "a new name shows")
        model.confirm(false, answering: refuseDrawn)
        XCTAssertEqual(session.sent.count, 2, "a no for a request the owner no longer sees")
        model.confirm(false, answering: try XCTUnwrap(model.question))
        XCTAssertEqual(
            session.sent.last, #"{"code":"4827","confirm":false,"moves_to_relay":false,"request":"0123456789abcdef"}"#,
            "a no carries the keys too"
        )

        model.receive(#"{"event":"refused","reason":"not_confirmed"}"#)
        XCTAssertEqual(model.step, .refused("not_confirmed"))
        XCTAssertNil(model.question)
        XCTAssertNil(model.relayMoveWarning)
    }

    /// Only a reprint of exactly the answered question keeps waiting: a new
    /// code or a changed warning under the same request id asks again.
    func testAChangedLineUnderTheAnsweredRequestAsksAgain() async throws {
        let streamer = FakePairStreamer()
        let model = Model(streamer: streamer, macName: "Work Mac", now: { self.start }, sleep: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        await model.start()
        let session = try XCTUnwrap(streamer.sessions.first)
        func line(_ code: String, moves: Bool) -> String {
            #"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"\#(code)","moves_to_relay":\#(moves),"request":"0123456789abcdef"}"#
        }

        model.receive(line("4827", moves: false))
        model.confirm(true, answering: try XCTUnwrap(model.question))
        model.receive(line("4827", moves: false))
        XCTAssertEqual(model.step, .waiting, "the same question: keep waiting")

        model.receive(line("5310", moves: false))
        XCTAssertEqual(model.step, .sas(code: "5310", phone: "Phone A"), "a new code under the same id asks again")
        XCTAssertNil(model.relayMoveWarning)
        model.confirm(true, answering: try XCTUnwrap(model.question))
        XCTAssertEqual(model.step, .waiting)

        model.receive(line("5310", moves: true))
        XCTAssertEqual(model.step, .sas(code: "5310", phone: "Phone A"), "a changed move under the same id asks again")
        XCTAssertEqual(model.relayMoveWarning, Model.relayMoveWarning("Work Mac"))
        model.confirm(true, answering: try XCTUnwrap(model.question))
        XCTAssertEqual(session.sent, [
            #"{"code":"4827","confirm":true,"moves_to_relay":false,"request":"0123456789abcdef"}"#,
            #"{"code":"5310","confirm":true,"moves_to_relay":false,"request":"0123456789abcdef"}"#,
            #"{"code":"5310","confirm":true,"moves_to_relay":true,"request":"0123456789abcdef"}"#
        ])
    }

    /// A new CLI on an older hub prints `"request":""`. The answer stays a
    /// valid line with an empty `request`; a reprint after it asks again (no
    /// id ties it to the answer), and the CLI's "out of date" failure shows
    /// as a failure with its text.
    func testAnEmptyRequestStillAnswersAndAnOldHubFailsWithItsText() async throws {
        let streamer = FakePairStreamer()
        let model = makeModel(streamer, clock: Clock(start))
        await model.start()
        let session = try XCTUnwrap(streamer.sessions.first)
        let line = #"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"4827","moves_to_relay":true,"request":""}"#
        let yes = #"{"code":"4827","confirm":true,"moves_to_relay":true,"request":""}"#

        model.receive(line)
        model.confirm(true, answering: try XCTUnwrap(model.question))
        XCTAssertEqual(session.sent, [yes])
        let decoded = try JSONSerialization.jsonObject(with: Data(yes.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["request"] as? String, "", "a valid JSON line")

        model.receive(line)
        XCTAssertEqual(model.step, .sas(code: "4827", phone: "Phone A"), "no request id: the reprint asks again")
        model.confirm(true, answering: try XCTUnwrap(model.question))
        XCTAssertEqual(session.sent, [yes, yes])

        let stderr = "Error: the hub is out of date: restart Watchtower, then link again\n"
        session.failureText = MobileHubCLI.reason(CLIRunnerError.nonZeroExit(code: 1, stderr: stderr))
        session.end()
        await waitUntil("failed") { if case .failed = model.step { true } else { false } }
        XCTAssertEqual(model.step, .failed("The hub is out of date: restart Watchtower, then link again."))
    }

    /// The answer line is built by hand: every string is escaped, so any
    /// code or request still makes one valid JSON line.
    func testTheAnswerLineEscapesItsStrings() throws {
        let odd = Model.Question(code: "12\"3\\4", movesToRelay: false, request: "a\nb\u{1}")
        let text = Model.answerLine(confirm: true, odd)
        XCTAssertFalse(text.contains("\n"), "one line")
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["code"] as? String, odd.code)
        XCTAssertEqual(decoded["request"] as? String, odd.request)
        XCTAssertEqual(decoded["confirm"] as? Bool, true)
        XCTAssertEqual(decoded["moves_to_relay"] as? Bool, false)
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
