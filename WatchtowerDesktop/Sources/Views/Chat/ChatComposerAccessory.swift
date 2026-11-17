import ChatUI
import SwiftUI
import WatchtowerCore

/// The main chat's composer on the Mac: ChatUI's shared composer over the chat's `ChatComposerModel`, with the Mac's
/// sends (the landing, the ⌘/ panel's screen context), files, paste, focus and the shared routing pill
/// (`ChatViewModel.routing`, under the field). The first keystroke warms the session or makes the landing's chat
/// (`draftStarted`).
struct MainChatComposer: View {
    @Bindable var chatVM: ChatViewModel
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
            routing: chatVM.routing,
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
