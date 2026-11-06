import SwiftUI
import WatchtowerCore

/// A press on a row's native actions.
enum InboxRowPress: Equatable {
    case open, reply, done, hide, snooze(duration: String), discussInChat, handToAgent
    case stopWatching, makeTask, goToTarget, deleteTrack
    case approve, reject, edit, retry, dismiss, notNow(until: String), activate, drop
    case snoozeHour
    /// **Retry** under a failed press: repeats it.
    case retryFailedPress
    case replyChanged(String), proposeReply, cancelReply
}

/// The trailing buttons of a row with a `ref` (plan Task 1: no wiring; Task
/// 13 hands them to A's `ArtifactRefHooks.nativeActions`).
struct InboxRowActionsView: View {
    let content: InboxRowActionsContent
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
        case let .inboxItem(openLabel, openEnabled, canReply, showsHandToAgent):
            if let openLabel {
                Button(openLabel) { onPress(.open) }
                    .disabled(!openEnabled)
            }
            if canReply {
                Button("Reply…") { onPress(.reply) }
                    .disabled(content.reply != nil)
            }
            Button("Done") { onPress(.done) }
            Button("Hide") { onPress(.hide) }
            Menu("Snooze") {
                ForEach(InboxMessagePane.snoozeChoices, id: \.duration) { choice in
                    Button(choice.label) { onPress(.snooze(duration: choice.duration)) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            if !content.isBusy {
                more {
                    Button("Discuss in Chat") { onPress(.discussInChat) }
                    if showsHandToAgent {
                        Button("Hand to Agent…") { onPress(.handToAgent) }
                    }
                }
            }
        case let .track(custom, linkedTargetID):
            Button("Done") { onPress(.done) }
            if !content.isBusy {
                more {
                    Button("Stop watching") { onPress(.stopWatching) }
                    if !custom {
                        Button("Make a Task") { onPress(.makeTask) }
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
            }
        case .reminder:
            Button("Done") { onPress(.done) }
            Button("Snooze 1h") { onPress(.snoozeHour) }
        case let .action(failed):
            if failed {
                Button("Retry") { onPress(.retry) }
                Button("Dismiss") { onPress(.dismiss) }
            } else {
                Button("Approve") { onPress(.approve) }
                Button("Reject") { onPress(.reject) }
                Button("Edit…") { onPress(.edit) }
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if case let .failed(message) = content.state {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button("Retry") { onPress(.retryFailedPress) }
                        .buttonStyle(.kitSecondary)
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
                    .onSubmit { onPress(.proposeReply) }
                    .onExitCommand { onPress(.cancelReply) }
                Button("Propose Reply") { onPress(.proposeReply) }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.isBusy)
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
