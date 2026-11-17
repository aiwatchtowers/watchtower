#if os(iOS)
import ChatWire
import SwiftUI
import UIKit
import WatchtowerDesign

/// The phone shows a connector call's input read-only (its relay answer carries no patch, so the card never edits);
/// this is the editor slot's iOS side, drawn only if a screen ever takes edits.
struct ConnectorInputEditor: View {
    @Binding var text: String
    let approval: ConnectorCallProposal.Approval?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("agentAction.connectorEditor")
            ConnectorInputNote(approval: approval)
        }
    }
}

/// The approval card's editor chrome on the phone.
enum ApprovalEditorChrome {
    static var background: Color { Color(uiColor: .secondarySystemBackground) }
    static var stroke: Color { Color.secondary.opacity(strokeOpacity) }
    private static let strokeOpacity = 0.3
}

extension View {
    func slackWorkspacePickerStyle() -> some View { pickerStyle(.inline) }
    func approvalLinkStyle() -> some View { buttonStyle(.borderless) }
}
#endif
