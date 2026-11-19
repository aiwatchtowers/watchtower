import ChatUI
import SwiftUI
import WatchtowerCore

/// The Workchat's field and round button (#711, spec §4): Return sends,
/// Shift-Return adds a line; the button is Send whenever the field holds
/// something, even while the agent works (#2065 §5), and Stop only with an
/// empty field while it works; Esc stops exactly when the button is Stop. A
/// pasted image or long text goes into the field as a token (#2065 §6). A Stop
/// that did not go says why above the field (`WorkchatModel.stopError`); while an agent without mid-turn
/// input works, one line says a message waits for the turn's end (U2).
struct WorkchatComposer: View {
    @Bindable var model: WorkchatModel
    /// `SessionControl.isWorking` for the session's status.
    let working: Bool
    /// The field takes the keyboard as it is made.
    var autoFocus = false
    /// Each new value puts the keyboard in the field, caret at the end.
    var focusRequest: UUID?
    /// ⌥↓ opens or closes the live steps list (#2065 spec §3): true = handled; false or nil = the stock key.
    var onToggleSteps: (() -> Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hold = Self.holdCaption(agent: model.agent, holdsUntilIdle: model.holdsUntilIdle, working: working) {
                Text(hold)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.compact)
            }
            if let stopError = model.stopError {
                Text(stopError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.compact)
            }
            ChatComposerField(
                text: $model.draft,
                isStreaming: working,
                config: ChatComposerFieldConfig(
                    placeholder: Self.placeholder,
                    hasPendingContent: !model.attachments.isEmpty,
                    autoFocus: autoFocus,
                    focusRequest: focusRequest,
                    sendWhileStreaming: true,
                    inlinePastes: true,
                    livePastes: model.pastes.mapValues(\.kind)
                ),
                onSend: send,
                onStop: stop,
                onEscape: escape,
                attachments: model.attachments.map {
                    ChatComposerAttachment(id: $0.id, name: $0.name, mime: $0.mime, size: $0.size)
                },
                attachmentError: model.attachmentError,
                onAttachFiles: { model.attach(files: $0) },
                onPasteData: { await model.attach(data: $0, name: $1) },
                onRemoveAttachment: { model.removeAttachment($0) },
                onInlinePaste: { await model.paste($0) },
                onInlinePasteDropped: { model.pasteNotInserted($0) },
                onOptionArrowDown: onToggleSteps
            )
            .macComposerStyle()
        }
    }

    static let placeholder = "Message the agent… (/ for commands)"

    /// U2's line (S5): while the agent works and the session holds lines
    /// until it stops; nil otherwise.
    static func holdCaption(agent: AgentKind?, holdsUntilIdle: Bool, working: Bool) -> String? {
        guard working, holdsUntilIdle else { return nil }
        return "\(agent?.displayName ?? "The agent") takes your message when this turn ends."
    }

    private func send() {
        Task { await model.send() }
    }

    private func escape() {
        Self.escape(working: working, draft: model.draft, hasAttachments: !model.attachments.isEmpty, stop: stop)
    }

    /// Esc is Stop exactly when the round button is (`ComposerButtonMode`): while the agent works and the field
    /// holds nothing to send — no text after trimming (a paste token is text), no files. Otherwise nothing.
    static func escape(working: Bool, draft: String, hasAttachments: Bool = false, stop: () -> Void) {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments
        let mode = ComposerButtonMode.resolve(isStreaming: working, sendWhileStreaming: true, canSend: canSend,
                                              canStop: true)
        if case .stopButton = mode { stop() }
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
    /// The session's agent works now.
    var working = false
    /// The line waits for the agent to stop (`WorkchatModel.holdsUntilIdle`).
    var holdsUntilIdle = false
    let onCancel: () -> Void
    let onShowTerminal: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: Spacing.tight) {
                Text(line.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, Spacing.cozy)
                    .padding(.vertical, Spacing.compact)
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
        let shape = RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
        if isPending {
            shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape.fill(Color.accentColor.opacity(ChipTint.fillOpacity))
        }
    }

    /// `WorkchatOutgoing.caption`, with the state's link after it; the send
    /// time where it has none.
    @ViewBuilder
    private var caption: some View {
        let text = WorkchatOutgoing.caption(
            state: line.state, working: working, holdsUntilIdle: holdsUntilIdle, sentWhileBusy: line.sentWhileBusy
        )
        if let text {
            HStack(spacing: Spacing.small) {
                Text(text)
                switch line.state {
                case .queued:
                    Button("Cancel", action: onCancel).buttonStyle(.link)
                case .typed, .copied:
                    Button("Show in Terminal", action: onShowTerminal).buttonStyle(.link)
                case .sending, .sent, .notSent:
                    EmptyView()
                }
            }
        } else {
            Text(line.sentAt, format: .dateTime.hour().minute())
        }
    }
}
