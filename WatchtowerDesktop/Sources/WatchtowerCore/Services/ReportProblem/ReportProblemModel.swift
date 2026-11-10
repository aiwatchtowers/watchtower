import Foundation
import Observation

/// The Report a Problem sheet's state (#1527). The sheet renders it and owns
/// no logic: the diagnostics run (`watchtower diagnostics --json`, 10 s),
/// the Open / Save rules, the GitHub link and the clipboard rule live here.
///
/// The app writes nothing on its own: the pasteboard only on Copy Report /
/// Copy Link, a file only on Save, the browser only on Open GitHub Issue.
@MainActor @Observable
package final class ReportProblemModel {
    package enum Phase: Equatable {
        case collecting
        case ready(DiagnosticsAnswer)
        case failed(ReportProblemCopy.FailureReason)
    }

    package enum CopiedKind: Equatable {
        case report
        case link
    }

    package enum Notice: Equatable {
        case none
        case opened
        case tooLong
        case browserFailed
        case saveFailed(String)
        case copied(CopiedKind)
    }

    /// The Desktop's budget for the command (its own hard stop is 8 s).
    static let timeout: TimeInterval = 10

    package private(set) var phase: Phase = .collecting
    package private(set) var notice: Notice = .none
    /// True once Open GitHub Issue was pressed: Cancel shows as Done.
    package private(set) var afterOpen = false
    /// The last Open built a shortened link: the sheet offers Copy Report.
    package private(set) var offersCopyReport = false
    /// The last Open could not reach the browser: the sheet offers Copy Link.
    package private(set) var offersCopyLink = false

    /// "What happened?", capped at `ReportProblemLink.maxTextLength` characters.
    package var text: String {
        get { typed }
        set { typed = String(newValue.prefix(ReportProblemLink.maxTextLength)) }
    }

    private var typed = ""

    /// The running diagnostics collection, nil when none runs.
    @ObservationIgnored package private(set) var collection: Task<Void, Never>?

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let macOS: String
    @ObservationIgnored private let iPhoneOn: Bool
    @ObservationIgnored private let isCorp: Bool
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored private let writePasteboard: (String) -> Void
    @ObservationIgnored private let writeFile: (String, URL) throws -> Void

    package init(
        runner: any CLIRunnerProtocol,
        appVersion: String,
        macOS: String,
        iPhoneOn: Bool,
        isCorp: Bool,
        openURL: @escaping (URL) -> Bool,
        writePasteboard: @escaping (String) -> Void,
        writeFile: @escaping (String, URL) throws -> Void = ReportProblemModel.writeAtomically
    ) {
        self.runner = runner
        self.appVersion = appVersion
        self.macOS = macOS
        self.iPhoneOn = iPhoneOn
        self.isCorp = isCorp
        self.openURL = openURL
        self.writePasteboard = writePasteboard
        self.writeFile = writeFile
    }

    /// Writes the whole file or nothing: the old file stays as it was when
    /// the write fails.
    package nonisolated static func writeAtomically(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Derived state

    private var isCollecting: Bool { phase == .collecting }

    private var answer: DiagnosticsAnswer? {
        if case .ready(let answer) = phase { return answer }
        return nil
    }

    /// Open GitHub Issue: never in a corporate build, never while collecting,
    /// and only with a non-blank "What happened?".
    package var canOpen: Bool {
        !isCorp && !isCollecting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Save Diagnostics…: in every state but collecting.
    package var canSave: Bool { !isCollecting }

    /// The diagnostics block exactly as it will be sent.
    package var diagnosticsText: String {
        switch phase {
        case .collecting: ""
        case .ready(let answer): answer.text
        case .failed: ReportProblemCopy.partialLines(appVersion: appVersion, macOS: macOS)
        }
    }

    /// What Copy Report and Save write: the user's text, if any, then the
    /// diagnostics block. Nothing else.
    package var report: String {
        let diagnostics = diagnosticsText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return diagnostics }
        return text + "\n\n" + diagnostics
    }

    package var noticeText: String? {
        switch notice {
        case .none: nil
        case .opened: ReportProblemCopy.opened
        case .tooLong: ReportProblemCopy.tooLong
        case .browserFailed: ReportProblemCopy.browserFailed
        case .saveFailed(let reason): ReportProblemCopy.saveFailed(reason)
        case .copied(.report): ReportProblemCopy.reportCopied
        case .copied(.link): ReportProblemCopy.linkCopied
        }
    }

    // MARK: - Actions

    /// Starts the diagnostics run. Does nothing while one runs or once an
    /// answer is in, so a re-open of the sheet never starts a second process.
    package func start() {
        guard collection == nil, answer == nil else { return }
        collect()
    }

    /// Retry after a failed collection; a second press while the retry runs
    /// does nothing.
    package func retry() {
        guard collection == nil, case .failed = phase else { return }
        collect()
    }

    /// Open GitHub Issue: builds the link from the current text and opens it.
    /// The sheet stays open with the text.
    package func openIssue() {
        guard canOpen else { return }
        let link = makeLink()
        afterOpen = true
        if openURL(link.url) {
            offersCopyLink = false
            offersCopyReport = link.shortened
            notice = link.shortened ? .tooLong : .opened
        } else {
            offersCopyLink = true
            offersCopyReport = link.shortened
            notice = .browserFailed
        }
    }

    package func copyReport() {
        writePasteboard(report)
        notice = .copied(.report)
    }

    package func copyLink() {
        guard !isCorp else { return }
        writePasteboard(makeLink().url.absoluteString)
        notice = .copied(.link)
    }

    package func save(to url: URL) {
        guard canSave else { return }
        do {
            try writeFile(report, url)
            if case .saveFailed = notice { notice = .none }
        } catch {
            notice = .saveFailed(error.localizedDescription)
        }
    }

    /// Cancel / Done: stops a running collection (the runner terminates the
    /// child); nothing is written.
    package func cancel() {
        collection?.cancel()
        collection = nil
    }

    // MARK: - Private

    private var arguments: [String] {
        ["diagnostics", "--json", "--app-version", appVersion, "--iphone", iPhoneOn ? "on" : "off"]
    }

    private func makeLink() -> (url: URL, shortened: Bool) {
        ReportProblemLink.make(userText: text, answer: answer, appVersion: appVersion, macOS: macOS)
    }

    private func collect() {
        phase = .collecting
        let runner = runner
        let args = arguments
        collection = Task { [weak self] in
            let result = await Self.run(runner, args: args)
            guard !Task.isCancelled, let self, let result else { return }
            self.phase = result
            self.collection = nil
        }
    }

    /// The run's outcome; nil when the run was cancelled.
    private static func run(_ runner: any CLIRunnerProtocol, args: [String]) async -> Phase? {
        let stdout: Data
        do {
            stdout = try await runner.run(args: args, timeout: timeout)
        } catch is CancellationError {
            return nil
        } catch let CLIRunnerError.nonZeroExit(code, _) {
            // `ProcessCLIRunner` reports its own timeout as exit -1.
            return .failed(code == -1 ? .timedOut : .exit(code))
        } catch {
            // `binaryNotFound`, or the binary could not be launched.
            return .failed(.missing)
        }
        guard let answer = try? DiagnosticsAnswer.decode(stdout: stdout) else {
            return .failed(.unreadable)
        }
        return .ready(answer)
    }
}
