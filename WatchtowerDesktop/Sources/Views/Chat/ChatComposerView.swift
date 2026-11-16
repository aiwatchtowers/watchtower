import ChatUI
import SwiftUI
import WatchtowerCore

/// Spec §3.5: Enter send, Shift+Enter newline, Esc stop, ↑ in an empty field
/// edits the last message, dictation, the `@`/`/` picker keys, attachment chips
/// and the provider/model pill — the Mac's composer over ChatUI's
/// `ChatComposerModel` (its send waits for the engine's echo, CHAT-01), with the
/// state line when the chat cannot be reached. Grows to `maxHeight`.
struct ChatComposerView: View {
    @Bindable var chatVM: ChatViewModel
    let modelSuggestions: [String]
    let maxHeight: CGFloat
    var placeholder = "Ask about your work…"
    /// The caret at the time of the last edit (UTF-16 offset) — needed to
    /// resolve the active `@`/`/` trigger on a mouse-click pick, which carries
    /// no caret of its own (spec §6.2).
    @State private var lastCursor = 0

    private var composer: ChatComposerModel { chatVM.composer }
    private var picker: ComposerPickerModel { chatVM.picker }

    /// The draft, read through the shell: the composer model changes with the chat on screen.
    private var draft: Binding<String> {
        Binding(get: { chatVM.composer.draft }, set: { chatVM.composer.draft = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let line = composer.stateLine {
                ChatStateLineView(content: line) { chatVM.conversation.performStateAction() }
                    .padding(.horizontal, Spacing.large)
            }
            if picker.isOpen {
                ComposerPickerList(items: picker.items, selectedIndex: picker.selectedIndex) { index in
                    if let edit = picker.accept(index: index, text: composer.draft, cursor: lastCursor) {
                        composer.draft = edit.text
                        lastCursor = edit.cursor
                    }
                }
            }
            if !composer.quotes.isEmpty {
                QuoteBatchView(
                    quotes: composer.quotes,
                    onEditComment: { id, comment in
                        if let index = composer.quotes.firstIndex(where: { $0.id == id }) {
                            composer.quotes[index].comment = comment
                        }
                    },
                    onRemove: { id in composer.quotes.removeAll { $0.id == id } }
                )
            }
            ComposerChipsRow(
                mentions: picker.mentions,
                skill: picker.skill,
                onRemoveMention: { picker.removeMention($0) },
                onRemoveSkill: { picker.clearSkill() }
            )
            ChatComposerBar(status: (composer.notice ?? chatVM.conversation.notice).map(ChatComposerStatus.error), input: ChatComposerField(
                text: draft,
                isStreaming: chatVM.isBusy,
                onSend: { Task { await chatVM.sendDraft() } },
                onStop: chatVM.conversation.canStop ? { chatVM.stop() } : nil,
                placeholder: placeholder,
                dictationTargetID: "chat.workspace",
                maxHeight: maxHeight,
                onEscape: { chatVM.stop() },
                onArrowUpWhenEmpty: { chatVM.beginEditingLast() },
                attachments: composer.attachments.map(Self.chip),
                attachmentError: chatVM.errorMessage,
                onAttachFiles: { chatVM.attachFiles($0) },
                onPasteData: { await chatVM.attachPasted($0, name: $1) },
                onRemoveAttachment: { id in Task { await composer.removeAttachment(id) } },
                attachmentProgress: AttachmentProgress(importing: composer.importing, removing: composer.removing,
                                                       sendWaits: composer.isWaitingForAttachments),
                attachUnavailableReason: chatVM.attachUnavailableReason,
                pdfUnavailableReason: chatVM.pdfUnavailableReason,
                onCursorChange: { text, cursor in
                    lastCursor = cursor
                    picker.update(text: text, cursor: cursor)
                },
                onPickerKey: { key, text, cursor in picker.handle(key, text: text, cursor: cursor) },
                hasPendingContent: !composer.quotes.isEmpty,
                focusRequest: chatVM.composerFocusRequest,
                sendBlocked: chatVM.conversation.reachability != .connected || chatVM.conversation.isGone
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
        .onChange(of: chatVM.composer.draft) { old, new in
            if old.isEmpty, !new.isEmpty { Task { await chatVM.draftStarted() } }
        }
    }

    /// A composer attachment as the field's chip shows it (name only: the engine stored the file).
    private static func chip(_ attachment: ChatComposerAttachment) -> ChatAttachment {
        ChatAttachment(id: attachment.id, conversationID: nil, projectID: nil, messageID: nil, name: attachment.name,
                       mime: attachment.mime, size: attachment.size, path: "", sha256: "", createdAt: 0)
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
