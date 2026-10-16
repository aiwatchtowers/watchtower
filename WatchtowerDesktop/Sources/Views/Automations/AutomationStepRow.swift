import SwiftUI
import WatchtowerCore

/// One journal step of an expanded run: "✓ list_emails — 23 messages" with
/// its tokens and duration on the right. A proposal links to its Inbox card;
/// an ask or a session shows as plain text in P3 (P5 makes them links).
struct AutomationStepRow: View {
    let step: AutomationRunStep
    let onOpenInbox: ((Int64) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AutomationCardPresentation.stepLine(step))
                    .foregroundStyle(step.error.isEmpty ? Color.primary : Color.red)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(metrics)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if step.actionID != nil || step.askID != nil || step.sessionID != nil {
                links
            }
        }
        .font(.callout)
    }

    private var metrics: String {
        var parts: [String] = []
        let tokens = step.inputTokens + step.outputTokens
        if tokens > 0 {
            parts.append(AutomationCardPresentation.tokensText(tokens, estimated: step.tokensEstimated))
        }
        if let cost = AutomationCardPresentation.reportedCostText(step.reportedCostUSD) {
            parts.append(cost)
        }
        if step.durationMS > 0 {
            parts.append(AutomationCardPresentation.durationText(ms: step.durationMS))
        }
        return parts.joined(separator: " · ")
    }

    private var links: some View {
        HStack(spacing: 12) {
            if let actionID = step.actionID {
                if let onOpenInbox {
                    Button("Open in Inbox (proposal #\(actionID))") { onOpenInbox(actionID) }
                        .buttonStyle(.link)
                } else {
                    Text("Proposal #\(actionID)")
                }
            }
            if let askID = step.askID {
                Text("Ask #\(askID)")
            }
            if let sessionID = step.sessionID {
                Text("Session #\(sessionID)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 18)
    }
}
