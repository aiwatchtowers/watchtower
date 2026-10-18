import AppKit
import SwiftUI
import WatchtowerCore

/// The window an owner-only CLI gesture waits on (AGENT-07, board #568,
/// ask #357): `watchtower actions approve`, `automations confirm` and the
/// like, run from a terminal without an agent marker, go ahead only on the
/// owner's click here. A floating panel shown without activating the app, so
/// it never takes the keyboard from what the owner is typing; it is not an
/// ask and never touches an agent's session. Confirm is armed one second
/// after the window appears; Deny is the default button, and Escape, Return
/// and closing the window deny.
@MainActor
enum OwnerConfirmWindow {
    /// The open panel and its delegate, kept alive until it closes.
    private static var open: (panel: NSPanel, delegate: CloseDelegate)?

    static func present(_ prompt: OwnerConfirmPrompt) {
        let panel = CancelPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        panel.title = "Confirm in Watchtower"
        let view = OwnerConfirmView(request: prompt.request, shownAt: Date()) { confirmed in
            prompt.answer(confirmed)
            panel.close()
        }
        show(panel, content: view) { prompt.answer(false) }
        prompt.onWithdraw = { panel.close() }
    }

    /// An informational panel with one OK button, shown the same way.
    static func notice(title: String, message: String) {
        let panel = CancelPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Watchtower"
        show(panel, content: NoticeView(title: title, message: message) { panel.close() }) {}
    }

    private static func show(
        _ panel: CancelPanel,
        content: some View,
        onClose: @escaping () -> Void
    ) {
        open?.panel.close()
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let delegate = CloseDelegate {
            onClose()
            open = nil
        }
        panel.delegate = delegate
        panel.onCancel = { panel.close() }
        panel.contentView = NSHostingView(rootView: content)
        open = (panel, delegate)
        panel.center()
        panel.orderFrontRegardless() // shown, not activated: no focus taken
    }

    /// Escape (`cancelOperation`) closes the panel, which denies.
    final class CancelPanel: NSPanel {
        var onCancel: (() -> Void)?

        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
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
    let shownAt: Date
    let decide: (Bool) -> Void
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm: \(OwnerConfirmRequest.displayable(request.verb))?")
                .font(.headline)
            Text("A command run outside Watchtower is waiting for you. Confirm only if you ran it yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(request.commandLine)
                        .font(.system(.callout, design: .monospaced))
                    if let detail = request.displayDetail {
                        Divider()
                        Text(detail)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Deny", role: .cancel) { decide(false) }
                    .keyboardShortcut(.defaultAction)
                Button("Confirm") {
                    // The arming also holds when a click lands before the state flips.
                    if OwnerConfirmArming.isArmed(shownAt: shownAt, now: Date()) { decide(true) }
                }
                .disabled(!armed)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
        .task {
            try? await Task.sleep(for: .seconds(OwnerConfirmArming.delay))
            armed = true
        }
    }
}

private struct NoticeView: View {
    let title: String
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
