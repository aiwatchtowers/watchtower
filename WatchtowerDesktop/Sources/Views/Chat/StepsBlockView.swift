import SwiftUI
import WatchtowerCore

/// "Worked for 12s · 4 steps" (spec §3.2.1): expanded with the live step on
/// top while running, collapsed when done. Every tool call is visible
/// (CHAT-02); a failed step is red with its reason under the label, and a
/// call waiting for the owner's approval says so until it ends.
struct StepsBlockView: View {
    let steps: [ChatStepDisplay]
    let isRunning: Bool
    // Tri-state by design: nil = "follow isRunning", not a default — so an
    // optional Bool is the honest type here (ProposedAction.done precedent).
    @State private var expanded: Bool? // swiftlint:disable:this discouraged_optional_boolean

    var body: some View {
        if !steps.isEmpty {
            DisclosureGroup(isExpanded: expandedBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ordered) { step in
                        StepRow(step: step, turnRunning: isRunning)
                    }
                }
                .padding(.top, 4)
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(StepsSummary.header(
                        stepCount: steps.count,
                        elapsed: StepsSummary.elapsed(steps: steps, running: isRunning, now: context.date),
                        running: isRunning))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ordered: [ChatStepDisplay] { isRunning ? steps.reversed() : steps }

    /// Follows the running state until the owner toggles it by hand.
    private var expandedBinding: Binding<Bool> {
        Binding(get: { expanded ?? isRunning }, set: { expanded = $0 })
    }
}

private struct StepRow: View {
    let step: ChatStepDisplay
    let turnRunning: Bool
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.argsJSON).font(.caption.monospaced()).textSelection(.enabled)
                // A failed step keeps its full reason here; the label's note is a preview.
                if !step.summary.isEmpty && step.state.waitingActionID == nil {
                    Text(step.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    statusIcon
                    Image(systemName: ChatToolCatalog.icon(name: step.name)).font(.caption)
                    Text(ChatToolCatalog.label(name: step.name, args: step.argsJSON))
                        .font(.caption)
                        .foregroundStyle(step.state == .failed ? Color.red : Color.primary)
                        .lineLimit(1)
                }
                if let note {
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(note.color)
                        .lineLimit(3)
                }
            }
        }
    }

    /// Shown without expanding the row: a failed (denied, timed-out) step's
    /// reason, and a waiting call's message pointing at its approval card.
    private var note: (text: String, color: Color)? {
        switch step.state {
        case .failed where !step.summary.isEmpty:
            (step.summary, Color.red)
        case .waiting where turnRunning:
            (step.summary + " — see the approval card below.", Color.orange)
        default:
            nil
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch step.state {
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(.green).font(.caption)
        case .failed: Image(systemName: "xmark.octagon").foregroundStyle(.red).font(.caption)
        case .waiting where turnRunning:
            Image(systemName: "hourglass").foregroundStyle(.orange).font(.caption)
        case .running, .waiting:
            if turnRunning {
                ProgressView().controlSize(.mini)
            } else {
                // The turn ended while this tool was in flight.
                Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}
