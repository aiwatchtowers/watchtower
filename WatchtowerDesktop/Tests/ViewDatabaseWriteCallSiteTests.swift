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
    /// point called with a closure or an argument — never `write(to:)`,
    /// `write(toFile:)`, `write(contentsOf:)` or `write(from:)`, a file,
    /// pipe or audio-file write.
    /// `try await …` never matches: `await` is followed by a space.
    private static let syncWrite = #"\btry[?!]?\s+(\([^()]*\)\s*)?[\w.?]*\."#
        + #"(write|writeWithoutTransaction|writeInTransaction|barrierWriteWithoutTransaction|inTransaction|inDatabase)"#
        + #"\s*(\{|\((?!to:|toFile:|contentsOf:|from:))"#

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
            "try db.dbPool.barrierWriteWithoutTransaction { db in",
            "try queue.inTransaction(.immediate) { db in",
            "try pool.inDatabase { db in"
        ]
        let allowed = [
            "try await db.dbPool.write { conn in",
            "_ = try await db.dbPool.write { conn in",
            "await ViewWrite.run(db.dbPool, pending: $isSaving, { conn in",
            "try file.contents.write(to: url, atomically: true, encoding: .utf8)",
            "try content.write(toFile: path, atomically: true, encoding: .utf8)",
            "try stdin.write(contentsOf: Data(line.utf8))",
            "try audioFile.write(from: outBuffer)",
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
        let (scanned, _) = try scan(Self.sources.appendingPathComponent("Views")) { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(scanned, 50, "the scan found too few views: wrong path?")
    }

    /// Board #670: the centers (`*Center.swift`, `*Center+….swift` anywhere
    /// under Sources) and `CodeQuestionSurface`, whose writes the code
    /// question center makes, are main-actor code too.
    func testNoSynchronousDatabaseWriteInCenters() throws {
        let (scanned, exempted) = try scan(Self.sources) { url in
            let name = url.deletingPathExtension().lastPathComponent
            return url.pathExtension == "swift"
                && (name.hasSuffix("Center") || name.contains("Center+") || name == "CodeQuestionSurface")
        }
        XCTAssertGreaterThan(scanned, 30, "the scan found too few centers: wrong path?")
        XCTAssertEqual(exempted, Self.offMainWrites.count,
                       "each exemption names exactly one line that is still there; drop one whose write moved")
    }

    /// Board #670 phase 2: the view models under `Sources/ViewModels/` and
    /// `DatabaseManager` (whose star toggles the Digests and People screens
    /// call) are main-actor code too — every one of them, since phase 2b
    /// moved the last four (targets, target assistant tabs, main chat,
    /// workbench board) and the synchronous contracts behind them (the
    /// embedded chat engine's `postTurn`, `TargetActionExecutor`, the brief
    /// center's chat factory) to awaited writes.
    func testNoSynchronousDatabaseWriteInViewModels() throws {
        let (scanned, _) = try scan(Self.sources.appendingPathComponent("ViewModels")) { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(scanned, 40, "the scan found too few view models: wrong path?")
        let (manager, _) = try scan(Self.sources.appendingPathComponent("Database")) {
            $0.lastPathComponent == "DatabaseManager.swift"
        }
        XCTAssertEqual(manager, 1, "DatabaseManager.swift moved: point the scan at it")
    }

    /// Board #670 phase 2b-2: the stores the chats write through — the main
    /// chat's turn store and session client, the embedded chats' store and
    /// engine, attachments, artifact panels and comments, the surfaces that
    /// create a chat's conversation — and the Inbox action strip.
    func testNoSynchronousDatabaseWriteInChatStores() throws {
        let folders = ["WatchtowerCore/Services/Chat", "Services/Chat", "Services/ChatSurfaces"]
        var total = 0
        for folder in folders {
            let (scanned, _) = try scan(Self.sources.appendingPathComponent(folder)) { $0.pathExtension == "swift" }
            XCTAssertGreaterThan(scanned, 0, "\(folder): nothing scanned, wrong path?")
            total += scanned
        }
        XCTAssertGreaterThan(total, 40, "the scan found too few chat files: wrong path?")
        let named: Set = ["ActionStripViewModel.swift", "EmbeddedChatWiring.swift"]
        let (single, _) = try scan(Self.sources) { named.contains($0.lastPathComponent) }
        XCTAssertEqual(single, named.count, "a named file moved: point the scan at it")
    }

    /// The mobile hub's ledger is exempt (owner decision, ask #368): every
    /// synchronous write in `HubSyncState*.swift` goes through its `queue`,
    /// the hub's private sidecar database (`MobileHub/hubstate.db`). Only the
    /// Desktop writes that file — never the daemon, a hook or the CLI — so no
    /// other process can hold its write lock and the busy wait #590 is about
    /// cannot happen there. The exemption covers that receiver in those
    /// files only: a write to any other handle there (the shared workspace
    /// database included) still fails, and the sidecar must stay its own
    /// file.
    func testTheMobileHubSidecarIsTheOnlyExemptWriter() throws {
        let hub = Self.sources.appendingPathComponent("Services/MobileHub")
        let write = try NSRegularExpression(pattern: Self.syncWrite)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: hub, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("HubSyncState") {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                guard let match = write.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range, in: line) else { continue }
                let call = String(line[range])
                XCTAssertTrue(Self.isSidecarWrite(call),
                              "\(url.lastPathComponent):\(index + 1) writes another handle than the sidecar `queue`")
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 3, "the HubSyncState files moved: point the exemption at them")
        let state = try String(contentsOf: hub.appendingPathComponent("HubSyncState.swift"), encoding: .utf8)
        XCTAssertTrue(state.contains("let queue: DatabaseQueue"), "the sidecar is the hub's own DatabaseQueue")
        let service = try String(contentsOf: hub.appendingPathComponent("MobileHubService.swift"), encoding: .utf8)
        XCTAssertTrue(service.contains(#"HubSyncState(path: dir.appendingPathComponent("hubstate.db").path)"#),
                      "the sidecar is its own file, never the workspace database")
    }

    /// Board #670 is complete: no file under `Sources/` writes the database
    /// synchronously, apart from the named exemptions — `offMainWrites`,
    /// `otherExemptWrites` and the mobile hub's sidecar `queue` (see
    /// `testTheMobileHubSidecarIsTheOnlyExemptWriter`). A new synchronous
    /// write anywhere, a Queries helper's included, fails here.
    func testNoSynchronousDatabaseWriteAnywhereInSources() throws {
        let write = try NSRegularExpression(pattern: Self.syncWrite)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var exempted: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let name = url.lastPathComponent
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"),
                      let match = write.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range, in: line) else { continue }
                if Self.offMainWrites[name] == code || Self.otherExemptWrites[name] == code {
                    exempted.insert(name)
                    continue
                }
                // The hub sidecar's own handle; its own test pins the rest.
                if name.hasPrefix("HubSyncState"), Self.isSidecarWrite(String(line[range])) { continue }
                XCTFail("\(name):\(index + 1) writes the database synchronously; await the writer instead")
            }
        }
        XCTAssertGreaterThan(scanned, 500, "the scan found too few files: wrong path?")
        XCTAssertEqual(exempted, Set(Self.offMainWrites.keys).union(Self.otherExemptWrites.keys),
                       "each exemption names exactly one line that is still there; drop one whose write moved")
    }

    /// A hub ledger write through the sidecar: its `queue`, or a nested
    /// `db.inTransaction` inside one of that queue's writes.
    private static func isSidecarWrite(_ call: String) -> Bool {
        call.contains(" queue.") || call.contains(" db.inTransaction")
    }

    /// Synchronous-looking writes that never run on the main actor, by file
    /// and exact line, each with its reason:
    /// - `PermissionRequestSlice.expire`: called only from
    ///   `SlicePublisher.publishOnce`, a nonisolated `async` method of a
    ///   non-actor class, so it runs on the cooperative pool, never the main
    ///   thread (it writes the shared database's `permission_requests`).
    /// - `BoardHandlers`: `field.write(db, …)` is the board field's own
    ///   setter, called inside `try await dbPool.write`, not a GRDB write.
    private static let otherExemptWrites: [String: String] = [
        "PermissionRequestSlice.swift": "let expired = try writer.write { db in",
        "BoardHandlers.swift": "return .wrote(try field.write(db, targetID, value))"
    ]

    /// The one synchronous write that never runs on the main thread, by
    /// file and its exact line: `OwnerPresenceCenter.databaseWriter`'s
    /// closure, which the center only calls on its own serial `writes`
    /// queue (the quit path waits at most `quitWait` for it). Any other
    /// write in that file is still caught.
    private static let offMainWrites: [String: String] = [
        "OwnerPresenceCenter.swift": "try dbPool.write { try OwnerPresenceQueries.upsert($0, sessionID: sessionID, at: at) }"
    ]

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources")

    /// Fails on every synchronous write in the matching files under
    /// `folder`; returns how many files it read and how many exempted
    /// lines it met.
    private func scan(_ folder: URL, _ include: (URL) -> Bool) throws -> (scanned: Int, exempted: Int) {
        let write = try NSRegularExpression(pattern: Self.syncWrite)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var scanned = 0
        var exempted = 0
        for case let url as URL in enumerator where include(url) {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if Self.offMainWrites[url.lastPathComponent] == code {
                    exempted += 1
                    continue
                }
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(write.firstMatch(in: line, range: range),
                             "\(url.lastPathComponent):\(index + 1) writes the database on the main thread; "
                                 + "use `ViewWrite.run` or `try await dbPool.write { … }`")
            }
        }
        return (scanned, exempted)
    }
}
