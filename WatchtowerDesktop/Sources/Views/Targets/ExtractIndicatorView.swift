import SwiftUI

/// Global bottom-trailing capsule reflecting `TargetExtractCenter` state, so an
/// in-flight "Extract with AI" run — and its finished result — is visible and
/// actionable from every screen and survives navigation. Hidden when idle.
struct ExtractIndicatorView: View {
    @Environment(AppState.self) private var appState
    @State private var showPreview = false
    @State private var showDetails = false

    var body: some View {
        let center = appState.targetExtractCenter
        content(center)
            // Sit above the recording indicator when both are visible.
            .padding(16)
            .padding(.bottom, 72)
            .sheet(isPresented: $showPreview) {
                if let result = center.result {
                    ExtractPreviewSheet(
                        proposed: result.extracted,
                        omittedCount: result.omittedCount,
                        notes: result.notes
                    ) { _ in
                        center.dismiss()
                    }
                }
            }
    }

    @ViewBuilder
    private func content(_ center: TargetExtractCenter) -> some View {
        switch center.phase {
        case .idle:
            EmptyView()
        case .extracting:
            capsule {
                ProgressView().controlSize(.small)
                Text("Extracting targets…").font(.callout)
                Button("Cancel") { center.cancel() }
                    .controlSize(.small)
            }
        case let .ready(count):
            capsule {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text("^[\(count) target](inflect: true) ready").font(.callout.weight(.medium))
                Button("Review") { showPreview = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Dismiss") { center.dismiss() }
                    .controlSize(.small)
            }
        case .empty:
            capsule {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text("No targets found in this text").font(.callout)
                Button("Dismiss") { center.dismiss() }
                    .controlSize(.small)
            }
        case let .failed(message, canRetry):
            failedCapsule(center, message: message, canRetry: canRetry)
        }
    }

    private func failedCapsule(_ center: TargetExtractCenter, message: String, canRetry: Bool) -> some View {
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

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
    }
}
