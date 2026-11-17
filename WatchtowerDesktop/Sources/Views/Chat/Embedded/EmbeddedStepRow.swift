import ChatUI
import ChatWire
import SwiftUI
import WatchtowerCore

/// One tool step of an embedded chat, as the app's steps block drew it before the chat came onto ChatUI (unified
/// chat T12): the status icon (an hourglass while it waits for the owner's approval, a stop sign when the turn ended
/// under it), the tool's icon and the label `ChatToolCatalog` builds from its arguments, the failed step's reason or
/// the waiting note inline, and the arguments behind a disclosure. ChatUI draws it through
/// `DesignKitChatStyle.stepLine`.
struct EmbeddedStepRow: View {
    let step: ChatStepDisplay
    let turnRunning: Bool
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(step.argsJSON).font(.caption.monospaced()).textSelection(.enabled)
                // A failed step keeps its full reason here; the label's note is a preview.
                if !step.summary.isEmpty && step.state.waitingActionID == nil {
                    Text(step.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    statusIcon
                    Image(systemName: ChatToolCatalog.icon(name: step.name)).font(.caption)
                    Text(ChatToolCatalog.label(name: step.name, args: step.argsJSON))
                        .font(.caption)
                        .foregroundStyle(step.state == .failed ? Tone.error : Color.primary)
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
            (step.summary, Tone.error)
        case .waiting where turnRunning:
            (step.summary + " — see the approval card below.", Tone.warning)
        default:
            nil
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch step.state {
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(Tone.success).font(.caption)
        case .failed: Image(systemName: "xmark.octagon").foregroundStyle(Tone.error).font(.caption)
        case .waiting where turnRunning:
            Image(systemName: "hourglass").foregroundStyle(Tone.warning).font(.caption)
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

extension EmbeddedStepRow {
    /// A step as ChatUI hands it over (`ChatStepLine`), in the app's own step model.
    init(_ line: ChatStepLine, turnRunning: Bool) {
        let state: StepState = switch line.outcome {
        case .succeeded: .succeeded
        case .failed: .failed
        case .running: line.isWaiting ? .waiting(actionID: 0) : .running
        }
        self.init(step: ChatStepDisplay(id: line.name, name: line.name, argsJSON: line.argsJSON ?? "{}", state: state,
                                        summary: line.summary, sources: [], startedAt: .distantPast, endedAt: nil),
                  turnRunning: turnRunning)
    }
}
