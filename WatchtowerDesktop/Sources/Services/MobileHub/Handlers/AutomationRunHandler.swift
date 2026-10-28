import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// `automation_run` from the phone (ask #692; entity: the automation id,
/// params `{workbench_id, confirmed}`): runs a workbench automation now, as the Mac's
/// quick run does (`QuickRunCenter`, `automations run <id> --json`), under
/// the start-sessions grant. The row is read fresh here, not from the
/// palette's cached list: a recipe that is gone, not on this workbench, or
/// not runnable (unconfirmed, off, unreadable) is refused with the reason;
/// one already running is `applied` with that run. A `confirm: true`
/// recipe runs only with `confirmed` (the owner pressed Run in the phone's
/// confirmation, AUTO-06), and then with no sheet on the Mac.
/// `applied` carries `{run_id, coalesced}`; the workbench record is
/// published at once, so the phone sees the run.
@MainActor
final class AutomationRunHandler {
    typealias Grant = SessionStartStopHandlers.Grant

    nonisolated static let notAllowedMessage = "This phone is not allowed to run automations. "
        + "On the Mac: Watchtower → Settings → Mobile → allow typing, then starting sessions."
    static let timeoutMessage = "The Mac did not finish this in time — check the automation on the Mac"

    private let dbPool: DatabasePool
    private let quickRun: @MainActor () -> QuickRunCenter?
    private let deviceGrant: Grant
    private let publishSoon: @MainActor (Set<SliceKind>) -> Void
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        dbPool: DatabasePool,
        quickRun: @escaping @MainActor () -> QuickRunCenter?,
        deviceGrant: @escaping Grant,
        publishSoon: @escaping @MainActor (Set<SliceKind>) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = SessionStartStopHandlers.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.quickRun = quickRun
        self.deviceGrant = deviceGrant
        self.publishSoon = publishSoon
        self.now = now
        self.timeout = timeout
        self.sleep = sleep
    }

    func register(on dispatcher: MobileHubCommandDispatcher) {
        dispatcher.register(.automationRun) { try await self.handle($0) }
    }

    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        try await withHandlerTimeout(timeout, sleep: sleep, message: Self.timeoutMessage) {
            try await self.run(action)
        }
    }

    private func run(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard let automationID = action.entityID.flatMap(Int64.init),
              case let .integer(workbenchID)? = action.params["workbench_id"] else {
            return .failed(.invalidParams, message: "automation_run needs an automation id and a workbench_id")
        }
        let confirmed = action.params["confirmed"] == .bool(true)
        guard deviceGrant(action.deviceID).startSessionsAllowed else {
            return .failed(.deviceNotAllowed, message: Self.notAllowedMessage)
        }
        guard let center = quickRun() else { return .failed(.writeFailed, message: "Automations are loading on the Mac") }
        let now = now()
        let row = try await dbPool.read { db in
            QuickRunCatalog.rows(try AutomationQueries.fetchList(db, now: now), workbenchNames: [:])
                .first { $0.id == automationID }
        }
        guard let row else { return .failed(.notFound, message: "This automation no longer exists on the Mac") }
        guard case .workbench(workbenchID, _) = row.group else {
            return .failed(.notOnBoard, message: "That automation is not on this workbench")
        }
        switch row.state {
        case .runnable:
            guard !row.asksFirst || confirmed else {
                return .failed(.conflict, message: "This automation asks before it runs — confirm it on the phone")
            }
        case let .running(runID): return Self.applied(runID: runID, coalesced: true)
        case .needsConfirmation: return .failed(.conflict, message: "Confirm this automation on the Mac first")
        case .disabled: return .failed(.conflict, message: "This automation is turned off on the Mac")
        case .parseError: return .failed(.conflict, message: "This automation can't be read on the Mac")
        }
        switch await center.runFromPhone(row) {
        case let .started(runID):
            publishSoon([.workbench])
            return Self.applied(runID: runID, coalesced: false)
        case let .coalesced(runID):
            publishSoon([.workbench])
            return Self.applied(runID: runID, coalesced: true)
        case let .refused(message):
            return .failed(.writeFailed, message: message)
        case .askFirst, .openedConfirmation, .openedCard, .openedRun:
            // `runFromPhone` only starts a run.
            return .failed(.writeFailed, message: "The automation did not start")
        }
    }

    private static func applied(runID: Int64, coalesced: Bool) -> ActionOutcome {
        .applied(["run_id": .integer(runID), "coalesced": .bool(coalesced)])
    }
}
