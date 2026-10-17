import AppKit
import SwiftUI
import WatchtowerCore

/// The window an owner-only CLI gesture waits on (AGENT-07, board #568,
/// ask #306): `watchtower actions approve`, `automations confirm` and the
/// like, run from a terminal or an agent's shell, go ahead only on the
/// owner's click here. A floating panel, so it shows whether or not a main
/// window is open; it is not an ask and never touches the agent's session.
/// Deny is the default button (Return, Escape and closing deny), so only a
/// deliberate click on Confirm confirms.
@MainActor
enum OwnerConfirmWindow {
    /// The open panel and its delegate, kept alive until it closes.
    private static var open: (panel: NSPanel, delegate: CloseDelegate)?

    static func present(_ prompt: OwnerConfirmPrompt) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Confirm in Watchtower"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let delegate = CloseDelegate {
            prompt.answer(false)
            open = nil
        }
        panel.delegate = delegate
        panel.contentView = NSHostingView(rootView: OwnerConfirmView(request: prompt.request) { confirmed in
            prompt.answer(confirmed)
            panel.close()
        })
        prompt.onWithdraw = { panel.close() }
        open = (panel, delegate)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }
}

private struct OwnerConfirmView: View {
    let request: OwnerConfirmRequest
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm: \(OwnerConfirmRequest.displayable(request.verb))?")
                .font(.headline)
            if let agent = request.agent, !agent.isEmpty {
                Label("Requested from an AI agent's shell (\(OwnerConfirmRequest.displayable(agent)) is set).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let detail = request.displayDetail {
                Text(detail)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(request.commandLine)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("A command is waiting for your confirmation. Confirm only if you ran it yourself or expect it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Deny", role: .cancel) { decide(false) }
                    .keyboardShortcut(.defaultAction)
                Button("Confirm") { decide(true) }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
