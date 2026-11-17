import ChatUI
import SwiftUI
import WatchtowerCore

/// The main chat's composer on the Mac: ChatUI's shared composer over the chat's `ChatComposerModel`, with the Mac's
/// sends (the landing, the ⌘/ panel's screen context), files, paste, focus and its routing accessory. The first
/// keystroke warms the session or makes the landing's chat (`draftStarted`).
struct MainChatComposer: View {
    @Bindable var chatVM: ChatViewModel
    let modelSuggestions: [String]
    let maxHeight: CGFloat
    var placeholder = "Ask about your work…"

    var body: some View {
        ChatComposerView(
            model: chatVM.composer,
            field: ChatComposerFieldConfig(
                placeholder: placeholder,
                maxHeight: maxHeight,
                dictationTargetID: "chat.workspace",
                attachUnavailableReason: chatVM.attachUnavailableReason,
                pdfUnavailableReason: chatVM.pdfUnavailableReason,
                focusRequest: chatVM.composerFocusRequest
            ),
            accessory: AnyView(ChatComposerAccessory(chatVM: chatVM, modelSuggestions: modelSuggestions)),
            onAttachFiles: { chatVM.attachFiles($0) },
            onPasteData: { await chatVM.attachPasted($0, name: $1) },
            onSend: { Task { await chatVM.sendDraft() } },
            attachmentError: chatVM.errorMessage
        )
        .macComposerStyle()
        .onChange(of: chatVM.composer.draft) { old, new in
            if old.isEmpty, !new.isEmpty { Task { await chatVM.draftStarted() } }
        }
    }
}

/// The main chat's routing accessory under the field (the composer's accessory slot): the model that answers, what
/// the provider lacks, the fallback preview and its action, a routing error, and the provider/model pill (off while
/// a turn runs). It refreshes on a chat change, on app activation and at a turn's end.
struct ChatComposerAccessory: View {
    @Bindable var chatVM: ChatViewModel
    let modelSuggestions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            routingState
            modelPill.padding(.horizontal, Spacing.large).padding(.bottom, Spacing.compact)
        }
        .task(id: chatVM.conversationID) { await chatVM.refreshRoutingStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await chatVM.refreshRoutingStatus() }
        }
        .onChange(of: chatVM.isBusy) { _, busy in
            if !busy { Task { await chatVM.refreshRoutingStatus() } }
        }
    }

    @ViewBuilder private var routingState: some View {
        if let presentation = chatVM.routingPresentation {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let actual = presentation.actual { Text(actual).font(.caption).foregroundStyle(.secondary) }
                // U3: what the provider lacks (images among them, U1).
                if let missing = presentation.missingCapabilities {
                    Text(missing).font(.caption).foregroundStyle(.secondary)
                }
                if let preview = presentation.preview {
                    ChatRoutingStatusView(preview: preview, nativeToolsNotice: presentation.nativeToolsNotice, actionEnabled: !chatVM.isBusy,
                                          onAction: routingAction(for: preview))
                }
                if let error = chatVM.routingStatusError {
                    Text(error).font(.caption).foregroundStyle(Tone.warning)
                }
            }
            .padding(.horizontal, Spacing.large)
        }
    }

    private func routingAction(for preview: ProviderFallbackPreview) -> (() -> Void)? {
        guard preview.state == .recovered else { return nil }
        return { chatVM.requestAutomaticRouting() }
    }

    private var modelPill: some View {
        ChatModelPicker(
            provider: chatVM.selectedProvider,
            model: chatVM.selectedModel,
            suggestions: modelSuggestions,
            onSelectProvider: { chatVM.switchProvider($0) },
            onSelectModel: { chatVM.selectModel($0) },
            automatic: chatVM.automaticRouting,
            onSelectAutomatic: chatVM.requestAutomaticRouting
        )
        .disabled(chatVM.isBusy)
    }
}

/// The provider/model pill of a chat composer: the main chat's, and the
/// code questions' (spec 2026-10-02 §9.1). `model` "" is Auto — the
/// provider's default tier.
struct ChatModelPicker: View {
    let provider: AIProvider
    let model: String
    let suggestions: [String]
    let onSelectProvider: (AIProvider) -> Void
    let onSelectModel: (String) -> Void
    var automatic = false
    var onSelectAutomatic: (() -> Void)?

    var body: some View {
        Menu {
            if let onSelectAutomatic {
                Button(ProviderFallbackPreview.automaticChoice, action: onSelectAutomatic)
            }
            Section("Provider") {
                ForEach(AIProvider.offered(by: .shared, current: provider)) { provider in
                    Button(ProviderFallbackPreview.pinnedChoice(provider: provider.displayName)) { onSelectProvider(provider) }
                }
            }
            Section("Model") {
                Button("Auto") { onSelectModel("") }
                ForEach(suggestions, id: \.self) { model in
                    Button(model) { onSelectModel(model) }
                }
            }
        } label: {
            Text(automatic ? ProviderFallbackPreview.chatPolicyAutomatic + " · Auto"
                 : ProviderFallbackPreview.pinnedChoice(provider: provider.displayName, model: model))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Provider and model for this chat")
    }
}
