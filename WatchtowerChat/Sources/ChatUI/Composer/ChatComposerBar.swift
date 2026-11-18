import SwiftUI
import WatchtowerDesign

/// A line above a composer about the turn it sends.
public enum ChatComposerStatus: Equatable {
    /// The message waits for a free slot; Cancel puts it back in the field.
    case queued
    /// A failure not tied to a message (a send that could not be saved).
    case error(String)
    /// The reply is in and its changes are being written; it cannot be stopped any more.
    case finishing
    /// A turn of this chat runs on another device (the phone, spec 2026-11-15 §5, mockup 4a): the field shows
    /// Stop, Send waits.
    case elsewhere(String)
}

/// The composer every chat shares: an optional status line, the input field (`ChatComposerField`: Enter sends,
/// Shift+Enter a new line, Esc stops, dictation) and an optional accessory row under it (the main chat's routing
/// accessory).
public struct ChatComposerBar<Accessory: View>: View {
    var status: ChatComposerStatus?
    var onCancelQueued: () -> Void
    let input: ChatComposerField
    let accessory: Accessory

    public init(
        status: ChatComposerStatus?,
        onCancelQueued: @escaping () -> Void = {},
        input: ChatComposerField,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.status = status
        self.onCancelQueued = onCancelQueued
        self.input = input
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            statusLine
            input
            accessory
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .queued:
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text("Queued — waiting for a free assistant slot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancelQueued)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, ComposerMetrics.inset)
        case .finishing:
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text("Applying the reply’s changes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, ComposerMetrics.inset)
        case .elsewhere(let line):
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, ComposerMetrics.inset)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ComposerMetrics.inset)
                .padding(.top, Spacing.small)
        case nil:
            EmptyView()
        }
    }
}

extension ChatComposerBar where Accessory == EmptyView {
    public init(status: ChatComposerStatus? = nil, onCancelQueued: @escaping () -> Void = {}, input: ChatComposerField) {
        self.init(status: status, onCancelQueued: onCancelQueued, input: input) { EmptyView() }
    }
}
