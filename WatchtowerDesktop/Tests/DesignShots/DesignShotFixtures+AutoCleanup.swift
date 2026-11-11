import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Board #1716 (spec 2026-11-10-auto-cleanup-on-session-delete §7): the nine
/// states of `docs/design/mockups/session-auto-cleanup/states.html`, on
/// fixture data. The notice and the marks come from the real model
/// (`SessionCleanupNotice`, `SessionAutoCleanupOutcome`) over sample plans.
@MainActor
enum AutoCleanupShotFixtures {
    private static var poolPaths: [String] = []
    static let workbenchID: Int64 = 1
    static let panelWidth: CGFloat = 300

    static var shots: [DesignShot] {
        [
            DesignShot(name: "auto-cleanup-1-delete-dialog", size: NSSize(width: 440, height: 150)) {
                deleteDialog()
            },
            DesignShot(name: "auto-cleanup-2-undo-window", size: NSSize(width: panelWidth, height: 64)) {
                undoWindow()
            },
            DesignShot(name: "auto-cleanup-3-cleaning-header", size: NSSize(width: panelWidth, height: 96)) {
                cleaningHeader()
            },
            DesignShot(name: "auto-cleanup-4-clean-notice", size: NSSize(width: panelWidth, height: 90)) {
                notice([("Fix login flow", cleanPlan)])
            },
            DesignShot(name: "auto-cleanup-5-clean-with-kept", size: NSSize(width: panelWidth, height: 90)) {
                notice([("Plan run 1527", keptPlan)])
            },
            DesignShot(name: "auto-cleanup-6-joined-notice", size: NSSize(width: panelWidth, height: 90)) {
                notice([
                    ("Fix login flow", cleanPlan), ("Plan run 1527", keptPlan),
                    ("Spec review", cleanPlan), ("Review payments PR", keptPlan)
                ])
            },
            DesignShot(name: "auto-cleanup-7a-process-running", size: NSSize(width: panelWidth, height: 110)) {
                markedRow(title: "Fix login flow", mark: mark(result: plan([worktree("a", reason: "process_running")])))
            },
            DesignShot(name: "auto-cleanup-7b-git-refused", size: NSSize(width: panelWidth, height: 110)) {
                markedRow(title: "Plan run 1527", mark: mark(result: plan([
                    worktree("a", reason: "git_refused"), worktree("b", reason: "git_refused")
                ])))
            },
            DesignShot(name: "auto-cleanup-7c-cleanup-failed", size: NSSize(width: panelWidth, height: 110)) {
                markedRow(title: "Spec review", mark: mark(result: nil, runError: "watchtower exited with code 1"))
            },
            DesignShot(name: "auto-cleanup-8-clean-up-again-running", size: NSSize(width: panelWidth, height: 110)) {
                markedRow(title: "Fix login flow", mark: nil, cleaningAgain: true)
            },
            DesignShot(name: "auto-cleanup-9-narrow-panel", size: NSSize(width: 210, height: 80)) {
                markedRow(
                    title: "Fix login flow",
                    mark: mark(result: plan([worktree("a", reason: "process_running")])), width: 210
                )
            }
        ]
    }

    static func cleanUp() {
        for path in poolPaths { TestDatabase.cleanup(path: path) }
        poolPaths = []
    }

    // MARK: States

    /// State 1: the plain Delete confirmation of a live row.
    static func deleteDialog() -> AnyView {
        withVM { vm in
            AnyView(SessionDeleteConfirmSheet(vm: vm, session: session(1, "Fix login flow"))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panelBackground())
        }
    }

    /// State 2: the Undo window, unchanged.
    static func undoWindow() -> AnyView {
        withVM { vm in
            vm.pendingDeletes.enqueueSessionDelete(
                .init(sessionID: 1, workbenchID: workbenchID, title: "Fix login flow"),
                now: Date(timeIntervalSince1970: 1_790_000_000)
            )
            return panel(AnyView(SessionDeleteToast(vm: vm)))
        }
    }

    /// State 3: two deleted sessions cleaning up; the panel header says so,
    /// the finished row below is an ordinary one.
    static func cleaningHeader() -> AnyView {
        withVM { vm in
            vm.autoCleanupQueue[workbenchID] = [11, 12]
            let finished = session(2, "Review payments PR")
            let row = SessionSwitcherPresentation.Row(
                session: finished, state: .notStarted, caption: "Finished · 2 h", badge: nil, shortcut: nil
            )
            return panel(AnyView(VStack(alignment: .leading, spacing: Spacing.small) {
                SessionsPanelSectionLabel(vm: vm, projectID: workbenchID)
                TerminalSessionRow(row: row, actions: SessionRowActions(open: { _ in }, rename: { _ in }, delete: { _ in }))
            }
            .padding(Spacing.medium)))
        }
    }

