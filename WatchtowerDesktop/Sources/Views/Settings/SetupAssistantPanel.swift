import SwiftUI
import WatchtowerCore

/// Compact chat panel docked to the right of an Add Account sheet's connect
/// cards while its setup assistant is open: a header with Close over the
/// shared embedded chat (compact). The chat reads the form through
/// `makeSnapshot` on every turn — never a credential (`SetupAssistantChat`).
struct SetupAssistantPanel<Snapshot, Patch>: View {
    let chatVM: SetupAssistantChat<Snapshot, Patch>
    let makeSnapshot: () -> Snapshot
    let placeholder: String
    let dictationTargetID: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            EmbeddedChatView(engine: chatVM.engine, density: .compact, placeholder: placeholder,
                             dictationTargetID: dictationTargetID)
        }
        .onAppear { chatVM.snapshotProvider = makeSnapshot }
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
}

extension SetupAssistantPanel where Snapshot == CalendarFormSnapshot, Patch == CalendarSettingsPatch {
    init(chatVM: CalendarSetupChatViewModel, makeSnapshot: @escaping () -> CalendarFormSnapshot,
         onClose: @escaping () -> Void) {
        self.init(chatVM: chatVM, makeSnapshot: makeSnapshot, placeholder: "e.g. \"my calendar is on iCloud\"",
                  dictationTargetID: "chat.setup.calendar", onClose: onClose)
    }
}

extension SetupAssistantPanel where Snapshot == ImapFormSnapshot, Patch == ImapSettingsPatch {
    init(chatVM: EmailSetupChatViewModel, makeSnapshot: @escaping () -> ImapFormSnapshot,
         onClose: @escaping () -> Void) {
        self.init(chatVM: chatVM, makeSnapshot: makeSnapshot, placeholder: "e.g. \"my mail is on Yahoo\"",
                  dictationTargetID: "chat.setup.email", onClose: onClose)
    }
}

typealias CalendarSetupAssistantPanel = SetupAssistantPanel<CalendarFormSnapshot, CalendarSettingsPatch>
typealias EmailSetupAssistantPanel = SetupAssistantPanel<ImapFormSnapshot, ImapSettingsPatch>
