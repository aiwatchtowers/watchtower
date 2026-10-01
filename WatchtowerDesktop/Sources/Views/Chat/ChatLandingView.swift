import SwiftUI
import WatchtowerCore

/// What the Chat tab shows outside the resume window (owner decision
/// 2026-09-28): a new-chat composer front and centre, the starter prompts,
/// and the pinned + recent chats to jump back into.
struct ChatLandingView: View {
    @Bindable var chatVM: ChatViewModel
    let recents: [ChatConversation]
    let ownerName: String
    let modelSuggestions: [String]
    let maxComposerHeight: CGFloat
    let onOpen: (Int64) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ChatEmptyState(ownerName: ownerName, onPrompt: usePrompt)
                ChatComposerView(
                    chatVM: chatVM,
                    modelSuggestions: modelSuggestions,
                    maxHeight: maxComposerHeight,
                    clearsRecordingIndicator: false
                )
                if let error = chatVM.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                if !recents.isEmpty { recentList }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
            // The recent list is the landing's bottom-most content.
            .clearsRecordingIndicator()
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent chats")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(recents) { conv in
                Button { onOpen(conv.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: conv.pinned ? "pin.fill" : "bubble.left")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(conv.displayTitle).lineLimit(1)
                        Spacer()
                        Text(conv.updatedDate.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(conv.pinned ? "Pinned chat: \(conv.displayTitle)" : "Chat: \(conv.displayTitle)")
            }
        }
        .padding(.horizontal, 16)
    }

    private func usePrompt(_ prompt: ChatStarterPrompt) {
        if prompt.sendsImmediately {
            chatVM.send(text: prompt.text)
        } else {
            chatVM.draft = prompt.text
        }
    }
}
