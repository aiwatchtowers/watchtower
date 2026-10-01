import SwiftUI
import WatchtowerCore

/// Compact chat panel docked to the right of an Add Account sheet's connect
/// cards while its setup assistant is open: a header with Close over the
/// shared embedded chat (compact). The chat reads the form through its
/// `snapshotProvider` on every turn — never a credential (`SetupAssistantChat`).
struct SetupAssistantPanel<Snapshot, Patch>: View {
    let chatVM: SetupAssistantChat<Snapshot, Patch>
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
