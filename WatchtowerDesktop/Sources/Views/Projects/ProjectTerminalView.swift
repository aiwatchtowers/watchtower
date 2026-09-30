import AppKit
import SwiftUI
import WatchtowerCore

/// Terminal pane (spec §6.2). Shows `ProjectsViewModel.shownSession` — the
/// session the panel last opened, else the last focused live one — from
/// `AppState.terminalCenter`, and never owns the process itself.
struct ProjectTerminalView: View {
    let project: Project
    @Environment(AppState.self) private var appState

    var body: some View {
        let vm = appState.projectsViewModel
        TerminalSessionPane(session: shownSession, error: vm?.sessionErrors[project.id]) {
            VStack(spacing: 8) {
                Text("Run Claude Code in \(project.folderPath).").foregroundStyle(.secondary)
                Button("Start Claude Code") {
                    Task { await vm?.openMostRecentSession(project: project) }
                }
            }
        }
        .task(id: project.id) { await vm?.loadSessions(projectID: project.id) }
    }

    private var shownSession: TerminalSession? {
        appState.projectsViewModel?.shownSession(projectID: project.id)
    }
}

/// A standalone terminal (no project): always the whole page, single pane.
struct StandaloneTerminalView: View {
    let session: TerminalSession
    @Environment(AppState.self) private var appState

    var body: some View {
        let vm = appState.projectsViewModel
        TerminalSessionPane(session: session, error: vm?.standaloneSessionError) {
            VStack(spacing: 8) {
                Text(session.isClosed ? "\(session.title) is closed." : "\(session.title) is not running.")
                    .foregroundStyle(.secondary)
                Button(session.isClosed ? "Reopen" : "Start") {
                    Task { await vm?.open(session) }
                }
            }
        }
    }
}

/// One session's terminal with its state around it: the error line, the
/// clipboard hint, the exit bar (Restart / Start fresh), or `notStarted`
/// when the center runs nothing for it.
private struct TerminalSessionPane<NotStarted: View>: View {
    let session: TerminalSession?
    let error: String?
    @ViewBuilder let notStarted: () -> NotStarted
    @Environment(AppState.self) private var appState

    var body: some View {
        let center = appState.terminalCenter
        let state = session.flatMap { center.states[$0.id] }
        let vm = appState.projectsViewModel
        VStack(spacing: 0) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Divider()
            }
            switch state {
            case .running?:
                if let session, center.clipboardHints.contains(session.id) {
                    HStack {
                        Label(ProjectCommentsSendBar.copiedNote, systemImage: "doc.on.clipboard")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { center.dismissClipboardHint(sessionID: session.id) }
                            .controlSize(.small)
                    }
                    .padding(8)
                    Divider()
                }
                host(center)
            case let .exited(code)?:
                host(center)
                Divider()
                HStack {
                    Text(TerminalLaunch.exitMessage(code: code))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // A failed resume fails again on Restart: only a new id gets out.
                    if let session, vm?.resumeFailed.contains(session.id) == true {
                        Button("Start fresh") { Task { await vm?.startFresh(session) } }
                    }
                    Button("Restart") {
                        if let session { Task { await vm?.open(session) } }
                    }
                }
                .padding(8)
            case let .unavailable(message)?:
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                notStarted().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func host(_ center: TerminalCenter) -> some View {
        if let session, let process = center.process(for: session.id) {
            TerminalHost(session: process)
        }
    }
}

/// Hosts a session's NSView. Dismantling the host only removes the view from
/// the hierarchy — the center keeps it (and the process) alive.
private struct TerminalHost: NSViewRepresentable {
    let session: any TerminalSessionProcess

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let terminal = session.view
        guard TerminalHostAttachment.attach(terminal, to: container) else { return }
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}

/// How a host shows one session's view. SwiftUI reuses the same host when the
/// page switches to another project, so the container can still hold the
/// previous project's terminal: it must be the only subview afterwards, or
/// switching back leaves the other project's terminal on top — on screen and
/// taking the keystrokes.
enum TerminalHostAttachment {
    /// Makes `terminal` the container's only subview. Returns whether
    /// anything changed (the caller then moves keyboard focus to it).
    @MainActor
    @discardableResult
    static func attach(_ terminal: NSView, to container: NSView) -> Bool {
        let others = container.subviews.filter { $0 !== terminal }
        if terminal.superview === container, others.isEmpty { return false }
        others.forEach { $0.removeFromSuperview() }
        if terminal.superview !== container {
            terminal.removeFromSuperview()
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
        }
        return true
    }
}
