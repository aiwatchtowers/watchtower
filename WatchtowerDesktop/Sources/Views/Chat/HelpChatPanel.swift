import AppKit
import ChatUI
import SwiftUI
import WatchtowerCore

/// The ⌘/ popup: the main AI Chat (same `ChatViewModel`, feed and composer)
/// as a panel over any tab. A turn sent from here carries the current-screen
/// block, which is prefixed to the provider text only and never stored.
struct HelpChatPanel: View {
    @Environment(AppState.self) private var appState
    @Bindable var chatVM: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ChatThreadView(chatVM: chatVM, ownerName: appState.owner.displayName)
            if let line = chatVM.composer.stateLine {
                ChatStateLineView(content: line) { chatVM.conversation.performStateAction() }
                    .padding(.horizontal, Spacing.medium)
            }
            ChatComposerBar(input: ChatComposerField(
                text: Binding(get: { chatVM.composer.draft }, set: { chatVM.composer.draft = $0 }),
                isStreaming: chatVM.isBusy,
                onSend: send,
                onStop: chatVM.conversation.canStop ? { chatVM.stop() } : nil,
                placeholder: "Ask how Watchtower works…",
                maxHeight: 120,
                // Esc stops a running answer first, then closes the panel.
                onEscape: escape,
                autoFocus: true,
                sendBlocked: chatVM.conversation.reachability != .connected || chatVM.conversation.isGone
            ))
        }
        .frame(width: 420, height: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(radius: 12, y: 4)
        .onExitCommand(perform: escape)
        .onChange(of: chatVM.composer.draft) { old, new in
            if old.isEmpty, !new.isEmpty { Task { await chatVM.draftStarted() } }
        }
        .macChatStyle(hooks: .app)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask Watchtower")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Ask Watchtower").font(.headline)
            Spacer()
            // The tab's own New: no empty conversation row until a send.
            Button("New") { chatVM.showLanding() }
                .disabled(chatVM.isBusy)
            Button("Open in Chats") {
                appState.selectedDestination = .chat
                close()
            }
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
        }
        .buttonStyle(.link)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func escape() {
        if chatVM.conversation.isTurnRunning { chatVM.stop() } else { close() }
    }

    private func close() { appState.isHelpChatShown = false }

    /// The typed words are stored as they are; the screen block rides along.
    private func send() {
        let screen = appState.currentScreenContext()
        Task { await chatVM.sendDraft(screen: screen) }
    }
}
