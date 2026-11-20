import SwiftUI
import WatchtowerInterface

/// The row treatment of a press that goes through the tower (mobile Inbox
/// mockup §8), shared by every screen that writes through it: busy with
/// the press's label, the tower's sentence with **Retry** when it did not
/// land, "Didn't confirm — checking again…" when its outcome is unknown,
/// nothing otherwise. It takes the place of the row's second line.
public struct TowerRowState: View {
    let state: TowerActionState?
    let busyLabel: String
    let retry: () -> Void

    public init(state: TowerActionState?, busyLabel: String, retry: @escaping () -> Void) {
        self.state = state
        self.busyLabel = busyLabel
        self.retry = retry
    }

    public var body: some View {
        switch state {
        case nil:
            EmptyView()
        case .busy:
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text(busyLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("towerRow.busy")
        case .refused(let sentence):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(sentence)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button(TowerText.retry, action: retry)
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
            .font(.caption)
            .accessibilityIdentifier("towerRow.refused")
        case .unknown:
            Text(TowerText.didntConfirmMac)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("towerRow.unknown")
        }
    }
}
