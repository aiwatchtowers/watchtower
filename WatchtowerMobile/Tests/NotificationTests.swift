import GRDB
import UserNotifications
import XCTest
import WatchtowerKit
@testable import WatchtowerMobile

/// NotificationCoordinator behavior over a fake UNUserNotificationCenter seam.
///
/// The load-bearing pin is the STORM SUPPRESSION: a new device's initial
/// hydrate pulls historical cloud records that still carry notifyLevel tags —
/// with an EMPTY watermark that must arm the watermark and alert about
/// NOTHING ("the first hydrate is history, not news").
@MainActor
final class NotificationTests: XCTestCase {

    // MARK: - Fake center

    /// Scriptable stand-in for the UNUserNotificationCenter seam: counts
    /// asks, records posted requests. @unchecked Sendable is safe here —
    /// every access in these tests happens on the main actor.
    private final class FakeNotificationCenter: NotificationCentering, @unchecked Sendable {
        var grantOnAsk = true
        var status: UNAuthorizationStatus = .notDetermined
        private(set) var askCount = 0
        private(set) var added: [UNNotificationRequest] = []

        func requestAuthorization() async throws -> Bool {
            askCount += 1
            status = grantOnAsk ? .authorized : .denied
            return grantOnAsk
        }

        func add(_ request: UNNotificationRequest) async throws {
            added.append(request)
        }

        func authorizationStatus() async -> UNAuthorizationStatus {
            status
        }
    }

    // MARK: - Helpers

    private struct Context {
        let coordinator: NotificationCoordinator
        let center: FakeNotificationCenter
        let store: ReplicaStore
        let defaults: UserDefaults
    }

    /// Isolated UserDefaults suite so permission memory can never leak
    /// between tests (or into the host app's standard defaults).
    private func makeDefaults() throws -> UserDefaults {
        let name = "notify-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeContext(
        permission: NotificationPermission? = nil,
        grant: Bool = true
    ) throws -> Context {
        let store = try ReplicaStore.inMemory()
        let center = FakeNotificationCenter()
        center.grantOnAsk = grant
        let defaults = try makeDefaults()
        if let permission {
            defaults.set(permission.rawValue, forKey: NotificationCoordinator.permissionDefaultsKey)
        }
        let coordinator = NotificationCoordinator(store: store, center: center, defaults: defaults)
        return Context(coordinator: coordinator, center: center, store: store, defaults: defaults)
    }

    private func applied(
        _ kind: SliceKind = .inboxItem,
        id: String = "3",
        level: String?,
        at seconds: TimeInterval
    ) -> AppliedSliceRecord {
        AppliedSliceRecord(
            recordName: kind.recordName(id: id),
            kind: kind,
            notifyLevel: level,
            modifiedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    /// Lands a real inbox row in the replica so the urgent alert's snippet
    /// fetch has something to read back.
    private func seedInboxItem(into store: ReplicaStore, id: Int, snippet: String) throws {
        let payload = try RowPayloadCoder.payload(from: Row([
            "id": id,
            "snippet": snippet,
            "status": "pending",
            "priority": "high"
        ]))
        let record = CloudRecord(
            recordName: SliceKind.inboxItem.recordName(id: String(id)),
            zone: .data,
            kind: SliceKind.inboxItem.rawValue,
            modifiedAt: Date(timeIntervalSince1970: 50),
            payload: payload
        )
        try store.apply(CloudChangeBatch(changed: [record], deletedRecordNames: [], newToken: CloudChangeToken(value: 1)))
    }

    // MARK: - Storm suppression (BINDING)

    /// THE storm pin: empty watermark + a first batch full of tagged
    /// historical records → ZERO alerts, ZERO permission prompts, watermark
    /// armed at the batch's newest modifiedAt.
    func testInitialHydrateWithTaggedHistorySetsWatermarkWithoutAlerting() async throws {
        let ctx = try makeContext()
        XCTAssertNil(try ctx.store.lastAlertedWatermark())

        await ctx.coordinator.recordsApplied([
            applied(id: "1", level: "urgent", at: 100),
            applied(.briefing, id: "2026-07-06", level: "briefing", at: 200),
            applied(.target, id: "9", level: nil, at: 300)
        ])

        XCTAssertTrue(ctx.center.added.isEmpty, "initial hydrate is history, not news — it must NEVER alert")
        XCTAssertEqual(ctx.center.askCount, 0, "a suppressed batch must not trigger the permission ask")
        XCTAssertEqual(ctx.coordinator.permission, .notAsked)
        XCTAssertEqual(try ctx.store.lastAlertedWatermark()?.timeIntervalSince1970, 300)
    }

    // MARK: - Fresh rows after the watermark

    func testFreshUrgentRowAlertsOnceWithSnippet() async throws {
        let ctx = try makeContext(permission: .authorized)
        try seedInboxItem(into: ctx.store, id: 3, snippet: "can you check the deploy?")
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))

        await ctx.coordinator.recordsApplied([applied(id: "3", level: "urgent", at: 150)])

        XCTAssertEqual(ctx.center.added.count, 1)
        let request = try XCTUnwrap(ctx.center.added.first)
        XCTAssertEqual(request.content.title, "Urgent inbox item")
        XCTAssertEqual(request.content.body, "can you check the deploy?")
        XCTAssertEqual(ctx.center.askCount, 0, "already authorized — must not re-ask")
        XCTAssertEqual(try ctx.store.lastAlertedWatermark()?.timeIntervalSince1970, 150)
    }

