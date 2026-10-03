import SwiftUI
import WatchtowerCore

/// Spec §3.5: Enter send, Shift+Enter newline, Esc stop, ↑ in an empty field
/// edits the last message, dictation, and the provider/model pill. Grows to
/// `maxHeight` (~40% of the window). The first keystroke prewarms the session.
struct ChatComposerView: View {
    @Bindable var chatVM: ChatViewModel
    let modelSuggestions: [String]
    let maxHeight: CGFloat
    /// The thread's composer is the chat's bottom-most content; on the
    /// landing the recent list sits below it and clears the pills instead.
    var clearsRecordingIndicator = true
    /// The caret at the time of the last edit (UTF-16 offset) — needed to
    /// resolve the active `@`/`/` trigger on a mouse-click pick, which carries
    /// no caret of its own (spec §6.2).
    @State private var lastCursor = 0

    private var composer: some View {
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
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.sendDraft() },
                onStop: { chatVM.stop() },
                placeholder: "Ask about your work…",
                dictationTargetID: "chat.workspace",
                maxHeight: maxHeight,
                onEscape: { chatVM.stop() },
                onArrowUpWhenEmpty: { chatVM.beginEditingLast() },
                attachments: chatVM.composerAttachments.pending,
                attachmentError: chatVM.composerAttachments.errorMessage,
                onAttachFiles: { chatVM.attachFiles($0) },
                onPasteImage: { chatVM.attachPastedImage($0) },
                onRemoveAttachment: { chatVM.composerAttachments.remove(id: $0) },
                onCursorChange: { text, cursor in
                    lastCursor = cursor
                    chatVM.composer.update(text: text, cursor: cursor)
                },
                onPickerKey: { key, text, cursor in chatVM.composer.handle(key, text: text, cursor: cursor) },
                hasPendingContent: !chatVM.pendingQuotes.isEmpty
            )) {
                modelPill.padding(.horizontal, 16).padding(.bottom, 6)
            }
        }
        .onChange(of: chatVM.draft) { old, new in
            if old.isEmpty, !new.isEmpty { chatVM.draftStarted() }
        }
    }

    var body: some View {
        if clearsRecordingIndicator {
            // The main chat's bottom-most content, model pill included.
            composer.clearsRecordingIndicator()
        } else {
            composer
        }
    }

    private var modelPill: some View {
        ChatModelPicker(
            provider: chatVM.selectedProvider,
            model: chatVM.selectedModel,
            suggestions: modelSuggestions,
            onSelectProvider: { chatVM.switchProvider($0) },
            onSelectModel: { chatVM.selectedModel = $0 }
        )
        .disabled(chatVM.isStreaming)
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

    var body: some View {
        Menu {
            Section("Provider") {
                ForEach(AIProvider.allCases) { provider in
                    Button(provider.displayName) { onSelectProvider(provider) }
                }
            }
            Section("Model") {
                Button("Auto") { onSelectModel("") }
                ForEach(suggestions, id: \.self) { model in
                    Button(model) { onSelectModel(model) }
                }
            }
        } label: {
            Text("\(provider.displayName) · \(model.isEmpty ? "Auto" : model)")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Provider and model for this chat")
    }
}
