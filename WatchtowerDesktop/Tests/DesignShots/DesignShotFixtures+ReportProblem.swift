import AppKit
import DesignKit
import SwiftUI

/// Design-only scenes for Help → Report a Problem… (#1527 spec). Nothing here
/// is wired into the app: the copy below is the spec's string table, which the
/// implementation moves into `WatchtowerCore` (`ReportProblemCopy`) with a test.
/// Sample data only (no live install).
@MainActor
enum ReportProblemShotFixtures {
    enum Frame: String, CaseIterable {
        case collecting, empty, filled, failed, opened, tooLong, browserFailed, saveFailed, corp
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "report-problem-\(frame.rawValue)", size: NSSize(width: 600, height: 0)) {
                AnyView(ReportProblemSheetMock(frame: frame))
            }
        } + [
            DesignShot(name: "report-problem-filled-narrow", size: NSSize(width: 360, height: 0)) {
                AnyView(ReportProblemSheetMock(frame: .filled))
            },
            DesignShot(name: "report-problem-settings-entry", size: NSSize(width: 480, height: 0)) {
                AnyView(ReportProblemSettingsEntryMock())
            }
        ]
    }
}

/// The spec's strings, in one place (the implementation pins them in a test).
enum ReportProblemMockCopy {
    static let title = "Report a Problem"
    static let intro = "Tell us what went wrong. Watchtower sends nothing itself: "
        + "you review everything below and submit it on GitHub yourself."
    static let corpIntro = "This is your organization's build. Save the diagnostics and send the file to your IT team."
    static let whatHappened = "What happened?"
    static let placeholder = "What you did, what you expected, what you saw instead."
    static let typeToContinue = "Describe the problem to continue."
    static let diagnosticsTitle = "Diagnostics that will be included"
    static let diagnosticsNote = "Kinds, counts, states and error classes only — no names, ids, message text or log lines."
    static let collecting = "Collecting diagnostics…"
    static let failed = "Could not collect diagnostics: the watchtower command did not answer in 10 seconds. "
        + "The report will carry the app and macOS versions only."
    static let retry = "Retry"
    static let publicNote = "GitHub issues are public. Check the text before you submit."
    static let discussions = "A question, not a problem? Ask in Discussions"
    static let cancel = "Cancel"
    static let save = "Save Diagnostics…"
    static let open = "Open GitHub Issue"
    static let done = "Done"
    static let opened = "Opened in your browser. Finish the issue there; this window keeps your text until you press Done."
    static let tooLong = "The report did not fit in the link. Copy it and paste it into Logs on GitHub."
    static let copyReport = "Copy Report"
    static let browserFailed = "Could not open your browser. Copy the link and paste it into a browser."
    static let copyLink = "Copy Link"
    static let logsSection = "Logs"
    static let openLogs = "Open Logs"
    static let menuItem = "Report a Problem…"
    static let saveFailed = "Could not save the file: you do not have permission to save in that folder."

    static func sample(corp: Bool) -> String { """
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
    static let partial = "Watchtower app 0.27.0\nmacOS 15.5"
}

private struct ReportProblemSheetMock: View {
    let frame: ReportProblemShotFixtures.Frame
    private typealias Copy = ReportProblemMockCopy

    private var text: String {
        frame == .empty || frame == .collecting ? "" :
            "After I reconnected Gmail the Inbox stopped showing new mail. Sync Now did not help."
    }

    private var isCorp: Bool { frame == .corp }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.title).font(.title3.weight(.semibold))
                Text(isCorp ? Copy.corpIntro : Copy.intro).font(.caption).foregroundStyle(.secondary)
            }
            field
            diagnostics
            notice
            if !isCorp {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(Copy.publicNote).font(.caption).foregroundStyle(.secondary)
                    Button(Copy.discussions) {}.buttonStyle(.kitQuiet)
                }
            }
            buttons
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(Copy.whatHappened).font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: .constant(text))
                    .font(.body)
                    .scrollContentBackground(.hidden)
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
                    Text(Copy.sample(corp: isCorp))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
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
        case .opened: noticeRow(Copy.opened, icon: "checkmark.circle.fill", tone: Tone.success, action: nil)
        case .tooLong: noticeRow(Copy.tooLong, icon: "doc.on.clipboard", tone: Tone.warning, action: Copy.copyReport)
        case .browserFailed:
            noticeRow(Copy.browserFailed, icon: "exclamationmark.triangle.fill", tone: Tone.warning, action: Copy.copyLink)
        case .saveFailed: noticeRow(Copy.saveFailed, icon: "exclamationmark.triangle.fill", tone: Tone.warning, action: nil)
        default: EmptyView()
        }
    }

    private func noticeRow(_ message: String, icon: String, tone: Color, action: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .top, spacing: Spacing.regular) {
                Image(systemName: icon).foregroundStyle(tone)
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action) {}.buttonStyle(.kitSecondary)
            }
        }
    }

    private var afterOpen: Bool { [.opened, .tooLong, .browserFailed].contains(frame) }
    private var canSend: Bool { !text.isEmpty && frame != .collecting }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.regular) {
                Spacer(minLength: 0)
                buttonSet
            }
            VStack(alignment: .trailing, spacing: Spacing.regular) {
                buttonSet
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder private var buttonSet: some View {
        if isCorp {
            Button(Copy.cancel) {}.buttonStyle(.kitQuiet)
            Button(Copy.save) {}.buttonStyle(.kitPrimary)
        } else {
            Button(afterOpen ? Copy.done : Copy.cancel) {}.buttonStyle(.kitQuiet)
            Button(Copy.save) {}.buttonStyle(.kitSecondary).disabled(frame == .collecting)
            Button(Copy.open) {}.buttonStyle(.kitPrimary).disabled(!canSend)
        }
    }
}

/// Settings → System → Logs with the second entry point (design-only).
private struct ReportProblemSettingsEntryMock: View {
    private typealias Copy = ReportProblemMockCopy

    var body: some View {
        SettingsSection(title: Copy.logsSection) {
            HStack(spacing: Spacing.regular) {
                Button {} label: { Label(Copy.openLogs, systemImage: "doc.text") }
                    .buttonStyle(.kitSecondary)
                Button {} label: { Label(Copy.menuItem, systemImage: "exclamationmark.bubble") }
                    .buttonStyle(.kitSecondary)
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}
