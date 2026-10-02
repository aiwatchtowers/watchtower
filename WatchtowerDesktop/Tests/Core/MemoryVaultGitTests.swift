import Foundation
import Testing
@testable import WatchtowerCore

@Suite("MemoryVaultGit")
struct MemoryVaultGitTests {
    /// A git failure still degrades to an empty history, but its stderr is
    /// reported instead of vanishing.
    @Test("a failing git log reports its stderr and returns no commits")
    func failureIsReported() async throws {
        let notARepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepo) }
        let reports = Reports()

        let commits = await MemoryVaultGit.log(vault: notARepo, path: nil) { reports.add($0) }

        #expect(commits.isEmpty)
        let line = try #require(reports.all.first)
        #expect(line.contains("not a git repository"))
        #expect(line.contains("exit 128"))
    }
}

/// Collects report lines from any thread.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
