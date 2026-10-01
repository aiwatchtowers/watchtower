import SwiftUI
import WatchtowerCore

/// The chat inspector: the artifact panel or the sources panel, with an
/// Artifact | Sources switch when both are open (`ChatInspectorPolicy`).
struct ChatInspectorContent: View {
    @Bindable var chatVM: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            if ChatInspectorPolicy.showsTabs(artifactOpen: chatVM.artifactPanel != nil, sourcesOpen: chatVM.sourcesPanel != nil) {
                Picker("Panel", selection: modeBinding) {
                    Text("Artifact").tag(ChatInspectorMode.artifacts)
                    Text("Sources").tag(ChatInspectorMode.sources)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            panel
        }
    }

    @ViewBuilder private var panel: some View {
        switch chatVM.inspectorMode {
        case .artifacts:
            if let panel = chatVM.artifactPanel {
                ArtifactPanelView(
                    model: panel, gmailConnected: chatVM.gmailConnected, slackLinks: chatVM.slackLinks,
                    canSendComments: !chatVM.isStreaming,
                    onSendComments: { chatVM.sendArtifactComments() },
                    onClose: { chatVM.closeArtifactPanel() }
                )
            }
        case .sources:
            if let selection = chatVM.sourcesPanel {
                ChatSourcesPanelView(selection: selection) { chatVM.closeSourcesPanel() }
                    .id(selection.messageID)
            }
        case nil:
            EmptyView()
        }
    }

    private var modeBinding: Binding<ChatInspectorMode> {
        Binding(get: { chatVM.inspectorMode ?? chatVM.preferredInspectorMode },
                set: { chatVM.preferredInspectorMode = $0 })
    }
}
