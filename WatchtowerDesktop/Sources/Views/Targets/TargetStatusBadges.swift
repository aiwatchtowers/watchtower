import SwiftUI
import WatchtowerCore

/// The target pane's status picker: one badge per status the owner sets
/// (`targets.set_status` through `TargetsViewModel.updateStatus`), and the
/// press's state under it (mockup §8) — busy, Go's sentence with Retry, or
/// "Didn't confirm".
struct TargetStatusBadges: View {
    let target: Target
    let viewModel: TargetsViewModel

    /// The statuses the picker offers, in order.
    static let statuses = ["todo", "in_progress", "blocked", "done"]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.regular) {
                ForEach(Self.statuses, id: \.self) { status in
                    badge(status)
                }
                Spacer(minLength: 0)
            }
            let row = TargetsViewModel.row(target.id)
            if let state = viewModel.presses.state(row) {
                TowerRowState(state: state, busyLabel: viewModel.presses.label(row)) {
                    Task { await viewModel.presses.retry(row) }
                }
            }
        }
    }

    private func badge(_ status: String) -> some View {
        let isSelected = target.status == status
        let color = Self.color(status)
        return Button {
            Task { await viewModel.updateStatus(target, to: status) }
        } label: {
            Text(Self.displayName(status))
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? color : Color.secondary)
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.compact)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .fill(isSelected ? color.opacity(ChipTint.fillOpacity) : Fill.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .strokeBorder(isSelected ? color.opacity(ChipTint.strokeOpacity) : Color.clear,
                                      lineWidth: Stroke.hairline * 2)
                )
        }
        .buttonStyle(.plain)
    }

    static func displayName(_ status: String) -> String {
        switch status {
        case "todo": "To Do"
        case "in_progress": "In Progress"
        case "blocked": "Blocked"
        case "done": "Done"
        case "dismissed": "Dismissed"
        case "snoozed": "Snoozed"
        default: status.capitalized
        }
    }

    /// The badge's tone (`Tone.status` names; "To Do" is neutral).
    static func color(_ status: String) -> Color {
        switch status {
        case "in_progress": Tone.status("blue")
        case "blocked": Tone.status("red")
        case "done": Tone.status("green")
        case "dismissed": Tone.status("gray")
        case "snoozed": Tone.status("purple")
        default: Tone.status("")
        }
    }
}
