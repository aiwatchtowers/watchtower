import AppKit
import SwiftTerm
import SwiftUI
import WatchtowerCore

/// Terminal pane (spec §6.2). Shows the project's active session from
/// `AppState.terminalCenter` — the last focused live one, else its most
/// recently active open row — and never owns the process itself. Interim
/// until the sessions panel (Task 9) lets the owner pick one.
struct ProjectTerminalView: View {
    let project: Project
    @Environment(AppState.self) private var appState

    var body: some View {
        let center = appState.terminalCenter
        let session = shownSession(center)
        let state = session.flatMap { center.states[$0.id] }
        let vm = appState.projectsViewModel
        VStack(spacing: 0) {
            if let error = vm?.sessionErrors[project.id] {
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
                host(center, session)
            case let .exited(code)?:
                host(center, session)
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
                VStack(spacing: 8) {
                    Text("Run Claude Code in \(project.folderPath).").foregroundStyle(.secondary)
                    Button("Start Claude Code") {
                        Task { await vm?.openMostRecentSession(project: project) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: project.id) { await vm?.loadSessions(projectID: project.id) }
    }

    private func shownSession(_ center: TerminalCenter) -> TerminalSession? {
        center.activeSession(projectID: project.id)
            ?? appState.projectsViewModel?.terminalSessions[project.id]?.first { !$0.isClosed }
    }

    @ViewBuilder
    private func host(_ center: TerminalCenter, _ session: TerminalSession?) -> some View {
        if let session, let process = center.process(for: session.id) {
            TerminalHost(session: process)
        }
    }
}

/// Hosts a session's NSView. Dismantling the host only removes the view from
/// the hierarchy — the center keeps it (and the process) alive.
private struct TerminalHost: NSViewRepresentable {
    let session: any TerminalSessionProcess

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        attach(to: container)
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: TerminalContainerView) {
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
            terminal.frame = contentFrame(in: container.bounds)
            container.addSubview(terminal)
        }
        return true
    }

    /// Terminal.app-like inner margin on every side. The terminal's own frame
    /// is inset (not padded inside it), so SwiftTerm computes cols/rows from
    /// the space it really has and the last column is never clipped.
    static let margin: CGFloat = 10

    static func contentFrame(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX + margin, y: bounds.minY + margin,
               width: max(0, bounds.width - 2 * margin), height: max(0, bounds.height - 2 * margin))
    }
}

/// The host's container: keeps its terminal inset by `TerminalHostAttachment.margin`
/// on every resize and paints the margin in the terminal's own background
/// colour, so the padding reads as part of the terminal, not as a frame.
final class TerminalContainerView: NSView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        subviews.forEach { $0.frame = TerminalHostAttachment.contentFrame(in: bounds) }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        needsDisplay = true
    }

    /// Drawn (not a layer colour) so a dynamic colour follows light/dark.
    override func draw(_ dirtyRect: NSRect) {
        let terminal = subviews.first as? TerminalView
        (terminal?.nativeBackgroundColor ?? .textBackgroundColor).setFill()
        dirtyRect.fill()
    }
}
