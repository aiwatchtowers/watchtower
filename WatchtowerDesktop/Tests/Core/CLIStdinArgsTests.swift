import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// #604 S6: every Desktop service that hands the CLI free text passes `-`
/// and sends the text on stdin; nothing lands in the temp directory.
final class CLIStdinArgsTests: XCTestCase {
    private func newTempEntries(_ body: () async throws -> Void) async throws -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory.path
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tmp))
        try await body()
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tmp))
        return after.subtracting(before).filter { name in StaleTempSweep.prefixes.contains { name.hasPrefix($0) } }
    }

    func testEveryTextServiceSendsItsTextOnStdin() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"topics":[],"notes":"","extracted":[],"omitted_count":0}"#.utf8))
        let created = try await newTempEntries {
            try await MeetingRecapService(runner: runner).generate(eventID: "e1", text: "recap text")
            _ = try await MeetingTopicsExtractService(runner: runner).extract(text: "topics text")
            _ = try? await TrackComposeService(runner: runner).compose(text: "track text")
            try await AutomationsCLI(runner: runner).trackInstruction(7, text: "instruction text")
        }
        XCTAssertEqual(created, [], "no text file is written")
        for args in runner.invocations {
            let flag = try XCTUnwrap(args.firstIndex(of: "--text-file"), "\(args)")
            XCTAssertEqual(args[flag + 1], "-", "\(args)")
        }
        XCTAssertEqual(runner.stdinInputs.map { String(bytes: $0, encoding: .utf8) },
                       ["recap text", "topics text", "track text", "instruction text"])
    }
}
