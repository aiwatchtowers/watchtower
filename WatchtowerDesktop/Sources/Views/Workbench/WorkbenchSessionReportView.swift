import AppKit
import SwiftUI
import WatchtowerCore

/// The Session view (spec 2026-10-03-workbench-session-report Part 1, Part
/// 7): one `claude` session's report from `SessionReportCenter`, in a column
/// of at most 760 pt. The pane names its session; the layout points it at
/// each session put on screen (`WorkspaceLayout.show`), so it follows the
/// selection. While on screen the center keeps the report fresh.
struct WorkbenchSessionReportView: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let sessionID: Int64

    var body: some View {
        let hasSession = vm.reportSession(sessionID, projectID: project.id) != nil
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { vm.reportAppeared(sessionID: sessionID, projectID: project.id) }
            .onDisappear { vm.reportDisappeared(sessionID: sessionID) }
            // A layout restored before any list load names a row not read
            // yet; a deleted session must stop its runs.
            .onChange(of: hasSession) { _, _ in
                vm.reportSessionChanged(sessionID: sessionID, projectID: project.id)
            }
            .task(id: sessionID) {
                if vm.session(sessionID, projectID: project.id) == nil { await vm.loadSessions(projectID: project.id) }
            }
            .task(id: project.id) { await vm.loadGitHubRepository(project: project) }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.reportPane(sessionID: sessionID, projectID: project.id) {
        case .pickSession:
            if vm.terminalSessions[project.id] == nil, vm.sessionErrors[project.id] == nil {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView(SessionReportPresentation.noSessionText, systemImage: "list.bullet.rectangle")
            }
        case .loading:
            ProgressView("Loading the report…").controlSize(.small)
        case let .failed(_, error):
            ContentUnavailableView(
                "Could not load the report", systemImage: "exclamationmark.triangle", description: Text(error)
            )
        case let .report(session, report, staleError):
            ScrollView {
                SessionReportContent(
                    report: report,
                    state: vm.sessionState(session),
                    staleError: staleError,
                    pullRequestURL: { vm.pullRequestURL($0, projectID: project.id) },
                    actions: .init(
                        openAsk: { id in Task { await vm.showAsk(id, projectID: project.id) } },
                        openTarget: { vm.showTargetOnBoard($0, projectID: project.id) },
                        openURL: { NSWorkspace.shared.open($0) }
                    )
                )
                .frame(maxWidth: 760, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// What the report's links do; the view wires them to the page.
struct SessionReportActions {
    /// An ask's **Open**: the asks drawer on that ask.
    let openAsk: (Int64) -> Void
    /// A target id: the Board with that target's card open.
    let openTarget: (Int64) -> Void
    /// A PR row with a known GitHub URL.
    let openURL: (URL) -> Void
}

/// The report's sections in the Part 1 order: state and size, On you, Now,
/// Pull requests, Done, Agent's last word.
struct SessionReportContent: View {
    let report: SessionReport
    let state: SessionSwitcherPresentation.State
    /// The failed refresh's error line; the report is from an earlier run.
    let staleError: String?
    let pullRequestURL: (SessionReport.PullRequest) -> URL?
    let actions: SessionReportActions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            onYou
            now
            pullRequests
            done
            lastWord
        }
        .textSelection(.enabled)
    }

    // MARK: State and size

    private var header: some View {
        let session = report.session
        return VStack(alignment: .leading, spacing: 8) {
            if let staleError {
                Label(staleError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The last refresh failed; this report is from an earlier run.")
            }
            HStack(spacing: 8) {
                SessionStateLabel(state: state)
                if let target = session.targetID { targetButton(target) }
                if let ran = SessionReportPresentation.ranFor(session) {
                    Text("ran \(ran)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(session.title).font(.headline)
            if !branches.isEmpty {
                Text(branches.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(SessionReportPresentation.heroLine(report.progress))
                .font(.title2.weight(.semibold))
            ProgressView(value: SessionReportPresentation.progressFraction(report.progress))
                .accessibilityLabel(SessionReportPresentation.heroLine(report.progress))
        }
    }

    /// The session's branches: those of its tasks in progress, then those
    /// of its PR rows, each once.
    private var branches: [String] {
        var seen: Set<String> = []
        let all = report.now.map(\.branch) + report.prs.compactMap(\.branch)
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Sections

    private var onYou: some View {
        section("On you") {
            if report.onYou.isEmpty {
                emptyText(SessionReportPresentation.onYouEmptyText)
            } else {
                ForEach(report.onYou) { ask in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("#\(ask.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(ask.title).lineLimit(2)
                        Spacer(minLength: 8)
                        Button("Open") { actions.openAsk(ask.id) }
                            .controlSize(.small)
                            .accessibilityLabel("Open ask \(ask.id)")
                    }
                }
            }
        }
    }

    private var now: some View {
        section("Now") {
            if report.now.isEmpty {
                emptyText(SessionReportPresentation.nowEmptyText)
            } else {
                ForEach(report.now) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            targetButton(item.id)
                            Text(item.text).lineLimit(2)
                        }
                        Text(SessionReportPresentation.nowDetail(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var pullRequests: some View {
        section("Pull requests") {
            if report.prs.isEmpty {
                emptyText(SessionReportPresentation.prsEmptyText)
            } else {
                ForEach(report.prs) { pr in
                    let line = SessionReportPresentation.prLine(pr)
                    VStack(alignment: .leading, spacing: 2) {
                        if let url = pullRequestURL(pr) {
                            Button(line.title) { actions.openURL(url) }
                                .buttonStyle(.link)
                                .help(url.absoluteString)
                        } else {
                            Text(line.title)
                        }
                        Text(line.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !report.prNote.isEmpty {
                Text(report.prNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var done: some View {
        section("Done") {
            if report.phases.isEmpty, report.next.isEmpty {
                emptyText(SessionReportPresentation.phasesEmptyText)
            }
            ForEach(report.phases) { phase in
                let line = SessionReportPresentation.phaseLine(phase)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: line.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(line.isComplete ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                    targetButton(phase.targetID)
                    Text(line.title).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(line.count).font(.caption.monospacedDigit())
                    if let span = line.span {
                        Text(span).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(report.next) { item in
                Button(SessionReportPresentation.nextLine(item)) { actions.openTarget(item.id) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private var lastWord: some View {
        let word = SessionReportPresentation.lastWord(report.session)
        return section(word.title) {
            if word.isPlaceholder {
                emptyText(word.text)
            } else {
                Text(word.text)
            }
        }
    }

    // MARK: Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    /// "#314": opens the target on the Board.
    private func targetButton(_ id: Int64) -> some View {
        Button("#\(id)") { actions.openTarget(id) }
            .buttonStyle(.link)
            .font(.caption.monospaced())
            .help("Show #\(id) on the Board")
            .accessibilityLabel("Show target \(id) on the Board")
    }
}
