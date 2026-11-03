import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// The A/B replay card of the tuning chat mockups (spec §3.6, §4.4, §4.6):
/// proposed, running, done and failed. Inputs show a time and a short
/// label, never their content; only the two outputs are text.
struct TuningReplayCard: View {
    enum Phase { case proposed, running, done, failed }

    let phase: Phase
    /// The narrow panel: Without above With.
    var stacked = false

    struct Input: Identifiable {
        let id: Int
        let label: String
        let without: String
        /// The With output in runs; `true` marks text the addition changed.
        let with: [(String, Bool)]

        var changed: Bool { with.contains { $0.1 } }
    }

    static let addition = "When a thread ends in a decision, name who made it."

    static let inputs = [
        Input(id: 1, label: "Fri 16:40 · 38 messages",
              without: "The team agreed to move the acme release to Tuesday. QA signs off on Monday.",
              with: [("The team agreed to move the acme release to Tuesday ", false),
                     ("(decided by colleague A)", true), (". QA signs off on Monday.", false)]),
        Input(id: 2, label: "Fri 09:05 · 12 messages",
              without: "Billing export now runs nightly; two columns were added.",
              with: [("Billing export now runs nightly; two columns were added. ", false),
                     ("Decided by colleague B.", true)]),
        Input(id: 3, label: "Thu 17:22 · 54 messages", without: "", with: [("", false)]),
        Input(id: 4, label: "Thu 11:10 · 21 messages", without: "", with: [("", true)]),
        Input(id: 5, label: "Wed 15:48 · 9 messages", without: "", with: [("", false)])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.compact) {
                Chip(text: "A/B", color: Color.accentColor)
                Chip(text: "Watchtower prompt · digest.channel", color: .secondary)
            }
            title.font(.headline)
            Text(costLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            additionBlock
            phaseBody
            buttons
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var title: Text {
        let verb = phase == .done ? "Tried on 5 past calls of " : "Try on 5 past calls of "
        return Text(verb) + Text("digest.channel").italic()
    }

    private var costLine: String {
        switch phase {
        case .proposed: "≈ $0.14 · 10 model calls"
        case .running: "Running 3 of 10 · ≈ $0.14"
        case .done: "10 calls · $0.12 · 3 of 5 outputs changed"
        case .failed: "4 of 10 calls · $0.05"
        }
    }

    private var additionBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Candidate addition").font(.caption).foregroundStyle(.secondary)
            Text("+ " + Self.addition).font(.callout.monospaced()).foregroundStyle(Tone.success)
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    @ViewBuilder private var phaseBody: some View {
        switch phase {
        case .proposed:
            EmptyView()
        case .running:
            ProgressView(value: 3, total: 10).controlSize(.small)
            rows { index in index < 1 ? ("done", Tone.success) : index == 1 ? ("running", Color.accentColor) : ("waiting", .secondary) }
        case .done:
            ForEach(Self.inputs.prefix(2)) { input in outputRow(input) }
            rows(from: 2) { index in Self.inputs[index].changed ? ("changed", Color.accentColor) : ("same", .secondary) }
        case .failed:
            Label("Stopped after 4 of 10 calls: the model timed out", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tone.warning)
            rows { index in index < 2 ? ("done", Tone.success) : ("not run", .secondary) }
        }
    }

    /// Folded input rows: a time, a label and a state chip.
    private func rows(from start: Int = 0, chip: @escaping (Int) -> (String, Color)) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(start..<Self.inputs.count, id: \.self) { index in
                let state = chip(index)
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(Self.inputs[index].label).font(.caption)
                    Spacer(minLength: Spacing.regular)
                    Chip(text: state.0, color: state.1)
                }
                .padding(.vertical, Spacing.tight)
            }
        }
    }

    /// One unfolded input: Without and With side by side (stacked when narrow).
    private func outputRow(_ input: Input) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                Text(input.label).font(.caption)
                Spacer(minLength: Spacing.regular)
                Chip(text: "changed", color: Color.accentColor)
            }
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.compact))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.compact))
            layout {
                output("Without", Text(input.without))
                output("With", highlighted(input.with))
            }
        }
    }

    private func output(_ title: String, _ text: Text) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            text.font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, maxHeight: stacked ? nil : .infinity, alignment: .topLeading)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    /// The With text with the changed runs on a success tint.
    private func highlighted(_ runs: [(String, Bool)]) -> Text {
        var string = AttributedString()
        for (text, changed) in runs {
            var run = AttributedString(text)
            if changed { run.backgroundColor = Tone.success.opacity(ChipTint.fillOpacity) }
            string += run
        }
        return Text(string)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: Spacing.regular) {
            Spacer(minLength: 0)
            switch phase {
            case .proposed:
                Button("Not now") {}.buttonStyle(.kitSecondary)
                Button("Run") {}.buttonStyle(.kitPrimary)
            case .running:
                EmptyView()
            case .done:
                Button("Discard") {}.buttonStyle(.kitSecondary)
                Button("Propose this addition") {}.buttonStyle(.kitPrimary)
            case .failed:
                Button("Discard") {}.buttonStyle(.kitSecondary)
                Button("Retry") {}.buttonStyle(.kitPrimary)
            }
        }
    }
}
