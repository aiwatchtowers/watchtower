import SwiftUI
import WatchtowerCore

/// Spec §3.5: Enter send, Shift+Enter newline, Esc stop, ↑ in an empty field
/// edits the last message, dictation, and the provider/model pill. Grows to
/// `maxHeight` (~40% of the window). The first keystroke prewarms the session.
struct ChatComposerView: View {
    @Bindable var chatVM: ChatViewModel
    let modelSuggestions: [String]
    let maxHeight: CGFloat
    var placeholder = "Ask about your work…"
    /// The caret at the time of the last edit (UTF-16 offset) — needed to
    /// resolve the active `@`/`/` trigger on a mouse-click pick, which carries
    /// no caret of its own (spec §6.2).
    @State private var lastCursor = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if chatVM.composer.isOpen {
                ComposerPickerList(items: chatVM.composer.items, selectedIndex: chatVM.composer.selectedIndex) { index in
                    if let edit = chatVM.composer.accept(index: index, text: chatVM.draft, cursor: lastCursor) {
                        chatVM.draft = edit.text
                        lastCursor = edit.cursor
                    }
                }
            }
            if !chatVM.pendingQuotes.isEmpty {
                QuoteBatchView(
                    quotes: chatVM.pendingQuotes,
                    onEditComment: { chatVM.updateQuoteComment(id: $0, comment: $1) },
                    onRemove: { chatVM.removeQuote(id: $0) }
                )
            }
            ComposerChipsRow(
                mentions: chatVM.composer.mentions,
                skill: chatVM.composer.skill,
                onRemoveMention: { chatVM.composer.removeMention($0) },
                onRemoveSkill: { chatVM.composer.clearSkill() }
            )
            ChatComposerBar(input: ChatComposerField(
                text: $chatVM.draft,
                isStreaming: chatVM.isBusy,
                onSend: { Task { await chatVM.sendDraft() } },
                // Nothing to stop while the turn's rows are being written.
                onStop: chatVM.canStop ? { chatVM.stop() } : nil,
                placeholder: placeholder,
                dictationTargetID: "chat.workspace",
                maxHeight: maxHeight,
                onEscape: { chatVM.stop() },
                onArrowUpWhenEmpty: { chatVM.beginEditingLast() },
                attachments: chatVM.composerAttachments.pending,
                attachmentError: chatVM.composerAttachments.errorMessage,
                onAttachFiles: { chatVM.attachFiles($0) },
                onPasteData: { await chatVM.attachPasted($0, name: $1) },
                onRemoveAttachment: { chatVM.composerAttachments.remove(id: $0) },
                attachmentProgress: AttachmentProgress(importing: chatVM.composerAttachments.importing,
                                                       removing: chatVM.composerAttachments.removing,
                                                       sendWaits: chatVM.isWaitingForAttachments),
                attachUnavailableReason: chatVM.attachUnavailableReason,
                pdfUnavailableReason: chatVM.pdfUnavailableReason,
                onCursorChange: { text, cursor in
                    lastCursor = cursor
                    chatVM.composer.update(text: text, cursor: cursor)
                },
                onPickerKey: { key, text, cursor in chatVM.composer.handle(key, text: text, cursor: cursor) },
                hasPendingContent: !chatVM.pendingQuotes.isEmpty,
                focusRequest: chatVM.composerFocusRequest
            )) {
                routingState
                modelPill.padding(.horizontal, 16).padding(.bottom, 6)
            }
        }
        .task(id: chatVM.conversationID) { await chatVM.refreshRoutingStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await chatVM.refreshRoutingStatus() }
        }
        .onChange(of: chatVM.isBusy) { _, busy in
            if !busy { Task { await chatVM.refreshRoutingStatus() } }
        }
        .onChange(of: chatVM.draft) { old, new in
            if old.isEmpty, !new.isEmpty { Task { await chatVM.draftStarted() } }
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
                    ChatRoutingStatusView(preview: preview, actionEnabled: !chatVM.isBusy,
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
        return { Task { await chatVM.useAutomaticRouting() } }
    }

    private var modelPill: some View {
        ChatModelPicker(
            provider: chatVM.selectedProvider,
            model: chatVM.selectedModel,
            suggestions: modelSuggestions,
            onSelectProvider: { chatVM.switchProvider($0) },
            onSelectModel: { chatVM.selectedModel = $0 },
            automatic: chatVM.automaticRouting,
            onSelectAutomatic: chatVM.requestAutomaticRouting
        )
        // Also while a turn's end is written (board #670): a pick then would
        // close the session under it.
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