    /// States 4–6: the clean notice on the Undo bar's place.
    static func notice(_ entries: [(title: String, result: SessionCleanupPlan)]) -> AnyView {
        withVM { vm in
            guard let notice = SessionCleanupNotice.joined(entries) else {
                return DesignShotFixtures.failure(FixtureError.noNotice)
            }
            vm.cleanupNotice = notice
            return panel(AnyView(SessionDeleteToast(vm: vm)))
        }
    }

    /// States 7–9: a Not fully cleaned row in the finished group, its
    /// actions shown as on hover.
    static func markedRow(title: String, mark: String?, cleaningAgain: Bool = false, width: CGFloat = panelWidth) -> AnyView {
        withVM { vm in
            let row = session(3, title)
            vm.notFullyCleanedRows[workbenchID] = [row]
            if let mark { vm.notFullyCleaned[row.id] = mark }
            if cleaningAgain { vm.cleaningAgain.insert(row.id) }
            // Its actions show as on hover (the mockup shows them always).
            return AnyView(NotFullyCleanedSessionRow(
                vm: vm, projectID: workbenchID, session: row, hoveredRow: .constant(row.id)
            )
                .padding(Spacing.medium)
                .frame(width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panelBackground())
        }
    }

    // MARK: Fixture data

    private enum FixtureError: Error { case noNotice, notMarked }

    private static func withVM(_ make: (WorkbenchesViewModel) -> AnyView) -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            poolPaths.append(path)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
            return make(WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static func panel(_ content: AnyView) -> AnyView {
        AnyView(content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .panelBackground())
    }

    private static func session(_ id: Int64, _ title: String) -> TerminalSession {
        TerminalSession(
            id: id, projectID: workbenchID, kind: .claude, title: title,
            titleSource: .user, folderPath: "/tmp/acme",
            createdAt: "2026-11-10T09:00:00Z", lastActiveAt: "2026-11-10T10:00:00Z"
        )
    }

    private static func mark(result: SessionCleanupPlan?, runError: String? = nil) -> String? {
        guard case let .notFullyCleaned(mark) = SessionAutoCleanupOutcome.evaluate(
            result: result, title: "T", runError: runError
        ) else {
            XCTFail("design shot fixture failed: \(FixtureError.notMarked)")
            return nil
        }
        return mark
    }

    /// 3 worktrees (~2.1 GB) and 12 branches removed.
    private static var cleanPlan: SessionCleanupPlan {
        plan([
            worktree("a", bytes: 700_000_000, done: true), worktree("b", bytes: 700_000_000, done: true),
            worktree("c", bytes: 700_000_000, done: true)
        ] + (1...12).map { branch("b\($0)", done: true) })
    }

    /// 2 worktrees (~1.4 GB) removed, 1 branch kept with unpushed commits.
    private static var keptPlan: SessionCleanupPlan {
        plan([
            worktree("d", bytes: 700_000_000, done: true), worktree("e", bytes: 700_000_000, done: true),
            branch("kept", reason: "unpushed_commits")
        ])
    }

    private static func worktree(_ name: String, bytes: Int64 = 0, done: Bool = false, reason: String? = nil) -> SessionCleanupItem {
        SessionCleanupItem(
            key: "worktree:/tmp/acme/\(name)", kind: .worktree, name: name,
            bytes: bytes, bytesKnown: true, action: done || reason == nil ? .remove : .keep,
            reason: reason.map(SessionCleanupReason.init(code:)), done: done
        )
    }

    private static func branch(_ name: String, done: Bool = false, reason: String? = nil) -> SessionCleanupItem {
        SessionCleanupItem(
            key: "branch:\(name)", kind: .branch, name: name,
            action: done || reason == nil ? .remove : .keep,
            reason: reason.map(SessionCleanupReason.init(code:)), done: done
        )
    }

    private static func plan(_ items: [SessionCleanupItem]) -> SessionCleanupPlan {
        let removed = items.filter { $0.done && $0.kind == .worktree }.reduce(Int64(0)) { $0 + $1.bytes }
        return SessionCleanupPlan(mode: "apply", items: items, removedBytes: removed, removedBytesKnown: true)
    }
}
