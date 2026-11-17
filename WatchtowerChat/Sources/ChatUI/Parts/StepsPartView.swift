import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The tool steps of a reply (the `steps` part): a folded "Worked · N steps" header, open while the turn runs (CHAT-02:
/// a waiting step stays visible until the turn ends).
struct StepsPartView: View {
    let payload: ChatStepsPayload
    let context: ChatPartContext
    // Tri-state by design: nil follows the turn (open while it runs), as the Mac's steps block.
    @State private var expanded: Bool? // swiftlint:disable:this discouraged_optional_boolean

    private var running: Bool { !context.isFinal }

    var body: some View {
        if !payload.steps.isEmpty {
            DisclosureGroup(isExpanded: Binding(get: { expanded ?? running }, set: { expanded = $0 })) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(Array((running ? payload.steps.reversed() : payload.steps).enumerated()), id: \.offset) { _, step in
                        StepLine(step: step, turnRunning: running)
                    }
                }
                .padding(.top, Spacing.small)
            } label: {
                Text(Self.header(count: payload.steps.count, running: running, steps: payload.steps))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("chat.steps")
        }
    }

    /// The engine's wire carries no step times, so the header counts steps only ("Worked · 3 steps"); steps that
    /// carry them (the Mac's embedded chats) say how long the turn worked ("Worked for 12s · 3 steps").
    static func header(count: Int, running: Bool, steps: [ChatStepsPayload.Step] = []) -> String {
        if !running, let start = steps.compactMap(\.startedAt).min() {
            let end = steps.compactMap(\.endedAt).max() ?? start
            return StepsSummary.header(stepCount: count, elapsed: end.timeIntervalSince(start), running: false)
        }
        let label = count == 1 ? "1 step" : "\(count) steps"
        return running ? "Working… · \(label)" : "Worked · \(label)"
    }
}

private struct StepLine: View {
    let step: ChatStepsPayload.Step
    let turnRunning: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            icon
            Text(step.summary.isEmpty ? step.name : step.summary)
                .font(.caption)
                .foregroundStyle(step.outcome == .failed ? Tone.error : Color.primary)
                .lineLimit(3)
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.outcome {
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(Tone.success).font(.caption)
        case .failed: Image(systemName: "xmark.octagon").foregroundStyle(Tone.error).font(.caption)
        case .running:
            if turnRunning {
                ProgressView().controlSize(.mini)
            } else {
                // The turn ended while this tool was in flight.
                Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}
