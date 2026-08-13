import SwiftUI

/// Compact chat panel docked to the right of the Add Email Account cards while
/// the setup assistant is open: header, scrollable message list (house chat
/// bubbles), and a `ChatInput` at the bottom. The input lives OUTSIDE the
/// message ScrollView (nested-NSScrollView collapse — same placement rule as
/// `SituationDiscussInputBar`).
///
/// Split out of `AddEmailAccountView.swift` alongside its Calendar twin
/// (`CalendarSetupAssistantPanel.swift`) — splitting only one half of this
/// "deliberate copy" pair left the other half's shared helper names
/// (`header`/`messageList`/`scrollToBottom`) resolving to two different
/// files instead of one, which is what tipped this file into the sentrux
/// god-file gate; splitting both keeps the pair symmetric.
struct EmailSetupAssistantPanel: View {
    @Bindable var chatVM: EmailSetupChatViewModel
    let makeSnapshot: () -> ImapFormSnapshot
    let onClose: () -> Void

    private let bottomAnchor = "setup-chat-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let err = chatVM.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            ChatInput(
                text: $chatVM.inputText,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.send(snapshot: makeSnapshot()) },
                onStop: { chatVM.cancelStream() },
                placeholder: "e.g. \"my mail is on Yahoo\"",
                dictationTargetID: "chat.setup.email"
            )
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            Text("Setup Assistant")
                .font(.headline)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close the assistant")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chatVM.messages) { msg in
                        MessageBubble(message: msg)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: chatVM.messages.count) { scrollToBottom(proxy) }
            .onChange(of: chatVM.messages.last?.text) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }
}
