import SwiftUI
import WatchtowerDesign

/// `claude_ai_connector_call`: the claude.ai connector, its tool and the exact input it sends.
struct ConnectorApproval: Equatable {
    static let tool = "claude_ai_connector_call"

    let server: String
    let toolName: String
    let input: String

    init?(_ payload: ChatApprovalPayload) {
        guard payload.tool == Self.tool else { return nil }
        let args = payload.args
        guard let server = args["server"] as? String, !server.isEmpty,
              let toolName = args["tool"] as? String, !toolName.isEmpty else { return nil }
        self.server = server
        self.toolName = toolName
        if let raw = args["input"], JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            input = String(bytes: data, encoding: .utf8) ?? ""
        } else {
            input = ""
        }
    }
}

struct ConnectorApprovalBody: View {
    let call: ConnectorApproval

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("\(call.server) · \(call.toolName)").font(.callout)
            if !call.input.isEmpty {
                Text(call.input)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .textSelection(.enabled)
            }
        }
    }
}
