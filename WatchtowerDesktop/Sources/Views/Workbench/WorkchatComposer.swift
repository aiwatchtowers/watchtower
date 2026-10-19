import SwiftUI
import WatchtowerCore

/// The Workchat's field and round button (#711, spec §4): Return sends,
/// Shift-Return adds a line; while the agent works the button is Stop, and
/// Esc in the empty field stops too. A Stop that did not go says why above
/// the field (`WorkchatModel.stopError`).
struct WorkchatComposer: View {
    @Bindable var model: WorkchatModel
    /// `SessionControl.isWorking` for the session's status.
    let working: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let stopError = model.stopError {
                Text(stopError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            ChatComposerField(
                text: $model.draft,
                isStreaming: working,
                onSend: send,
                onStop: stop,
                placeholder: "Message the agent… (/ for commands)",
                onEscape: escape
            )
        }
    }

    private func send() {
        Task { await model.send() }
    }

    /// Esc in the empty field while the agent works is Stop.
    private func escape() {
        if working && model.draft.isEmpty { stop() }
    }

    private func stop() {
        Task { _ = await model.stop() }
    }
}

/// A line sent from the Workchat, at the end of the feed until the feed
/// shows it (spec §4's table): a dashed bubble while queued, a caption for
/// a line the terminal still holds or that never went.
struct WorkchatOutgoingBubble: View {
    let line: WorkchatOutgoing
    let onCancel: () -> Void
    let onShowTerminal: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                Text(line.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(bubble)
                caption
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .opacity(isPending ? 0.65 : 1)
        }
    }

    private var isPending: Bool {
        line.state == .queued || line.state == .sending
    }

    @ViewBuilder
    private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if isPending {
            shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape.fill(Color.accentColor.opacity(0.14))
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch line.state {
        case .sending:
            Text("Sending…")
        case .queued:
            HStack(spacing: 4) {
                Text("Queued · sends when the agent stops ·")
                Button("Cancel", action: onCancel).buttonStyle(.link)
            }
        case .typed:
            HStack(spacing: 4) {
                Text("Typed into the terminal, not sent: press Return there ·")
                Button("Show in Terminal", action: onShowTerminal).buttonStyle(.link)
            }
        case .copied:
            HStack(spacing: 4) {
                Text("Copied to the clipboard: the terminal does not accept pasted text ·")
                Button("Show in Terminal", action: onShowTerminal).buttonStyle(.link)
            }
        case .notSent:
            Text("Not sent: the session ended")
        case .sent:
            Text(line.sentAt, format: .dateTime.hour().minute())
        }
    }
}
