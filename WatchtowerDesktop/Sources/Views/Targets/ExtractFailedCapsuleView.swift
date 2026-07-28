import SwiftUI

/// `ExtractIndicatorView`'s `.failed` phase rendering — the Retry/Show-details
/// capsule — split into its own file so the parent view's fan-out doesn't
/// accumulate with this case's calls too.
extension ExtractIndicatorView {
    func failedCapsule(_ center: TargetExtractCenter, message: String, canRetry: Bool) -> some View {
        capsule {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.callout.weight(.medium))
                if showDetails, let raw = center.lastRawError {
                    Text(raw).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
                } else if center.lastRawError != nil {
                    Button("Show details") { showDetails = true }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            if canRetry {
                Button("Retry") { showDetails = false; center.retry() }
                    .controlSize(.small)
            }
            Button("Dismiss") { center.dismiss() }
                .controlSize(.small)
        }
        .frame(maxWidth: 420)
    }
}
