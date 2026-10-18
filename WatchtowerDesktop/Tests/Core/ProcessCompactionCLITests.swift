import Foundation
@testable import WatchtowerCore
import XCTest

/// `ProcessCompactionCLI` over a real child: a `/bin/sh` stub stands in for
/// the `watchtower` binary.
final class ProcessCompactionCLITests: XCTestCase {
    private var directory: URL?
    private var child: (any CompactionChild)?

    override func tearDown() async throws {
        // A child the test left running is killed and reaped.
        if let child {
            child.kill()
            _ = await child.waitForExit()
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A preamble line before the JSON and a non-zero exit (2: disk) come
    /// through as the exit status and a decodable last line.
    func testStartCompactReadsResultAfterPreambleAndExitStatus() async throws {
        let stub = try makeStub("""
        #!/bin/sh
        echo "schema format upgraded"
        echo '{"compacted":false,"skipped":"disk"}'
        exit 2
        """)
        let child = try ProcessCompactionCLI(executablePath: stub).startCompact()
        self.child = child

        let exit = await child.waitForExit()
        XCTAssertEqual(exit.status, 2)
        let output = try decodeLastJSONLine(CompactionRunOutput.self, from: exit.stdout)
        XCTAssertFalse(output.compacted)
        XCTAssertEqual(output.skipped, "disk")
    }

    private func makeStub(_ script: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessCompactionCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let stub = directory.appendingPathComponent("watchtower")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }
}
