import SwiftUI
import WatchtowerCore

/// The trailing buttons of a row with a `ref`, drawn through A's
/// `ArtifactRefHooks.nativeActions` (`InboxRefHooks`).
struct InboxRowActionsView: View {
    let content: InboxRowActionsContent
    /// A sender or Older row's **Mark All Done…** press (`InboxBulkCenter`).
    var bulk: InboxBulkPressModel?
    var onPress: (InboxRowPress) -> Void = { _ in }

    var body: some View {
        HStack(spacing: Spacing.compact) {
            buttons
                .disabled(content.isBusy || content.isPreview)
            if content.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.kitSecondary)
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder
    private var buttons: some View {
        switch content.kind {
        case .mailSender, .waitingOlder:
            if let bulk {
                InboxBulkRowButtons(model: bulk, isSender: isSender) { bar }
            } else {
                bar
            }
        case .inboxItem, .track, .idea, .reminder, .action:
            bar
            let more = all.filter { $0.place == .more }
            if !content.isBusy, !more.isEmpty {
                self.more {
                    ForEach(Array(more.enumerated()), id: \.offset) { _, button in draw(button) }
                }
            }
        }
    }

    /// Every button the row has (`InboxRowActionsContent.rowButtons`), the
    /// list VoiceOver names too.
    private var all: [InboxRowButton] { content.rowButtons(hasBulk: bulk != nil) }

    private var isSender: Bool {
        if case .mailSender = content.kind { return true }
        return false
    }

    private var bar: some View {
        ForEach(Array(all.filter { $0.place == .bar }.enumerated()), id: \.offset) { _, button in
            draw(button)
        }
    }

    @ViewBuilder
    private func draw(_ button: InboxRowButton) -> some View {
        if button.press == .markAllDone, let bulk {
            InboxBulkPressButton(
                title: button.title, confirmTitle: { "Mark \($0) Done" }, model: bulk, style: .inline)
                .disabled(!button.enabled)
        } else if !button.choices.isEmpty {
            Menu(button.title) {
                ForEach(Array(button.choices.enumerated()), id: \.offset) { _, choice in
                    Button(choice.title) { onPress(choice.currentPress) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(!button.enabled)
        } else {
            Button(button.title, role: button.destructive ? .destructive : nil) { onPress(button.currentPress) }
                .disabled(!button.enabled)
                .help(button.help ?? "")
        }
    }

    private func more<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        Menu(content: items) { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .buttonStyle(.kitIcon(isOn: false))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
    }
}

/// A sender or Older row's buttons, observing its **Mark All Done…** press:
/// while it asks, the row shows only the question — a sender's "<N> open
/// from this sender", then **Cancel** and the prominent "Mark N Done" (no
/// Open or Mute meanwhile, as the approved mockup) — and its usual buttons
/// (`idle`) otherwise.
struct InboxBulkRowButtons<Idle: View>: View {
    @ObservedObject var model: InboxBulkPressModel
    let isSender: Bool
    @ViewBuilder let idle: () -> Idle

    var body: some View {
        if case let .confirming(plan) = model.state {
            if isSender {
                Text("\(plan.count) open from this sender")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            InboxBulkPressButton(
                title: "Mark All Done…", confirmTitle: { "Mark \($0) Done" }, model: model, style: .inline)
        } else {
            idle()
        }
    }
}

/// What sits under a row with a `ref`: a proposal's own summary, the
/// missing-CLI line on a row with a press that needs the CLI, a failed
/// press's error with **Retry**, the Reply composer (or its refusal), or
/// "Reply waiting for approval". Nothing for an idle row without these.
struct InboxRowActionsFooter: View {
    let content: InboxRowActionsContent
    /// A sender or Older row's bulk press: its result line and Try Again.
    var bulk: InboxBulkPressModel?
    var onPress: (InboxRowPress) -> Void = { _ in }

    /// The composer's field has the keyboard: only then does ⌘↩ propose,
    /// so two open composers never answer the same press.
    @FocusState private var composing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let summary = content.actionSummary {
                // Next to Approve whatever the look's row says (A's contract item 3), with the row's full width.
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(summary)
                    .accessibilityIdentifier("inboxRow.actionSummary")
            }
            if content.showsCLIMissingLine {
                Text(InboxRowActionsContent.cliMissingMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("inboxRow.cliMissing")
            }
            if case let .failed(message) = content.state {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if content.footerOffersRetry {
                        Button("Retry") { onPress(.retryFailedPress) }
                            .buttonStyle(.kitSecondary)
                            .disabled(content.isOff(.retryFailedPress))
                    }
                }
            }
            switch content.reply {
            case let .composing(text, error):
                composer(text: text, error: error)
            case .waiting:
                Text("Reply waiting for approval")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            if let bulk {
                InboxBulkPressResult(model: bulk, inline: true)
            }
        }
        .controlSize(.small)
    }

    private func composer(text: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.regular) {
                TextField("Reply…", text: Binding(get: { text }, set: { onPress(.replyChanged($0)) }))
                    .textFieldStyle(.kit)
                    .focused($composing)
                    .onAppear { composing = true }
                    .onExitCommand { onPress(.cancelReply) }
                    .disabled(content.isBusy)
                Button("Propose Reply") { onPress(.proposeReply) }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(composing ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.isBusy
                              || content.isOff(.proposeReply))
                Button("Cancel") { onPress(.cancelReply) }
                    .buttonStyle(.kitQuiet)
                    .disabled(content.isBusy)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("Goes to Needs approval — nothing is sent until you approve it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The footer of a row with a bulk press (a sender or Older row): it
/// observes the press, so its result line and Try Again appear the moment
/// it finishes. Nothing is drawn — no empty footer, no spacing — while the
/// row has no footer of its own and the press has nothing to say (idle,
/// under way, or a full success).
struct InboxRowBulkFooter: View {
    let content: InboxRowActionsContent
    @ObservedObject var model: InboxBulkPressModel
    var onPress: (InboxRowPress) -> Void = { _ in }

    var body: some View {
        if drawsAnything {
            InboxRowActionsFooter(content: content, bulk: showsResult ? model : nil, onPress: onPress)
        }
    }

    var drawsAnything: Bool { content.hasFooter || showsResult }

    /// A finished press with a result line or Try Again.
    private var showsResult: Bool {
        guard case let .finished(result) = model.state else { return false }
        return InboxBulkPressButton.resultLine(result) != nil || InboxBulkPressButton.offersTryAgain(result)
    }
}
