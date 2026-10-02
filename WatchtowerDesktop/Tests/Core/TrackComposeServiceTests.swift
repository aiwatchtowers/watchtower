import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

final class TrackComposeServiceTests: XCTestCase {
    func testComposeShipsTextAsAFileAndDecodesTheDraft() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"title": "Release watch", "instruction": "Watch the release"}"#.utf8))
        let service = TrackComposeService(runner: runner)

        let draft = try await service.compose(text: "watch the -- release", targetID: 7)

        XCTAssertEqual(draft.title, "Release watch")
        let args = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(Array(args.prefix(3)), ["tracks", "create", "--text-file"])
        XCTAssertEqual(Array(args.suffix(2)), ["--target", "7"])
        XCTAssertFalse(args.contains("watch the -- release"), "pasted text never rides argv")
        XCTAssertEqual(runner.textFileContents, ["watch the -- release"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: args[3]), "the temp file is removed after the call")
    }

    func testTextFileIsRemovedWhenTheRunThrows() async {
        let runner = FakeCLIRunner(error: CocoaError(.fileReadUnknown))
        let service = TrackComposeService(runner: runner)

        do {
            _ = try await service.compose(text: "x")
            XCTFail("expected the runner's error")
        } catch {}

        let path = runner.invocations.first?[3] ?? ""
        XCTAssertFalse(path.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
