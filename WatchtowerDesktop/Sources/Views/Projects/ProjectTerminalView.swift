import AppKit
import SwiftUI
import WatchtowerCore

/// Terminal pane (spec §6.2). Shows the project's session from
/// `AppState.projectTerminalCenter`; never owns the process itself.
struct ProjectTerminalView: View {
    let project: Project
    @Environment(AppState.self) private var appState

    var body: some View {
        let center = appState.projectTerminalCenter
        VStack(spacing: 0) {
            switch center.states[project.id] {
            case .running?:
                if center.clipboardHints.contains(project.id) {
                    HStack {
                        Label(ProjectCommentsSendBar.copiedNote, systemImage: "doc.on.clipboard")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { center.dismissClipboardHint(projectID: project.id) }
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
                    Button("Restart") { center.start(project: project) }
                }
                .padding(8)
            case let .unavailable(message)?:
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                VStack(spacing: 8) {
                    Text("Run Claude Code in \(project.folderPath).").foregroundStyle(.secondary)
                    Button("Start Claude Code") { center.start(project: project) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func host(_ center: ProjectTerminalCenter) -> some View {
        if let session = center.session(for: project.id) {
            TerminalHost(session: session)
        }
    }
}

/// Hosts a session's NSView. Dismantling the host only removes the view from
/// the hierarchy — the center keeps it (and the process) alive.
private struct TerminalHost: NSViewRepresentable {
    let session: any ProjectTerminalSession

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
