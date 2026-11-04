import AppKit
import DesignKit
import SwiftUI

/// Design-only scenes for Help → Report a Problem… (#1527 spec). Nothing here
/// is wired into the app: the copy below is the spec's string table, which the
/// implementation moves into `WatchtowerCore` (`ReportProblemCopy`) with a test.
/// Sample data only (no live install): version 0.27.0, `acme`-free counts.
@MainActor
enum ReportProblemShotFixtures {
    enum Frame: String, CaseIterable {
        case collecting, empty, filled, failed, clipboard, browserFailed, saveFailed
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "report-problem-\(frame.rawValue)", size: NSSize(width: 560, height: 0)) {
                AnyView(ReportProblemSheetMock(frame: frame))
            }
        } + [DesignShot(name: "report-problem-filled-narrow", size: NSSize(width: 360, height: 0)) {
            AnyView(ReportProblemSheetMock(frame: .filled))
        }]
    }
}

/// The spec's strings, in one place (the implementation pins them in a test).
enum ReportProblemMockCopy {
    static let title = "Report a Problem"
    static let intro = "Tell us what went wrong. Watchtower sends nothing itself: "
        + "you review everything below and submit it on GitHub."
    static let whatHappened = "What happened?"
    static let placeholder = "What you did, what you expected, what you saw instead."
    static let typeToContinue = "Describe the problem to continue."
    static let diagnosticsTitle = "Diagnostics that will be included"
    static let diagnosticsNote = "Kinds, counts and states only — no names, ids, message text or log lines."
    static let collecting = "Collecting diagnostics…"
    static let failed = "Could not collect diagnostics: the watchtower command did not answer in 10 seconds. "
        + "The report will carry the app version only."
    static let retry = "Retry"
    static let publicNote = "GitHub issues are public. Check the text before you submit."
    static let cancel = "Cancel"
    static let save = "Save Diagnostics…"
    static let open = "Open GitHub Issue"
    static let done = "Done"
    static let clipboard = "The diagnostics did not fit in the link. They are on the clipboard — "
        + "paste them into Logs on GitHub."
    static let browserFailed = "Could not open your browser. The issue link is on the clipboard — paste it into a browser."
    static let saveFailed = "Could not save the file: you do not have permission to save in that folder."

    static let sample = """
    Watchtower 0.27.0 (commit 1a2b3c4, flavor: release) · app 0.27.0
    macOS 15.5 · Apple M3
    AI: Claude Code · reserve Codex, automatic
    Features on: briefing, tracks, knowledge-search, people
    Sources: Slack 1 ok · Gmail 2 (1 needs sign-in) · Jira 1 ok
    Daemon: running · last cycle 4 min ago, done
    Last 24 h: gmail sync auth ×3 · digests timeout ×1
    Crash log: no panic since 2026-11-01
    Logs: watchtower.log 4 MB · daemon.log 12 KB (not attached)
    Database: schema 166 · 1.2 GB · managed by organization: no
    """
    static let partial = "Watchtower app 0.27.0"
}

private struct ReportProblemSheetMock: View {
    let frame: ReportProblemShotFixtures.Frame
    private typealias Copy = ReportProblemMockCopy

    private var text: String {
        frame == .empty || frame == .collecting ? "" :
            "After I reconnected Gmail the Inbox stopped showing new mail. Sync Now did not help."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.title).font(.title3.weight(.semibold))
                Text(Copy.intro).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.whatHappened).font(.headline)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: .constant(text)).font(.body).scrollContentBackground(.hidden)
                        .frame(height: 72)
                    if text.isEmpty {
                        Text(Copy.placeholder).foregroundStyle(.tertiary).padding(.leading, Spacing.small)
                    }
                }
                .padding(Spacing.regular)
                .card()
                if frame == .empty {
                    Text(Copy.typeToContinue).font(.caption).foregroundStyle(.secondary)
                }
            }
            diagnostics
            notice
            Text(Copy.publicNote).font(.caption).foregroundStyle(.secondary)
            buttons
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(Copy.diagnosticsTitle).font(.headline)
            Text(Copy.diagnosticsNote).font(.caption).foregroundStyle(.secondary)
            Group {
                switch frame {
                case .collecting:
                    HStack(spacing: Spacing.regular) {
                        ProgressView().controlSize(.small)
                        Text(Copy.collecting).font(.caption).foregroundStyle(.secondary)
                    }
                case .failed:
                    VStack(alignment: .leading, spacing: Spacing.regular) {
                        HStack(alignment: .top, spacing: Spacing.regular) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                            Text(Copy.failed).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(Copy.partial).font(.caption.monospaced())
                        Button(Copy.retry) {}.buttonStyle(.kitSecondary)
                    }
                default:
                    Text(Copy.sample).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder private var notice: some View {
        switch frame {
        case .clipboard: noticeRow(Copy.clipboard, icon: "doc.on.clipboard", tone: Tone.success)
        case .browserFailed: noticeRow(Copy.browserFailed, icon: "exclamationmark.triangle.fill", tone: Tone.warning)
        case .saveFailed: noticeRow(Copy.saveFailed, icon: "exclamationmark.triangle.fill", tone: Tone.warning)
        default: EmptyView()
        }
    }

    private func noticeRow(_ message: String, icon: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.regular) {
            Spacer(minLength: 0)
            if frame == .clipboard || frame == .browserFailed {
                Button(Copy.done) {}.buttonStyle(.kitPrimary)
            } else {
                Button(Copy.cancel) {}.buttonStyle(.kitQuiet)
                Button(Copy.save) {}.buttonStyle(.kitSecondary).disabled(frame == .collecting)
                Button(Copy.open) {}.buttonStyle(.kitPrimary)
                    .disabled(frame == .empty || frame == .collecting)
            }
        }
    }
}
