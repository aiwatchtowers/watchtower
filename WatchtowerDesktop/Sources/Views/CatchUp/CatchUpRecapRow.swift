import SwiftUI
import WatchtowerCore

// MARK: - CatchUpRecapRow
//
// One row of the left-hand recap list: the window the recap covers, plus the
// one thing worth knowing about it at a glance — still building, failed, or
// already acknowledged.
struct CatchUpRecapRow: View {
    let recap: CatchUpRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(CatchUpRecap.windowLabel(
                from: Date(timeIntervalSince1970: recap.periodFrom),
                to: Date(timeIntervalSince1970: recap.periodTo)
            ))
            .font(.subheadline)
            .fontWeight(recap.isAcknowledged ? .regular : .medium)
            .foregroundStyle(recap.isAcknowledged ? .secondary : .primary)
            .lineLimit(2)

            HStack(spacing: 6) {
                statusBadge
                if recap.regenOfID != nil {
                    Text("regenerated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusBadge: some View {
        if recap.isBuilding {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("building…")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if recap.isFailed {
            Label("failed", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.red)
        } else if recap.isAcknowledged {
            Label("caught up", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }
}
