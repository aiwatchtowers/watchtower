import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A review round's line (board #328) goes through the same PROJ-12 gates as
/// an answered ask: pasted without Return unless the session's hooks vouch
/// for this run.
@MainActor
final class SessionLineDeliveryReviewTests: XCTestCase {
    private var sessions: [FakeTerminalSession] = []
    private var folder: URL!
    private var center: TerminalCenter!
    private var delivery: SessionLineDelivery!
    private var sessionID: Int64 = 0

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt review \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessions = []
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let session = FakeTerminalSession()
                self?.sessions.append(session)
                return session
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
        delivery = SessionLineDelivery(terminalCenter: center)
        delivery.refreshStates = { true }
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let acme = folder.path
        let session = try await pool.write { db -> TerminalSession in
            let project = try TestDatabase.insertWorkbench(db, folder: acme)
            return try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: .claude, title: "s", folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        center.start(session, fresh: true)
        sessionID = session.id
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    func testReviewLineWithoutHookStateIsTypedNotSubmitted() async {
        delivery.hasHookState = { _ in false }
        let line = ReviewDeliveryLine.line(roundID: 7, comments: 2)
        let result = await delivery.deliverLine(line, key: .review(7), sessionID: sessionID) { _ in }
        XCTAssertEqual(result, .typed)
        XCTAssertFalse(sessions[0].inputs.contains([0x0D]), "no Return without hook state")
    }

    func testReviewLineWithHooksIsSubmitted() async {
        delivery.hasHookState = { _ in true }
        let line = ReviewDeliveryLine.line(roundID: 7, comments: 2)
        let result = await delivery.deliverLine(line, key: .review(7), sessionID: sessionID) { _ in }
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(sessions[0].inputs.last, [0x0D])
    }

    func testReviewLineIsHeldWhileAPermissionPromptShows() async {
        delivery.needsApproval = { _ in true }
        let result = await delivery.deliverLine("x", key: .review(7), sessionID: sessionID) { _ in }
        XCTAssertEqual(result, .held)
        XCTAssertTrue(sessions[0].inputs.isEmpty)
        XCTAssertEqual(delivery.heldKeys(sessionID: sessionID), [.review(7)])
    }

    func testOnlyPhoneInputKeepsFormatCharacters() {
        XCTAssertTrue(SessionLineDelivery.LineKey.input("a").keepsFormatCharacters)
        XCTAssertFalse(SessionLineDelivery.LineKey.ask(1).keepsFormatCharacters)
        XCTAssertFalse(SessionLineDelivery.LineKey.review(1).keepsFormatCharacters)
    }
}
