import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Help → Report a Problem… (#1527): the real `ReportProblemSheet` over a
/// `ReportProblemModel` driven into each state with a fake CLI, opener and
/// writer, and the Settings → System → Logs row. Sample data only (no live
/// install). The approved mockups in `docs/design/mockups/report-a-problem/`
/// are the reference these renders are compared against.
@MainActor
enum ReportProblemShotFixtures {
    enum Frame: String, CaseIterable {
        case collecting, empty, filled, busy, failed, opened, tooLong, browserFailed, saveFailed, corp
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "report-problem-\(frame.rawValue)", size: NSSize(width: 600, height: 0)) {
                sheet(frame)
            }
        } + [
            DesignShot(name: "report-problem-filled-narrow", size: NSSize(width: 360, height: 0)) {
                sheet(.filled)
            },
            DesignShot(name: "report-problem-settings-entry", size: NSSize(width: 480, height: 0)) {
                AnyView(settingsEntry)
            }
        ]
    }

    /// One model per frame, built once: `make` runs three times per shot.
    private static var models: [Frame: ReportProblemModel] = [:]

    /// Stops the collecting frame's run (`DesignShotFixtures.cleanUp`).
    static func cleanUp() {
        models.values.forEach { $0.cancel() }
        models = [:]
    }

    private static func sheet(_ frame: Frame) -> AnyView {
        let model = models[frame] ?? build(frame)
        models[frame] = model
        return AnyView(ReportProblemSheet(model: model) {})
    }

    // MARK: - Driving the model

    private struct NoPermission: LocalizedError {
        var errorDescription: String? { "you do not have permission to save in that folder." }
    }

    private static func build(_ frame: Frame) -> ReportProblemModel {
        let runner: FakeCLIRunner
        switch frame {
        case .collecting:
            runner = FakeCLIRunner()
            runner.blockUntilCancelled = true
        case .failed:
            // `ProcessCLIRunner`'s own timeout.
            runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: -1, stderr: ""))
        case .busy:
            runner = FakeCLIRunner(stdout: answerJSON(busySample, partial: true))
        case .corp:
            runner = FakeCLIRunner(stdout: answerJSON(sample(corp: true), flavor: "corp"))
        default:
            runner = FakeCLIRunner(stdout: answerJSON(sample(corp: false)))
        }
        let model = ReportProblemModel(
            runner: runner,
            appVersion: "0.27.0",
            macOS: "15.5",
            iPhoneOn: frame == .busy,
            isCorp: frame == .corp,
            openURL: { _ in frame != .browserFailed },
            writePasteboard: { _ in XCTFail("a shot never writes the pasteboard") },
            writeFile: { _, _ in throw NoPermission() }
        )
        model.start()
        guard frame != .collecting else { return model }
        settle(model)

        switch frame {
        case .collecting, .empty: break
        case .tooLong: model.text = longText
        default: model.text = typed
        }
        switch frame {
        case .opened, .tooLong, .browserFailed: model.openIssue()
        case .saveFailed: model.save(to: URL(fileURLWithPath: "/nonexistent/watchtower-diagnostics.txt"))
        default: break
        }
        XCTAssertEqual(model.notice, expectedNotice(frame), "report-problem-\(frame.rawValue)")
        return model
    }

    private static func expectedNotice(_ frame: Frame) -> ReportProblemModel.Notice {
        switch frame {
        case .opened: .opened
        case .tooLong: .tooLong
        case .browserFailed: .browserFailed
        case .saveFailed: .saveFailed(NoPermission().localizedDescription)
        default: .none
        }
    }

    /// Spins the main run loop until the collection ended (≤ 2 s).
    private static func settle(_ model: ReportProblemModel) {
        let deadline = Date().addingTimeInterval(2)
        while model.collection != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(model.collection, "the fixture's collection finished")
    }

    // MARK: - Sample data

    private static let typed = "After I reconnected Gmail the Inbox stopped showing new mail. Sync Now did not help."

    /// Long enough, with escapes, that the link has to drop the pasted report
    /// (≤ 2 000 characters; the typed line first, so the field reads like the mockup).
    private static var longText: String {
        let step = "Inbox → “0 new” → Sync Now → “0 new” → reconnect Gmail → “0 new” — the same.\n"
        return String((typed + "\n" + String(repeating: step, count: 40)).prefix(2_000))
    }

    private static func answerJSON(_ text: String, partial: Bool = false, flavor: String = "default") -> Data {
        let object: [String: Any] = [
            "text": text, "version": "0.27.0", "macos": "15.5", "chip": "Apple M3",
            "provider": "Claude Code", "flavor": flavor, "sources": ["Slack", "Gmail", "Jira"], "partial": partial
        ]
        // A literal dictionary always serialises.
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func sample(corp: Bool) -> String { """
    Watchtower 0.27.0 (commit 1a2b3c4, flavor: \(corp ? "corp" : "default")) · app 0.27.0
    macOS 15.5 · Apple M3
    Config: ok
    AI: Claude Code · reserve Codex, automatic
    Features on: briefing, tracks, knowledge-search, people
    Sources: Slack 1 ok · Gmail 2 (1 needs sign-in) · Jira 1 ok
    Daemon: running · last cycle 4 min ago, done
    Recent errors (last 20):
      2026-11-04 09:12Z  gmail-sync  auth
      2026-11-04 08:42Z  gmail-sync  auth
      2026-11-03 22:10Z  digests     timeout
    Crash: none in the logs
    Logs: watchtower.log 4 MB · daemon.log 12 KB (not attached)
    Database: schema 166 · 1.2 GB · managed by organization: \(corp ? "yes" : "no")
    """ }

    private static let busySample = """
    Watchtower 0.27.0 (commit 1a2b3c4, flavor: default) · app 0.27.0
    macOS 15.5 · Apple M3
    Config: ok
    AI: Claude Code · reserve Codex, automatic
    Features on: briefing, tracks, knowledge-search, people
    Sources: unknown (database busy) · iPhone companion on
    Daemon: running · last cycle 4 min ago, done
    Recent errors (last 20):
      pipeline runs unknown (database busy)
      2026-11-04 09:40Z  sync        network
    Crash: none in the logs
    Logs: watchtower.log 4 MB · daemon.log 12 KB (not attached)
    Database: schema unknown (database busy) · 1.2 GB · managed by organization: no
    Partial report: database busy
    """

    // MARK: - Settings → System → Logs

    /// The real row (`LogsSectionButtons`) in the grouped form Settings → System uses.
    private static var settingsEntry: some View {
        Form {
            Section {
                LogsSectionButtons(openLogs: {}, reportProblem: {})
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .detailBackground()
    }
}
