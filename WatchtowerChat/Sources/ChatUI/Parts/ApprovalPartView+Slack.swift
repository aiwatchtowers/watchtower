import SwiftUI
import WatchtowerDesign

/// `send_slack_message`: who it goes to and the text, as pinned at propose time (the Mac's own card also edits it).
struct SlackApproval: Equatable {
    static let tool = "send_slack_message"
    static let chooseWorkspace = "Choose a workspace on the Mac before approving"

    let recipient: String
    let text: String

    init?(_ payload: ChatApprovalPayload) {
        guard payload.tool == Self.tool else { return nil }
        let args = payload.args
        text = args["text"] as? String ?? ""
        if let target = args["target"] as? [String: Any] {
            let label = target["label"] as? String ?? "?"
            let workspace = target["workspace"] as? String ?? ""
            recipient = workspace.isEmpty ? "To: \(label)" : "To: \(label) · \(workspace)"
        } else if let channel = args["channel"] as? String, !channel.isEmpty {
            recipient = "To: \(channel)"
        } else {
            recipient = Self.chooseWorkspace
        }
    }
}

struct SlackApprovalBody: View {
    let slack: SlackApproval

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(slack.recipient).font(.callout)
            Text(slack.text)
                .font(.callout)
                .padding(Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
                .textSelection(.enabled)
        }
    }
}
