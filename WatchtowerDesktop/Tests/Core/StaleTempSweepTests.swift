import XCTest
@testable import WatchtowerCore

/// The launch sweep of the temp files older versions handed text to the CLI
/// through (#604 S6/S7).
final class StaleTempSweepTests: XCTestCase {
    func testOldPrefixedFilesAndDirectoriesGoFreshOnesStay() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("stale-sweep-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let now = Date()
        let old = now.addingTimeInterval(-700)
        func make(_ name: String, at date: Date, directory: Bool = false) throws -> URL {
            let url = dir.appendingPathComponent(name)
            if directory {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: url)
            }
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let gone = try StaleTempSweep.prefixes.map { try make("\($0)a.txt", at: old) }
            + [try make("watchtower-automation-1", at: old, directory: true),
               try make("dictation-\(UUID().uuidString).txt", at: old)]
        let kept = [try make("watchtower-text-fresh.txt", at: now), try make("other-old.txt", at: old),
                    try make("dictation-notes.txt", at: old), try make("dictation-\(UUID().uuidString).wav", at: old)]

        let removed = StaleTempSweep.run(in: dir, now: now)

        XCTAssertEqual(removed, gone.count)
        for url in gone { XCTAssertFalse(fm.fileExists(atPath: url.path), url.lastPathComponent) }
        for url in kept { XCTAssertTrue(fm.fileExists(atPath: url.path), url.lastPathComponent) }
    }
}
