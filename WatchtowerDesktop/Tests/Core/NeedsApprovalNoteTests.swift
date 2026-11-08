import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Needs approval's note (plan Task 12): shown only off, stopped or after a
/// failed run, each with its own press; Turn On's reason under the note,
/// never the feature manager's shared error; Run History's target.
@MainActor
final class NeedsApprovalNoteTests: XCTestCase {
    private var path = ""
    private let suite = "NeedsApprovalNoteTests.\(UUID().uuidString)"
    private static let busy = "Feature changes are being applied in Settings — try again"

    override func tearDown() {
        if !path.isEmpty { TestDatabase.cleanup(path: path) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The Inbox over the Needs approval built-in in `state`, read once.
    private func inbox(
        stopped: Bool = false, runs: [String] = ["succeeded"], featureOn: Bool = true
    ) async throws -> (vm: ActionStripViewModel, pool: DatabasePool, automation: Int64, runs: [Int64]) {
        let (pool, path) = try TestDatabase.createPool()
        self.path = path
        let seeded = try await pool.write { db -> (Int64, [Int64]) in
            try InboxFolderFixtures.seed(db)
            let automation = try NeedsApprovalFixtures.builtin(
                db, id: "needs-approval", name: "Needs approval", disabledReason: stopped ? "would not end" : "")
            let runIDs = try runs.map { try NeedsApprovalFixtures.run(db, automation, status: $0) }
            return (automation, runIDs)
        }
        let vm = NeedsApprovalFixtures.viewModel(pool, suite: suite)
        vm.disabledFeatures = featureOn ? [] : [ActionStripViewModel.approvalsFeatureID]
        await vm.refresh()
        return (vm, pool, seeded.0, seeded.1)
    }

    func testNoteHiddenWhenOnAndHealthy() async throws {
        let inbox = try await inbox()
        XCTAssertNil(inbox.vm.approvalsNoteContent)
    }

    func testFeatureOffShowsOffNote() async throws {
        let inbox = try await inbox(stopped: true, runs: ["failed"], featureOn: false)
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.state, .off, "off wins over stopped and failed")
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.buttonTitle, "Turn On")
    }

