import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The recording header's Private toggle and Export runs
/// (docs/features/private-meetings.md): state keyed by recording on AppState,
/// a file written by the app (not the CLI child), failures and the success
/// line kept until the owner looks.
@MainActor
final class RecordingActionsCenterTests: XCTestCase {

    private var copied: [String] = []

    private func makeCenter(noticeLifetime: Duration = .seconds(60)) -> RecordingActionsCenter {
        RecordingActionsCenter(noticeLifetime: noticeLifetime) { [weak self] in self?.copied.append($0) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func tempURL(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    func testSaveWritesTheCLIRenderingFromTheApp() async throws {
        let center = makeCenter()
        let runner = FakeCLIRunner(stdout: Data("# Weekly sync\n".utf8))
        let url = try tempURL("Weekly sync.md")

        center.save(transcriptID: 5, format: .md, to: url, service: TranscriptSaveService(runner: runner))
        XCTAssertTrue(center.exporting.contains(5), "the busy flag is set at once, on AppState")
        await waitUntil { !center.exporting.contains(5) }

        XCTAssertEqual(runner.invocations, [["meeting-prep", "transcript", "export", "5", "--format", "md"]],
                       "the CLI renders to stdout; it is never handed the destination")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Weekly sync\n")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600, "readable by the owner only")
        XCTAssertEqual(center.notice[5], "Saved to Weekly sync.md")
        XCTAssertNil(center.lastError[5])
    }

    func testSaveFailureIsKeptForTheRecordingAndWritesNothing() async throws {
        let center = makeCenter()
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "no timed segments"))
        let url = try tempURL("x.srt")

        center.save(transcriptID: 5, format: .srt, to: url, service: TranscriptSaveService(runner: runner))
        await waitUntil { !center.exporting.contains(5) }

        XCTAssertNotNil(center.lastError[5])
        XCTAssertTrue(center.lastError[5]?.hasPrefix("Export failed: ") == true)
        XCTAssertNil(center.notice[5])
        XCTAssertNil(center.lastError[6], "another recording shows nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCopyPutsTheTextOnThePasteboardAndConfirms() async {
        let center = makeCenter()
        let runner = FakeCLIRunner(stdout: Data("[00:00:01] Speaker 1: hi\n".utf8))

        center.copyTranscript(transcriptID: 5, service: TranscriptSaveService(runner: runner))
        await waitUntil { !center.exporting.contains(5) }

        XCTAssertEqual(runner.invocations.first, ["meeting-prep", "transcript", "export", "5", "--format", "txt"])
        XCTAssertEqual(copied, ["[00:00:01] Speaker 1: hi\n"])
        XCTAssertEqual(center.notice[5], "Copied the transcript")
    }

    func testCopyOfNonTextFailsWithoutTouchingThePasteboard() async {
        let center = makeCenter()
        let notText = TranscriptSaveService(runner: FakeCLIRunner(stdout: Data([0xFF, 0xFE])))
        center.copyTranscript(transcriptID: 5, service: notText)
        await waitUntil { !center.exporting.contains(5) }

        XCTAssertEqual(copied, [])
        XCTAssertEqual(center.lastError[5], "Couldn't copy the transcript: the export was not text")
    }

    func testNoticeExpires() async {
        let center = makeCenter(noticeLifetime: .milliseconds(20))
        let service = TranscriptSaveService(runner: FakeCLIRunner(stdout: Data("x".utf8)))
        center.copyTranscript(transcriptID: 5, service: service)
        await waitUntil { center.notice[5] != nil }
        await waitUntil { center.notice[5] == nil }
    }

    func testSetPrivateReportsTheCLIFlag() async {
        let center = makeCenter()
        let runner = FakeCLIRunner(stdout: Data(#"{"id":5,"private":true}"#.utf8))
        let done = expectation(description: "changed")
        var reported: [Bool] = []

        center.setPrivate(transcriptID: 5, true, service: TranscriptSaveService(runner: runner)) {
            reported.append($0)
            done.fulfill()
        }
        XCTAssertTrue(center.changingPrivate.contains(5))
        center.setPrivate(transcriptID: 5, false, service: TranscriptSaveService(runner: runner)) { _ in
            XCTFail("a second change of the same recording while one runs is ignored")
        }
        await fulfillment(of: [done], timeout: 5)
        await waitUntil { !center.changingPrivate.contains(5) }

        XCTAssertEqual(reported, [true])
        XCTAssertEqual(runner.invocations, [["meeting-prep", "transcript", "private", "5", "on"]])
        XCTAssertNil(center.lastError[5])
    }

    func testSetPrivateFailureIsKeptAndReportsNoChange() async {
        let center = makeCenter()
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))

        center.setPrivate(transcriptID: 5, true, service: TranscriptSaveService(runner: runner)) { _ in
            XCTFail("no change landed")
        }
        await waitUntil { !center.changingPrivate.contains(5) }

        XCTAssertTrue(center.lastError[5]?.hasPrefix("Couldn't change Private: ") == true)
    }
}
