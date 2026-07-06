import SwiftUI

/// Compact footer showing hydrator state + last-cycle stats. Rendered at the
/// bottom of each tab so the replica's freshness is always visible.
struct SyncStatusFooter: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 6) {
            if env.isHydrating {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.secondary)
                Text(statusText)
            }
            Spacer()
            Text("transport: \(env.transportLabel)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private var statusText: String {
        guard let last = env.lastHydrate else { return "Idle" }
        return "Synced · +\(last.applied) / −\(last.deleted)"
    }
}