    func testSameRowReappliedWithSameModifiedAtStaysSilent() async throws {
        let ctx = try makeContext(permission: .authorized)
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))
        let record = applied(id: "3", level: "urgent", at: 150)

        await ctx.coordinator.recordsApplied([record])
        await ctx.coordinator.recordsApplied([record])

        XCTAssertEqual(ctx.center.added.count, 1, "recordName+modifiedAt dedup: a replayed row must not re-alert")
    }

    /// A re-publish with a NEWER modifiedAt re-alerts BY DESIGN: the desktop
    /// only republishes a row when its content hash changed, so a re-carried
    /// urgent tag means genuinely new content on an urgent item.
    func testRepublishWithNewerModifiedAtAlertsAgain() async throws {
        let ctx = try makeContext(permission: .authorized)
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))

        await ctx.coordinator.recordsApplied([applied(id: "3", level: "urgent", at: 150)])
        await ctx.coordinator.recordsApplied([applied(id: "3", level: "urgent", at: 250)])

        XCTAssertEqual(ctx.center.added.count, 2)
    }

    func testTwoNewRowsInOneBatchRaiseTwoAlerts() async throws {
        let ctx = try makeContext(permission: .authorized)
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))

        await ctx.coordinator.recordsApplied([
            applied(id: "3", level: "urgent", at: 150),
            applied(.briefing, id: "2026-07-07", level: "briefing", at: 160)
        ])

        XCTAssertEqual(ctx.center.added.count, 2)
    }

    func testBriefingCopy() async throws {
        let ctx = try makeContext(permission: .authorized)
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))

        await ctx.coordinator.recordsApplied([applied(.briefing, id: "2026-07-07", level: "briefing", at: 150)])

        let request = try XCTUnwrap(ctx.center.added.first)
        XCTAssertEqual(request.content.title, "Your briefing is ready")
        XCTAssertTrue(request.content.body.isEmpty)
    }

    /// Forward compatibility: a newer desktop may ship notifyLevel values
    /// this build does not know — they must not alert (the phone never
    /// guesses importance), but the watermark still advances.
    func testUnknownNotifyLevelIsIgnored() async throws {
        let ctx = try makeContext(permission: .authorized)
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))

        await ctx.coordinator.recordsApplied([applied(id: "3", level: "calendar_conflict", at: 150)])

        XCTAssertTrue(ctx.center.added.isEmpty)
        XCTAssertEqual(try ctx.store.lastAlertedWatermark()?.timeIntervalSince1970, 150)
    }

    // MARK: - Contextual permission (Decision 5)

    func testFirstAlertableRowAsksOnceThenPosts() async throws {
        let ctx = try makeContext() // not asked yet, grant on ask
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))

        await ctx.coordinator.recordsApplied([applied(id: "3", level: "urgent", at: 150)])

        XCTAssertEqual(ctx.center.askCount, 1)
        XCTAssertEqual(ctx.center.added.count, 1, "a granted ask must be followed by the alert that triggered it")
        XCTAssertEqual(ctx.coordinator.permission, .authorized)
        XCTAssertEqual(
            ctx.defaults.string(forKey: NotificationCoordinator.permissionDefaultsKey),
            NotificationPermission.authorized.rawValue
        )

        // The next alertable row posts without asking again.
        await ctx.coordinator.recordsApplied([applied(id: "3", level: "urgent", at: 250)])
        XCTAssertEqual(ctx.center.askCount, 1)
        XCTAssertEqual(ctx.center.added.count, 2)
    }

    func testDeclinedAskIsRememberedAndNeverReasked() async throws {
        let ctx = try makeContext(grant: false)
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))

        await ctx.coordinator.recordsApplied([applied(id: "3", level: "urgent", at: 150)])
        XCTAssertEqual(ctx.center.askCount, 1)
        XCTAssertTrue(ctx.center.added.isEmpty)
        XCTAssertEqual(ctx.coordinator.permission, .denied)

        // A rebuilt coordinator over the same defaults keeps the memory —
        // declining survives app relaunches.
        let relaunched = NotificationCoordinator(store: ctx.store, center: ctx.center, defaults: ctx.defaults)
        XCTAssertEqual(relaunched.permission, .denied)
        await relaunched.recordsApplied([applied(id: "3", level: "urgent", at: 250)])
        XCTAssertEqual(ctx.center.askCount, 1, "declined is final — no re-ask on later alertable rows")
        XCTAssertTrue(ctx.center.added.isEmpty)
    }

    func testDeniedSkipsSilentlyButWatermarkStillAdvances() async throws {
        let ctx = try makeContext(permission: .denied)
        try ctx.store.setLastAlertedWatermark(Date(timeIntervalSince1970: 100))

        await ctx.coordinator.recordsApplied([applied(id: "3", level: "urgent", at: 150)])

        XCTAssertEqual(ctx.center.askCount, 0)
        XCTAssertTrue(ctx.center.added.isEmpty)
        XCTAssertEqual(try ctx.store.lastAlertedWatermark()?.timeIntervalSince1970, 150)
    }

    /// The user can flip authorization in iOS Settings behind the app's back;
    /// the Settings row re-reads the system state (never prompting).
    func testRefreshPermissionTracksSystemChanges() async throws {
        let ctx = try makeContext(permission: .authorized)
        ctx.center.status = .denied

        await ctx.coordinator.refreshPermission()
        XCTAssertEqual(ctx.coordinator.permission, .denied)

        ctx.center.status = .authorized
        await ctx.coordinator.refreshPermission()
        XCTAssertEqual(ctx.coordinator.permission, .authorized)
    }

    /// Never-asked stays never-asked on refresh — refreshing must not turn
    /// into an implicit prompt or a phantom state.
    func testRefreshPermissionLeavesNotAskedUntouched() async throws {
        let ctx = try makeContext()
        await ctx.coordinator.refreshPermission()
        XCTAssertEqual(ctx.coordinator.permission, .notAsked)
        XCTAssertEqual(ctx.center.askCount, 0)
    }

    // MARK: - Settings row

    func testSettingsNotificationsRowRendersPermission() {
        XCTAssertEqual(SettingsView.notificationsValue(for: .notAsked), "Not requested")
        XCTAssertEqual(SettingsView.notificationsValue(for: .authorized), "Allowed")
        XCTAssertEqual(SettingsView.notificationsValue(for: .denied), "Denied")
    }

    // MARK: - AppEnvironment wiring

    /// End-to-end: a demo-kind environment's first hydrate fires the Kit hook
    /// into the coordinator, which arms the watermark WITHOUT any permission
    /// activity — the app-level proof of the boot-time storm suppression.
    func testAppEnvironmentWiresHookAndArmsWatermarkOnFirstHydrate() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: dir.appendingPathComponent("replica.sqlite").path
        )

        let deadline = Date().addingTimeInterval(5)
        while (try env.store.lastAlertedWatermark()) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(try env.store.lastAlertedWatermark(), "the hydrator hook must arm the watermark on first hydrate")
        XCTAssertEqual(env.notifications.permission, .notAsked, "demo boot must never trigger the permission ask")
    }
}
