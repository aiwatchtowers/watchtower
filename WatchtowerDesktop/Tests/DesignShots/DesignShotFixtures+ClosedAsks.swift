import AppKit
import DesignKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The closed asks list in the ask drawer (#1713), every state of the
/// spec's States table, rendered from the real views over a real view
/// model. The approved mockups these are compared with are in
/// `docs/design/mockups/closed-asks-list/`. Sample data only.
@MainActor
enum ClosedAsksShotFixtures {
    enum Frame: String, CaseIterable {
        case big, search, noMatch, narrow, empty, loading, error, busy, staleError, partial, askGone, opened

        var height: CGFloat {
            switch self {
            case .big, .busy, .staleError: 720
            case .search, .opened, .partial, .askGone: 420
            default: 0
            }
        }
    }

    private static var poolPaths: [String] = []

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "closed-asks-\(frame.rawValue)", size: NSSize(width: 440, height: frame.height)) {
                scene(frame)
            }
        } + [
            // The drawer at its least width (320): two-line titles wrap, the time stays.
            DesignShot(name: "closed-asks-big-min-width", size: NSSize(width: 320, height: 560)) {
                scene(.big)
            }
        ]
    }

    static func cleanUp() {
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
    }

    // MARK: - Scenes

    private static func scene(_ frame: Frame) -> AnyView {
        do {
            let (vm, project, session) = try workbench()
            let key = frame == .narrow
                ? OwnerAsksViewModel.ClosedListKey(projectID: project, sessionID: nil, automations: true)
                : OwnerAsksViewModel.ClosedListKey(projectID: project, sessionID: session)
            let asks = vm.asks
            let list = try rows(frame, project: project, session: session)
            switch frame {
            case .loading:
                _ = asks.beginClosedRead(key)
            case .error:
                fail(asks, key)
            case .busy:
                succeed(asks, key, list)
                _ = asks.beginClosedRead(key)
            case .staleError:
                succeed(asks, key, list)
                fail(asks, key)
            default:
                succeed(asks, key, list, labels: frame == .narrow ? narrowLabels : [:])
            }
            switch frame {
            case .search: asks.closedListQueries[key] = "login"
            case .noMatch: asks.closedListQueries[key] = "postgres"
            case .big: asks.closedListCursors[key] = list.asks.dropFirst(2).first?.id
            case .askGone: asks.closedListNotices[key] = ClosedAskListCopy.askGone
            default: break
            }
            let view: AnyView
            if frame == .opened, let ask = list.asks.first(where: { $0.title.hasPrefix("Which session store") }) {
                asks.openDrawer(ask)
                asks.noteOpenedFromClosedList(key, askID: ask.id)
                view = AnyView(OwnerAskDrawer(vm: vm, ask: ask))
            } else {
                view = AnyView(OwnerAskClosedListPane(vm: vm, key: key))
            }
            return AnyView(view.frame(maxWidth: .infinity, maxHeight: frame.height > 0 ? .infinity : nil, alignment: .top))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// A workbench with one session, selected, as on its page.
    private static func workbench() throws -> (WorkbenchesViewModel, Int64, Int64) {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        let (project, session) = try pool.write { db -> (Int64, TerminalSession) in
            let id = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
            let session = try TerminalSessionQueries.create(
                db, .init(projectID: id, kind: .shell, title: "Fix the login redirect after SSO", folderPath: "/tmp/acme"))
            return (id, session)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        vm.selectedWorkbenchID = project
        vm.terminalSessions[project] = [session]
        return (vm, project, session.id)
    }

    private static func succeed(
        _ asks: OwnerAsksViewModel,
        _ key: OwnerAsksViewModel.ClosedListKey,
        _ rows: OwnerAskRows,
        labels: [Int64: String] = [:]
    ) {
        let generation = asks.beginClosedRead(key)
        let read = OwnerAsksViewModel.ClosedRead(asks: rows, replaced: replacements, counts: [:], automationCount: 0, labels: labels)
        asks.finishClosedRead(key, generation: generation, result: .success(read), now: readAt)
    }

    private static func fail(_ asks: OwnerAsksViewModel, _ key: OwnerAsksViewModel.ClosedListKey) {
        let generation = asks.beginClosedRead(key)
        asks.finishClosedRead(key, generation: generation, result: .failure(Busy()))
    }

    private struct Busy: LocalizedError {
        var errorDescription: String? { "the database is busy." }
    }

    /// 14:32 today, the last good read of the stale shot.
    private static var readAt: Date {
        Calendar.current.date(bySettingHour: 14, minute: 32, second: 0, of: Date()) ?? Date()
    }

    // MARK: - Sample asks

    private static let replacements: [Int64: Int64] = [412: 406, 408: 401, 401: 395]
    private static let narrowLabels: [Int64: String] = [388: "⚙ Weekly summary · run #41", 351: "⚙ Nightly export · run #12"]

    private struct Sample {
        let kind: String
        let title: String
        let status: String
        let reason: String
        let payload: String
        let answer: String

        init(_ kind: String, _ title: String, _ status: String, _ reason: String, _ payload: String, _ answer: String) {
            self.kind = kind
            self.title = title
            self.status = status
            self.reason = reason
            self.payload = payload
            self.answer = answer
        }
    }

    private static let questionPayload = #"{"questions":[{"id":"a","question":"Store?","options":[{"label":"Server table"},{"label":"Cookie"}]}]}"#
    private static let checkPayload = #"{"checklist":[{"id":"1","text":"Sign in"},{"id":"2","text":"Expire"},{"id":"3","text":"Return"},"#
        + #"{"id":"4","text":"Log out"},{"id":"5","text":"Again"}]}"#

    private static func answer(
        verdict: String = "",
        answers: String = "[]",
        checklist: String = "[]",
        comments: Int = 0,
        note: String = "",
        dismissed: Bool = false
    ) -> String {
        let comment = #"{"quote":"q","prefix":"","suffix":"","heading":"","body":"b"}"#
        let list = Array(repeating: comment, count: comments).joined(separator: ",")
        return #"{"verdict":"\#(verdict)","answers":\#(answers),"checklist":\#(checklist),"comments":[\#(list)],"note":"\#(note)""#
            + (dismissed ? #","dismissed":true}"# : "}")
    }

    private static var samples: [Sample] {
        let marks = #"[{"id":"1","state":"ok"},{"id":"2","state":"ok"},{"id":"3","state":"ok"},{"id":"4","state":"ok"},"#
            + #"{"id":"5","state":"broken"}]"#
        let threeOK = #"[{"id":"1","state":"ok"},{"id":"2","state":"ok"},{"id":"3","state":"ok"}]"#
        return [
            Sample("review", "Spec: login redirect keeps the return URL after SSO", "delivered", "", "{}",
                   answer(verdict: "approved", comments: 3)),
            Sample("question", "Which session store should the redirect fix use — the cookie or the server table?", "delivered", "",
                   questionPayload, answer(answers: #"[{"id":"a","labels":["Server table"],"other":"keep the cookie as a fallback"}]"#)),
            Sample("check", "Check the login flow on staging with an expired session", "delivered", "", checkPayload,
                   answer(checklist: marks)),
            Sample("review", "Plan: login redirect, 6 tasks", "withdrawn", "superseded", "{}", ""),
            Sample("question", "Rename the `acme_auth` package now or after the release?", "answered", "", questionPayload,
                   answer(answers: #"[{"id":"a","labels":[],"other":"After the release"}]"#)),
            Sample("review", "Spec: login redirect keeps the return URL after SSO (round 1)", "withdrawn", "superseded", "{}", ""),
            Sample("check", "Open example.com/settings and confirm the banner is gone", "answered", "", checkPayload,
                   answer(note: "Not needed any more", dismissed: true)),
            Sample("question", "Run the migration on the shared database now?", "withdrawn", "agent", questionPayload, ""),
            Sample("review", "Review the changes to the session cleanup", "delivered", "", "{}",
                   answer(verdict: "changes", comments: 2, note: "Keep the old flag for one release")),
            Sample("question", "Should the retry use the existing backoff helper?", "delivered", "", questionPayload,
                   answer(answers: #"[{"id":"a","labels":["Yes"],"other":""}]"#)),
            Sample("check", "Sign in with a second account and switch between them", "delivered", "", checkPayload,
                   answer(checklist: threeOK))
        ]
    }

    private static func rows(_ frame: Frame, project: Int64, session: Int64) throws -> OwnerAskRows {
        switch frame {
        case .empty, .loading, .error: return OwnerAskRows()
        case .narrow: return OwnerAskRows(asks: try narrow(project: project))
        default:
            let all = try big(project: project, session: session)
            return frame == .partial
                ? OwnerAskRows(asks: all.filter { $0.id != 369 && $0.id != 362 }, unreadableIDs: [369, 362])
                : OwnerAskRows(asks: all)
        }
    }

    /// 84 asks over nine days, newest first, 7 today and 7 yesterday.
    private static func big(project: Int64, session: Int64) throws -> [OwnerAsk] {
        var out: [OwnerAsk] = []
        var id: Int64 = 412
        let today = Calendar.current.startOfDay(for: Date())
        let dayOffsets = [0, 1, 3, 4, 5, 6, 7, 10, 11]
        for (index, offset) in dayOffsets.enumerated() where out.count < 84 {
            let count = min(84 - out.count, index < 2 ? 7 : 10 + index % 3)
            for slot in 0..<count {
                let sample = samples[Int(id * 5) % samples.count]
                let day = Calendar.current.date(byAdding: .day, value: -offset, to: today) ?? today
                let created = day.addingTimeInterval(Double((18 - min(slot, 10)) * 3600 + Int(id * 7) % 60 * 60))
                out.append(try ask(id, project: project, session: session, sample: sample, created: created))
                id -= 1
            }
        }
        return out
    }

    private static func narrow(project: Int64) throws -> [OwnerAsk] {
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let older = Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today
        return [
            try ask(388, project: project, session: nil,
                    sample: Sample("question", "Post the weekly summary to #acme-team?", "delivered", "", questionPayload,
                                   answer(answers: #"[{"id":"a","labels":[],"other":"Post it"}]"#)),
                    created: yesterday.addingTimeInterval(17 * 3600 + 300), run: 41),
            try ask(351, project: project, session: nil,
                    sample: Sample("check", "Confirm the nightly export reached example.com", "withdrawn", "agent", checkPayload, ""),
                    created: older.addingTimeInterval(9 * 3600 + 720), run: 12)
        ]
    }

    private static func ask(
        _ id: Int64,
        project: Int64,
        session: Int64?,
        sample: Sample,
        created: Date,
        run: Int64? = nil
    ) throws -> OwnerAsk {
        try OwnerAsk(row: Row([
            "id": id, "project_id": project, "session_id": session, "level": "full", "origin": "agent",
            "kind": sample.kind, "title": sample.title, "status": sample.status, "withdrawn_reason": sample.reason,
            "payload": sample.payload, "answer": sample.answer, "automation_run_id": run,
            "created_at": ISO8601DateFormatter().string(from: created)
        ]))
    }
}
