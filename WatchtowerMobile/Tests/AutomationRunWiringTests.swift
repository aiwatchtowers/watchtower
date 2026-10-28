import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Running a workbench automation from the phone (ask #692): the rows over
/// the demo workbench, Run through a real outbox, the Mac's refusal and the
/// start-sessions grant.
@MainActor
final class AutomationRunWiringTests: XCTestCase {
    private let now = Date()

    private func grant(startSessions: Bool) -> DeviceGrant {
        DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Phone", scope: DemoSeed.device.scope, linked: true,
            typingAllowed: startSessions, startSessionsAllowed: startSessions
        )
    }

    private func model(
        _ snapshot: WorkbenchReplicaSnapshot, startSessions: Bool = true, inFlight: Set<String> = []
    ) -> WorkbenchAutomationsModel {
        WorkbenchAutomationsModel(
            workbenchID: DemoSeed.acmeID, snapshot: snapshot, grant: grant(startSessions: startSessions),
            inFlight: inFlight, now: now
        )
    }

    func testRowsFollowTheMacsState() throws {
        let rows = model(try demoSnapshot(now: now)).rows

        XCTAssertEqual(rows.map(\.automation.name), ["Release notes", "Changelog check", "Nightly triage"])
        XCTAssertEqual(rows.map(\.action), [.run, .running, .unavailable("Confirm on the Mac")])
        XCTAssertEqual(rows[0].meta.map(\.text).prefix(2), ["Button", "asks first"])
        XCTAssertTrue(rows[0].meta.last?.text.hasPrefix("Succeeded") == true)
        XCTAssertEqual(rows[2].meta.last?.tone, .red)
    }

    func testWithoutTheStartGrantNothingRuns() throws {
        let model = model(try demoSnapshot(now: now), startSessions: false)

        XCTAssertEqual(model.notAllowed, AutomationRunText.notAllowed)
        XCTAssertEqual(model.rows[0].action, .unavailable("Not allowed"))
    }

    func testAWorkbenchWithoutAutomationsHasNoRows() throws {
        let rows = WorkbenchAutomationsModel(
            workbenchID: DemoSeed.notesID, snapshot: try demoSnapshot(now: now), grant: grant(startSessions: true),
            inFlight: [], now: now
        ).rows
        XCTAssertTrue(rows.isEmpty)
    }

    func testRunSendsOneActionAndARefusalOffersDismiss() async throws {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let writer = BoardWriter.sending(through: outbox, store: store)
        let release = try XCTUnwrap(try demoSnapshot(now: now).workbench(DemoSeed.acmeID)?.automations?.first)

        let sent = try await writer.runAutomation(release, workbenchID: DemoSeed.acmeID, confirmed: true)
        XCTAssertTrue(sent)

        let row = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .automationRun)
        XCTAssertEqual(row.action.entityID, "71")
        XCTAssertEqual(try AutomationRunParams(wireParams: row.action.params), AutomationRunParams(workbenchID: DemoSeed.acmeID, confirmed: true))
        var snapshot = try demoSnapshot(now: now)
        snapshot.pending = try store.pendingActions()
        guard case .sending = model(snapshot).rows[0].action else { return XCTFail("a pending run shows its progress") }

        var echo = row.action
        echo.status = .failed
        echo.reason = .conflict
        echo.errorMessage = "Confirm this automation on the Mac first"
        try await outbox.applyEcho(echo)
        snapshot.pending = try store.pendingActions()
        let failed = try XCTUnwrap(model(snapshot).rows[0].failure)
        XCTAssertEqual(failed.message, "Confirm this automation on the Mac first")
        XCTAssertEqual(model(snapshot).rows[0].action, .run, "a refused run can be sent again")

        try writer.dismissRun(failed)
        XCTAssertTrue(try store.pendingActions().isEmpty)
    }

    func testANewRunClearsTheOlderRefusal() async throws {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let writer = BoardWriter.sending(through: outbox, store: store)
        let release = try XCTUnwrap(try demoSnapshot(now: now).workbench(DemoSeed.acmeID)?.automations?.first)
        try await writer.runAutomation(release, workbenchID: DemoSeed.acmeID)
        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .failed
        echo.reason = .writeFailed
        try await outbox.applyEcho(echo)

        try await writer.runAutomation(release, workbenchID: DemoSeed.acmeID)

        let rows = try store.pendingActions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.state, .pending)
    }
}
