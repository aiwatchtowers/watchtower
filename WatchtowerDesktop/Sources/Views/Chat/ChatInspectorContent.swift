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
                    expand: expandButton,
                    onSendComments: { chatVM.sendArtifactComments() },
                    onClose: { chatVM.closeArtifactPanel() }
                )
            }
        case .sources:
            if let selection = chatVM.sourcesPanel {
                ChatSourcesPanelView(selection: selection, expand: expandButton) { chatVM.closeSourcesPanel() }
                    .id(selection.messageID)
            }
        case nil:
            EmptyView()
        }
    }

    private var expandButton: ChatInspectorExpandButton {
        ChatInspectorExpandButton(isExpanded: chatVM.isInspectorExpanded) { chatVM.toggleInspectorExpanded() }
    }

    private var modeBinding: Binding<ChatInspectorMode> {
        Binding(get: { chatVM.inspectorMode ?? chatVM.preferredInspectorMode },
                set: { chatVM.preferredInspectorMode = $0 })
    }
}

/// The panel header's expand button (#786): the open panel takes the chat's
/// whole width in place of the conversation, or goes back to the column.
struct ChatInspectorExpandButton: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.borderless)
        .help(isExpanded ? "Show the conversation" : "Expand to the full width")
        .accessibilityLabel(isExpanded ? "Collapse panel" : "Expand panel")
    }
}
