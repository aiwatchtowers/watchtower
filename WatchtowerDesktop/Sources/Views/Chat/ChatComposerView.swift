import SwiftUI
import WatchtowerCore

/// Spec §3.5: Enter send, Shift+Enter newline, Esc stop, ↑ in an empty field
/// edits the last message, dictation, and the provider/model pill. Grows to
/// `maxHeight` (~40% of the window). The first keystroke prewarms the session.
struct ChatComposerView: View {
    @Bindable var chatVM: ChatViewModel
    let modelSuggestions: [String]
    let maxHeight: CGFloat
    /// The caret at the time of the last edit (UTF-16 offset) — needed to
    /// resolve the active `@`/`/` trigger on a mouse-click pick, which carries
    /// no caret of its own (spec §6.2).
    @State private var lastCursor = 0
    @Environment(\.recordingIndicatorInset) private var recordingIndicatorInset

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
            ComposerChipsRow(
                mentions: chatVM.composer.mentions,
                skill: chatVM.composer.skill,
                onRemoveMention: { chatVM.composer.removeMention($0) },
                onRemoveSkill: { chatVM.composer.clearSkill() }
            )
            VStack(alignment: .leading, spacing: 2) {
                ChatInput(
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
                    onPickerKey: { key, text, cursor in chatVM.composer.handle(key, text: text, cursor: cursor) }
                )
                modelPill.padding(.horizontal, 16).padding(.bottom, 6)
            }
            // The whole composer (model pill included) keeps clear of the
            // recorder pills below, so the inner input must not add it again.
            .environment(\.recordingIndicatorInset, 0)
        }
        .padding(.bottom, recordingIndicatorInset)
        .onChange(of: chatVM.draft) { old, new in
            if old.isEmpty, !new.isEmpty { chatVM.prewarm() }
        }
    }

    private var modelPill: some View {
        Menu {
            Section("Provider") {
                ForEach(AIProvider.allCases) { provider in
                    Button(provider.displayName) { chatVM.switchProvider(provider) }
                }
            }
            Section("Model") {
                Button("Auto") { chatVM.selectedModel = "" }
                ForEach(modelSuggestions, id: \.self) { model in
                    Button(model) { chatVM.selectedModel = model }
                }
            }
        } label: {
            Text("\(chatVM.selectedProvider.displayName) · \(chatVM.selectedModel.isEmpty ? "Auto" : chatVM.selectedModel)")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(chatVM.isStreaming)
        .help("Provider and model for this chat")
    }
}