    func testStoppedShowsStoppedNoteWithTurnOn() async throws {
        let inbox = try await inbox(stopped: true, runs: ["failed"])
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.state, .stopped)
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.buttonTitle, "Turn On", "not Run History")
    }

    func testLastRunFailedShowsRunHistory() async throws {
        let inbox = try await inbox(runs: ["succeeded", "timed_out"])
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.state, .lastRunFailed)
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.buttonTitle, "Run History")
    }

    /// Both Turn On notes call the built-in card's Turn On once per press,
    /// and Run History never does.
    func testTurnOnCallsSetBuiltinEnabledOnce() async throws {
        for (featureOn, stopped) in [(false, false), (true, true)] {
            let inbox = try await inbox(stopped: stopped, featureOn: featureOn)
            var calls = 0
            var opened = 0
            await inbox.vm.pressApprovalsNote(turnOn: { calls += 1; return nil }, runHistory: { _, _ in opened += 1 })
            XCTAssertEqual(calls, 1, "featureOn \(featureOn)")
            XCTAssertEqual(opened, 0)
        }
    }

    func testFeatureOffTurnOnFailureShowsReason() async throws {
        let inbox = try await inbox(featureOn: false)
        await inbox.vm.pressApprovalsNote(turnOn: { "features enable: config locked" }, runHistory: { _, _ in })
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.state, .off, "the note stays")
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.failure, "features enable: config locked")
        XCTAssertNil(inbox.vm.lastError, "the reason is the note's own, not the strip's")
    }

    func testStoppedTurnOnFailureShowsReason() async throws {
        let inbox = try await inbox(stopped: true)
        await inbox.vm.pressApprovalsNote(turnOn: { "watchtower exited with error: database is locked" },
                                          runHistory: { _, _ in })
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.state, .stopped)
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.failure, "watchtower exited with error: database is locked")
    }

    func testTurnOnBusyShowsSettingsBusy() async throws {
        let inbox = try await inbox(featureOn: false)
        await inbox.vm.pressApprovalsNote(turnOn: { Self.busy }, runHistory: { _, _ in })
        XCTAssertEqual(inbox.vm.approvalsNoteContent?.failure, Self.busy)
        // The next press clears it.
        await inbox.vm.pressApprovalsNote(turnOn: { nil }, runHistory: { _, _ in })
        XCTAssertNil(inbox.vm.approvalsNoteContent?.failure)
    }

    /// nil: the Inbox re-reads, and the note leaves once the read sees the
    /// built-in running again.
    func testTurnOnSuccessRefreshesAndNoteLeaves() async throws {
        let inbox = try await inbox(stopped: true)
        let pool = inbox.pool
        await inbox.vm.pressApprovalsNote(turnOn: {
            try? await pool.write { db in try db.execute(sql: "UPDATE automations SET disabled_reason = ''") }
            return nil
        }, runHistory: { _, _ in })
        XCTAssertNil(inbox.vm.approvalsNoteContent)
    }

    /// Turned on, the restart failed: the note leaves with the read (the
    /// feature reads on), while the app-wide banner the call set stays.
    func testRestartFailureOutlivesTheNote() async throws {
        let inbox = try await inbox(featureOn: false)
        var banner: String?
        let vm = inbox.vm
        await vm.pressApprovalsNote(turnOn: {
            vm.disabledFeatures = []
            banner = "The background sync did not restart: the daemon did not stop in time"
            return "the daemon did not stop in time"
        }, runHistory: { _, _ in })
        await vm.refresh()
        XCTAssertNil(vm.approvalsNoteContent, "the note left")
        XCTAssertNotNil(banner, "the banner outlives it")
    }

    /// nil but nothing changed (another apply won the race): the note stays
    /// with no message, and can be pressed again.
    func testTurnOnNilWithStateUnchangedKeepsNoteWithoutMessage() async throws {
        let inbox = try await inbox(stopped: true)
        await inbox.vm.pressApprovalsNote(turnOn: { nil }, runHistory: { _, _ in })
        XCTAssertEqual(inbox.vm.approvalsNoteContent, NeedsApprovalNoteContent(state: .stopped))
    }

    func testTurnOnDisabledWhileRunning() async throws {
        let inbox = try await inbox(featureOn: false)
        let vm = inbox.vm
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let first = Task {
            await vm.pressApprovalsNote(turnOn: {
                calls += 1
                await withCheckedContinuation { release = $0 }
                return nil
            }, runHistory: { _, _ in })
        }
        while release == nil { await Task.yield() }
        XCTAssertEqual(vm.approvalsNoteContent?.isApplying, true, "the button waits")
        await vm.pressApprovalsNote(turnOn: { calls += 1; return nil }, runHistory: { _, _ in })
        release?.resume()
        await first.value
        XCTAssertEqual(calls, 1, "a second press while one runs is ignored")
        XCTAssertEqual(vm.approvalsNoteContent?.isApplying, false)
    }

    func testRunHistoryOpensLatestFailedRun() async throws {
        let inbox = try await inbox(runs: ["failed", "succeeded", "failed"])
        var opened: [(Int64, Int64?)] = []
        await inbox.vm.pressApprovalsNote(turnOn: { XCTFail("no Turn On"); return nil },
                                          runHistory: { opened.append(($0, $1)) })
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, inbox.automation)
        XCTAssertEqual(opened.first?.1, inbox.runs[2])
    }

    /// No failed run left (pruned): the automation's card opens alone.
    func testRunHistoryWithoutFailedRunOpensCard() {
        let state = NeedsApprovalState(automationID: 7, lastRunFailed: true, latestFailedRunID: nil)
        let target = NeedsApprovalNoteModel.runHistory(state)
        XCTAssertEqual(target?.automationID, 7)
        XCTAssertNil(target?.runID)
        XCTAssertNil(NeedsApprovalNoteModel.runHistory(.absent), "nothing to open before it is indexed")
    }
}
