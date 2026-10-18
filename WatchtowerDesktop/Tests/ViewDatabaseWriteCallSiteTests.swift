import XCTest

/// Board #590: no view writes the database synchronously. A view's code runs
/// on the main thread, and a synchronous GRDB write there waits out another
/// process's write lock in the busy callback (up to 5 s) with the UI frozen.
/// Views take `ViewWrite.run` or `try await dbPool.write { … }`, which wait
/// on the writer queue.
final class ViewDatabaseWriteCallSiteTests: XCTestCase {
    /// `try` / `try?` / `try!`, an optional parenthesised receiver
    /// (`(db ?? other).write`), a dotted receiver with optional chaining
    /// (`appState.databaseManager?.dbPool.write`), then a GRDB write entry
    /// point called with a closure or an argument — never `write(to:)`, a
    /// file write. `try await …` never matches: `await` is followed by a space.
    private static let syncWrite = #"\btry[?!]?\s+(\([^()]*\)\s*)?[\w.?]*\."#
        + #"(write|writeWithoutTransaction|writeInTransaction|barrierWriteWithoutTransaction)"#
        + #"\s*(\{|\((?!to:))"#

    func testThePatternCatchesEverySynchronousWriteShape() throws {
        let write = try NSRegularExpression(pattern: Self.syncWrite)
        let caught = [
            "try db.dbPool.write { conn in",
            "_ = try db.dbPool.write { conn in",
            "try? dbPool.write { db in try X.markRead(db) }",
            "let id = try! pool.write(body)",
            "try appState.databaseManager?.dbPool.write { db in",
            "try (manager ?? fallback).dbPool.write { db in",
            "try (pool).write { db in",
            "try db.dbPool.writeWithoutTransaction { db in",
            "try writer.writeInTransaction { db in",
            "try db.dbPool.barrierWriteWithoutTransaction { db in"
        ]
        let allowed = [
            "try await db.dbPool.write { conn in",
            "_ = try await db.dbPool.write { conn in",
            "await ViewWrite.run(db.dbPool, pending: $isSaving, { conn in",
            "try file.contents.write(to: url, atomically: true, encoding: .utf8)",
            "try db.dbPool.read { conn in"
        ]
        for line in caught {
            XCTAssertNotNil(write.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
        for line in allowed {
            XCTAssertNil(write.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
    }

    func testNoSynchronousDatabaseWriteInViews() throws {
        let scanned = try scan(Self.sources.appendingPathComponent("Views")) { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(scanned, 50, "the scan found too few views: wrong path?")
    }

    /// Board #670: the centers (`*Center.swift`, `*Center+….swift` anywhere
    /// under Sources) and `CodeQuestionSurface`, whose writes the code
    /// question center makes, are main-actor code too.
    func testNoSynchronousDatabaseWriteInCenters() throws {
        let scanned = try scan(Self.sources) { url in
            let name = url.deletingPathExtension().lastPathComponent
            return url.pathExtension == "swift"
                && (name.hasSuffix("Center") || name.contains("Center+") || name == "CodeQuestionSurface")
        }
        XCTAssertGreaterThan(scanned, 30, "the scan found too few centers: wrong path?")
    }

    /// Writes that already run off the main thread: `OwnerPresenceCenter`'s
    /// writer is only called on its own serial `writes` queue.
    private static let offMainWrites: [String: String] = [
        "OwnerPresenceCenter.swift": "OwnerPresenceQueries.upsert"
    ]

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources")

    /// Fails on every synchronous write in the matching files under
    /// `folder`; returns how many files it read.
    private func scan(_ folder: URL, _ include: (URL) -> Bool) throws -> Int {
        let write = try NSRegularExpression(pattern: Self.syncWrite)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where include(url) {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if let allowed = Self.offMainWrites[url.lastPathComponent], code.contains(allowed) { continue }
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(write.firstMatch(in: line, range: range),
                             "\(url.lastPathComponent):\(index + 1) writes the database on the main thread; "
                                 + "use `ViewWrite.run` or `try await dbPool.write { … }`")
            }
        }
        return scanned
    }
}
