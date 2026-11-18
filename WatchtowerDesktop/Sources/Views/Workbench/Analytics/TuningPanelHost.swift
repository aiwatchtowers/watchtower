import SwiftUI
import WatchtowerCore

/// The tuning panel's host: builds the workbench's `TuningChat` once (the
/// engine lives in the embedded-chat center, so a turn outlives the panel)
/// and closes its view of it when the panel goes — also a chat that was
/// still being built then.
struct TuningPanelHost: View {
    typealias MakeChat = @MainActor (Int64) async throws -> TuningChat?

    let workbenchID: Int64
    let makeChat: MakeChat
    let coach: CoachCenter?
    let inputs: TuningPanelInputs
    let actions: CoachActions
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onShowAccepted: (Int64) -> Void
    @State private var chat: TuningChat?
    @State private var error: String?
    /// Bumped by Retry: the task builds the chat again.
    @State private var attempt = 0

    private struct Load: Hashable {
        let workbenchID: Int64
        let attempt: Int
    }

    var body: some View {
        Group {
            if let chat {
                TuningPanelView(chat: chat, coach: coach, figures: inputs.figures, starters: inputs.starters,
                                loading: inputs.loading, actions: actions, onClose: onClose,
                                onOpenSettings: onOpenSettings, onShowAccepted: onShowAccepted)
            } else if let error {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Tone.warning)
                    Button(TuningChatTexts.retry) { attempt += 1 }
                        .buttonStyle(.kitSecondary)
                        .controlSize(.small)
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: Load(workbenchID: workbenchID, attempt: attempt)) { await load() }
        .onDisappear {
            chat?.close()
            chat = nil
        }
    }

    private func load() async {
        chat?.close()
        chat = nil
        error = nil
        let made: TuningChat?
        do {
            made = try await makeChat(workbenchID)
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { self.error = TuningChatTexts.openFailed(error.localizedDescription) }
            return
        }
        // The panel went (or the workbench changed) while the chat was built:
        // nothing shows it, so it closes at once.
        guard !Task.isCancelled else {
            made?.close()
            return
        }
        guard let made else {
            error = TuningChatTexts.notReady
            return
        }
        chat = made
    }
}
