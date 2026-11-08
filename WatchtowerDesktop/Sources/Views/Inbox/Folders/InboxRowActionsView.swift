import SwiftUI
import WatchtowerCore

/// The trailing buttons of a row with a `ref`, drawn through A's
/// `ArtifactRefHooks.nativeActions` (`InboxRefHooks`).
struct InboxRowActionsView: View {
    let content: InboxRowActionsContent
    var onPress: (InboxRowPress) -> Void = { _ in }

    /// A proposal's own summary beside its buttons: one line, cut at this width.
    static let summaryWidth: CGFloat = 280

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
        case let .inboxItem(openLabel, openEnabled, canReply, showsHandToAgent):
            if let openLabel {
                Button(openLabel) { onPress(.open) }
                    .disabled(!openEnabled)
            }
            if canReply {
                Button("Reply…") { onPress(.reply) }
                    .disabled(content.reply != nil || content.isOff(.reply))
            }
            Button("Done") { onPress(.done) }.disabled(content.isOff(.done))
            Button("Hide") { onPress(.hide) }.disabled(content.isOff(.hide))
            Menu("Snooze") {
                ForEach(InboxMessagePane.snoozeChoices, id: \.duration) { choice in
                    Button(choice.label) { onPress(.snooze(duration: choice.duration)) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(content.isOff(.snooze(duration: "")))
            if !content.isBusy {
                more {
                    Button("Discuss in Chat") { onPress(.discussInChat) }
                    if showsHandToAgent {
                        Button("Hand to Agent…") { onPress(.handToAgent) }
                    }
                }
            }
        case let .track(custom, linkedTargetID):
            Button("Done") { onPress(.done) }.disabled(content.isOff(.done))
            if !content.isBusy {
                more {
                    Button("Stop watching") { onPress(.stopWatching) }.disabled(content.isOff(.stopWatching))
                    if !custom {
                        Button("Make a Task") { onPress(.makeTask) }.disabled(content.isOff(.makeTask))
                    }
                    if custom, linkedTargetID != nil {
                        Button("Go to Target") { onPress(.goToTarget) }
                    }
                    if custom {
                        Button("Delete…") { onPress(.deleteTrack) }
                    }
                }
            }
        case let .idea(kind, status, awaitsVerdict):
            ForEach(InboxRowActionsContent.ideaButtons(kind: kind, status: status, awaitsVerdict: awaitsVerdict),
                    id: \.self) { button in
                ideaButton(button)
                    .disabled(content.isOff(.approve)) // every idea verdict writes
            }
        case .reminder:
            Button("Done") { onPress(.done) }.disabled(content.isOff(.done))
            Button("Snooze 1h") { onPress(.snoozeHour) }.disabled(content.isOff(.snoozeHour))
        case let .action(summary, buttons):
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Self.summaryWidth, alignment: .trailing)
                .help(summary)
                .accessibilityIdentifier("inboxRow.actionSummary")
            ForEach(buttons, id: \.self) { button in
                actionButton(button)
                    .disabled(content.isOff(button.press))
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ button: InboxRowActionsContent.ActionButton) -> some View {
        switch button {
        case .approve: Button("Approve") { onPress(.approve) }
        case .reject: Button("Reject") { onPress(.reject) }
        case .edit:
            Button("Edit…") { onPress(.edit) }
                .help("Open the full proposal")
        case .openDraft:
            Button("Open Draft") { onPress(.openDraft) }
                .help("Read the whole recipe in the editor and save it there")
        case .retry: Button("Retry") { onPress(.retry) }
        case .dismiss:
            Button("Dismiss") { onPress(.dismiss) }
                .help(ConnectorCallProposal.dismissNote)
        }
    }

    @ViewBuilder
    private func ideaButton(_ button: InboxRowActionsContent.IdeaButton) -> some View {
        switch button {
        case .approve: Button("Approve") { onPress(.approve) }
        case .makeTask: Button("Make a Task") { onPress(.makeTask) }
        case .notNow:
            Menu("Not now") {
                ForEach(IdeaNotNow.allCases, id: \.label) { choice in
                    Button(choice.label) { onPress(.notNow(until: choice.until())) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
        case .reject: Button("Reject", role: .destructive) { onPress(.reject) }
        case .activate: Button("Activate") { onPress(.activate) }
        case .drop: Button("Drop", role: .destructive) { onPress(.drop) }
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

/// What sits under a row with a `ref`: a failed press's error with
/// **Retry**, the Reply composer (or its refusal), or "Reply waiting for
/// approval". Nothing for an idle row.
struct InboxRowActionsFooter: View {
    let content: InboxRowActionsContent
    var onPress: (InboxRowPress) -> Void = { _ in }

    /// The composer's field has the keyboard: only then does ⌘↩ propose,
    /// so two open composers never answer the same press.
    @FocusState private var composing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if content.cliMissing {
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
                    Button("Retry") { onPress(.retryFailedPress) }
                        .buttonStyle(.kitSecondary)
                        .disabled(content.isOff(.retryFailedPress))
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
                Button("Propose Reply") { onPress(.proposeReply) }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(composing ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.isBusy
                              || content.isOff(.proposeReply))
                Button("Cancel") { onPress(.cancelReply) }
                    .buttonStyle(.kitQuiet)
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
