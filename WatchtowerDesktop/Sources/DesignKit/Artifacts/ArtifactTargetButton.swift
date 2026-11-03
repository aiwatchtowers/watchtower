import SwiftUI

/// A `target` button's state, read from its newest proposal (spec "The
/// Desktop button"). The one state type of the button and of the approval
/// card of its proposal; the app maps its facts onto it.
public enum ArtifactTargetButtonState: Equatable, Sendable {
    /// No proposal, or the last one rejected, dismissed, or its task deleted: pressable.
    case idle
    /// Pending: a click opens the approval card.
    case waiting
    /// Approved or executing, still in flight.
    case creating
    /// Approved or executing two minutes after approval with nothing working on it.
    case stuck
    /// Applied and its task exists: a click opens it.
    case created
    /// The apply failed: the error line and **Try again** on the same proposal.
    case failed(message: String)
    /// The press itself failed (no proposal written): pressable, with the reason.
    case proposeError(message: String)
}

/// A recipe's `target` action: the press proposes a task, which the owner
/// approves in the approval card. A pure view over its state.
public struct ArtifactTargetButton: View {
    let label: String
    let state: ArtifactTargetButtonState
    let mode: ArtifactRenderMode
    let action: () -> Void

    public init(
        label: String,
        state: ArtifactTargetButtonState,
        mode: ArtifactRenderMode,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.state = state
        self.mode = mode
        self.action = action
    }

    public var body: some View {
        if mode == .preview {
            idleButton
                .disabled(true)
                .help(ArtifactRenderMode.previewButtonHelp)
        } else {
            content
        }
    }

    /// Every state but idle keeps the recipe's label for VoiceOver:
    /// "Sign off the checklist: Task created".
    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            idleButton
        case .waiting:
            Button(action: action) { Label("Waiting for approval", systemImage: "checklist") }
                .buttonStyle(.kitSecondary)
                .foregroundStyle(.secondary)
                .help("Open the approval card")
                .accessibilityLabel(spoken("Waiting for approval"))
        case .creating:
            Button(action: {}, label: {
                HStack(spacing: Spacing.small) {
                    ProgressView().controlSize(.mini)
                    Text("Creating task…")
                }
            })
            .buttonStyle(.kitSecondary)
            .disabled(true)
            .accessibilityLabel(spoken("Creating task"))
        case .stuck:
            ArtifactTargetStuckLine(onTryAgain: action)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(spoken("Didn't finish"))
        case .created:
            Button(action: action) { Label("Task created", systemImage: "checkmark") }
                .buttonStyle(.kitSecondary)
                .help("Open the task")
                .accessibilityLabel(spoken("Task created"))
        case let .failed(message):
            VStack(alignment: .trailing, spacing: Spacing.small) {
                Button("Try again", action: action)
                    .buttonStyle(.kitSecondary)
                    .help("Apply the same proposal again")
                    .accessibilityLabel(spoken("Try again"))
                errorLine("Couldn't create the task: \(message)")
            }
        case let .proposeError(message):
            VStack(alignment: .trailing, spacing: Spacing.small) {
                idleButton
                errorLine("Couldn't propose the task: \(message)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(spoken("Couldn't propose the task"))
        }
    }

    private var idleButton: some View {
        Button(action: action) { Label(label, systemImage: "checklist") }
            .buttonStyle(.kitSecondary)
    }

    private func spoken(_ state: String) -> String {
        "\(label): \(state)"
    }

    /// The one error look of the button: why the apply or the press failed.
    private func errorLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Tone.error)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// "Didn't finish" with **Try again**: a proposal stuck in approved or
/// executing, on the target button and on its approval card. Try again
/// applies the same proposal; it never proposes a second task.
public struct ArtifactTargetStuckLine: View {
    let onTryAgain: () -> Void

    public init(onTryAgain: @escaping () -> Void) {
        self.onTryAgain = onTryAgain
    }

    public var body: some View {
        HStack(spacing: Spacing.regular) {
            Label("Didn't finish", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Tone.warning)
            Button("Try again", action: onTryAgain)
                .buttonStyle(.kitSecondary)
                .help("Creating the task didn't finish. Try again applies the same proposal.")
        }
    }
}
