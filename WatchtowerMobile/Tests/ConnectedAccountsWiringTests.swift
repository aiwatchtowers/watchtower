import GRDB
import XCTest
import WatchtowerKit
@testable import WatchtowerMobile

/// Wiring + projection tests for the Settings "Connected accounts" section:
/// the view model's single observation over the three account slice kinds,
/// and the pure `AccountRow` presentation mapping the rows render.
///
/// The backward-compatibility state carries as much weight as the happy path:
/// an older desktop publishes NO account slices, and the section must then be
/// hidden — `accountSections` empty — not rendered blank.
@MainActor
final class ConnectedAccountsWiringTests: XCTestCase {

    // MARK: - Helpers

    /// Pool-backed store on a throwaway path — the production mechanism the
    /// observation runs against (`ReplicaWiringTests.makePoolStore` twin).
    private func makePoolStore() throws -> ReplicaStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try ReplicaStore(path: dir.appendingPathComponent("replica.sqlite").path)
    }

    private func seed(into store: ReplicaStore) async throws {
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport)
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        _ = try await hydrator.hydrateOnce()
    }

    private func poll(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool,
        _ message: @autoclosure () -> String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    /// A slice row exactly as the publisher's projection delivers it — only
    /// the columns of the given kind's frozen projection set.
    private func account(_ columns: [String: (any DatabaseValueConvertible)?]) -> ConnectedAccount {
        ConnectedAccount(row: Row(columns))
    }

    // MARK: - View model over the slices

    /// The demo seed's four accounts surface grouped by service in fixed
    /// service order, each group ordered id ASC (the desktop Connections
    /// order), with the health each state maps to.
    func testViewModelGroupsSeededAccountsByService() async throws {
        let store = try makePoolStore()
        try await seed(into: store)

        let model = SettingsViewModel()
        model.start(store: store)
        try await poll { model.accountSections.count == 3 }

        XCTAssertEqual(model.accountSections.map(\.service), [.slack, .google, .jira])

        let slack = model.accountSections[0].rows
        XCTAssertEqual(slack.map(\.id), [1, 2], "desktop order: oldest account first")
        XCTAssertEqual(slack[0].name, "Acme Corp")
        XCTAssertEqual(slack[0].detail, "acme.slack.com")
        XCTAssertEqual(slack[0].health, .ok)
        XCTAssertEqual(slack[1].health, .disabled, "the desktop-disabled workspace renders gray")

        let google = model.accountSections[1].rows
        XCTAssertEqual(google.map(\.name), ["me@example.com"])
        XCTAssertEqual(google[0].health, .attention)
        XCTAssertEqual(google[0].statusText, "Gmail token expired — re-login on your Mac")

        let jira = model.accountSections[2].rows
        XCTAssertEqual(jira.map(\.name), ["Acme Jira"])
        XCTAssertEqual(jira[0].health, .revoked)
    }

    /// Backward compatibility both ways: an empty replica (older desktop)
    /// keeps the section hidden; the first published account reveals it; the
    /// account's deletion (removed on the Mac) hides it again rather than
    /// keeping the last snapshot.
    func testAccountSectionsFollowTheSlice() async throws {
        let store = try makePoolStore()
        let model = SettingsViewModel()
        model.start(store: store)

        XCTAssertTrue(model.accountSections.isEmpty, "no slices yet — the section starts hidden")

        let payload = try RowPayloadCoder.payload(from: Row([
            "id": 1, "team_name": "Acme Corp", "team_domain": "acme",
            "label": "", "status": "ok", "error": "", "enabled": true,
        ]))
        try store.apply(CloudChangeBatch(
            changed: [CloudRecord(
                recordName: SliceKind.slackAccount.recordName(id: "1"),
                zone: .data,
                kind: SliceKind.slackAccount.rawValue,
                modifiedAt: Date(),
                payload: payload
            )],
            deletedRecordNames: [],
            newToken: CloudChangeToken(value: 1)
        ))
        try await poll { model.accountSections.count == 1 }
        XCTAssertEqual(model.accountSections[0].service, .slack)

        try store.apply(CloudChangeBatch(
            changed: [],
            deletedRecordNames: [SliceKind.slackAccount.recordName(id: "1")],
            newToken: CloudChangeToken(value: 2)
        ))
        try await poll { model.accountSections.isEmpty }
    }

    // MARK: - Row projection (badge semantics — desktop Connections parity)

    func testHealthyEnabledAccountIsGreenWithNoInlineStatus() {
        let row = AccountRow(account([
            "id": 1, "team_name": "Acme Corp", "team_domain": "acme",
            "label": "", "status": "ok", "error": "", "enabled": true,
        ]))
        XCTAssertEqual(row.health, .ok)
        XCTAssertEqual(row.statusText, "Connected")
        XCTAssertEqual(row.name, "Acme Corp")
        XCTAssertEqual(row.detail, "acme.slack.com")
    }

    /// Disabled wins over any status: the desktop rolls a disabled account
    /// into neither ok nor problem, because its status is not actively
    /// verified while it isn't syncing — even a stale 'error' must not paint
    /// the row orange.
    func testDisabledAccountIsGrayEvenWhenItsLastStatusWasBad() {
        let row = AccountRow(account([
            "id": 2, "team_name": "Old Corp", "team_domain": "",
            "label": "", "status": "error", "error": "stale failure", "enabled": false,
        ]))
        XCTAssertEqual(row.health, .disabled)
        XCTAssertEqual(row.statusText, "Disabled on your Mac")
    }

    func testRevokedAccountIsRedAndErrorTextFallsBackToStatusWord() {
        let withError = AccountRow(account([
            "id": 3, "site_name": "Acme Jira", "site_url": "https://acme.atlassian.net",
            "label": "", "status": "revoked", "error": "consent withdrawn", "enabled": true,
        ]))
        XCTAssertEqual(withError.health, .revoked)
        XCTAssertEqual(withError.statusText, "consent withdrawn")

        let bare = AccountRow(account([
            "id": 3, "site_name": "Acme Jira", "site_url": "",
            "label": "", "status": "revoked", "error": "", "enabled": true,
        ]))
        XCTAssertEqual(bare.statusText, "revoked", "no error text — the raw status word is shown")
    }

    /// Valid-but-degenerate status: a word this app version has never heard
    /// of (a future desktop's new state) must degrade to "needs attention",
    /// not crash or render green.
    func testUnknownStatusDegradesToAttention() {
        let row = AccountRow(account([
            "id": 4, "email": "me@example.com", "label": "",
            "status": "rate_limited", "error": "", "enabled": true,
        ]))
        XCTAssertEqual(row.health, .attention)
        XCTAssertEqual(row.statusText, "rate_limited")
    }

    /// Google payloads carry no `enabled` column (that service has no
    /// per-account toggle) — the row must read enabled, never gray.
    func testGoogleAccountWithoutEnabledColumnIsNotDisabled() {
        let row = AccountRow(account([
            "id": 1, "email": "me@example.com", "label": "",
            "status": "ok", "error": "", "calendar_enabled": true, "gmail_enabled": false,
        ]))
        XCTAssertEqual(row.health, .ok)
        XCTAssertNil(row.detail, "the email IS the primary line — no redundant detail")
    }
}
