import SwiftUI
import WatchtowerCore

/// One journal step of an expanded run: "✓ list_emails — 23 messages" with
/// its tokens and duration on the right. A proposal links to its Inbox card,
/// a workbench run's session and ask to the workbench page (P5); with no
/// link to follow each shows as plain text.
struct AutomationStepRow: View {
    /// Where the step's ids lead; nil leaves that id as text.
    struct Links {
        var openInbox: ((Int64) -> Void)?
        var openSession: ((Int64) -> Void)?
        var openAsk: ((Int64) -> Void)?
    }

    let step: AutomationRunStep
    let links: Links

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
                linkRow
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

    private var linkRow: some View {
        HStack(spacing: 12) {
            if let actionID = step.actionID {
                link("Open in Inbox (proposal #\(actionID))", text: "Proposal #\(actionID)", id: actionID, links.openInbox)
            }
            if let askID = step.askID {
                link("Open ask #\(askID)", text: "Ask #\(askID)", id: askID, links.openAsk)
            }
            if let sessionID = step.sessionID {
                link("Open session #\(sessionID)", text: "Session #\(sessionID)", id: sessionID, links.openSession)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 18)
    }

    @ViewBuilder
    private func link(_ title: String, text: String, id: Int64, _ open: ((Int64) -> Void)?) -> some View {
        if let open {
            Button(title) { open(id) }
                .buttonStyle(.link)
        } else {
            Text(text)
        }
    }
}
