import SwiftUI

/// A line above a composer about the turn it sends.
enum ChatComposerStatus: Equatable {
    /// The message waits for a free slot; Cancel puts it back in the field.
    case queued
    /// A failure not tied to a message (a send that could not be saved).
    case error(String)
}

/// The composer every chat shares: an optional status line, the input field
/// (`ChatInput`: Enter sends, Shift+Enter newline, Esc stops, dictation) and
/// an optional accessory row under it (the main chat's provider/model pill).
struct ChatComposerBar<Accessory: View>: View {
    var status: ChatComposerStatus?
    var onCancelQueued: () -> Void = {}
    let input: ChatInput
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusLine
            input
            accessory()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .queued:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Queued — waiting for a free assistant slot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancelQueued)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 16)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 4)
        case nil:
            EmptyView()
        }
    }
}

extension ChatComposerBar where Accessory == EmptyView {
    init(status: ChatComposerStatus? = nil, onCancelQueued: @escaping () -> Void = {}, input: ChatInput) {
        self.init(status: status, onCancelQueued: onCancelQueued, input: input) { EmptyView() }
    }
}
