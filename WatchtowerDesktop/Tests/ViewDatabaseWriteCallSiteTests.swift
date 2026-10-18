import XCTest

/// Board #590: no view writes the database synchronously. A view's code runs
/// on the main thread, and a synchronous GRDB write there waits out another
/// process's write lock in the busy callback (up to 5 s) with the UI frozen.
/// Views take `try await dbPool.write { … }`, which waits on the writer queue.
final class ViewDatabaseWriteCallSiteTests: XCTestCase {
    func testNoSynchronousDatabaseWriteInViews() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources/Views")
        // `dbPool.write {`, `db.write(body)`, `writeWithoutTransaction {` …;
        // not a file write (`text.write(to: url, …)`).
        let write = try NSRegularExpression(pattern: #"\btry[?!]?\s+[\w.]*\.write(WithoutTransaction)?\s*(\{|\((?!to:))"#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(write.firstMatch(in: line, range: range),
                             "\(url.lastPathComponent):\(index + 1) writes the database on the main thread; "
                                 + "use `try await dbPool.write { … }`")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan found too few views: wrong path?")
    }
}
