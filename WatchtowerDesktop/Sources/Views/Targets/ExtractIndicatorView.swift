import SwiftUI

/// Global bottom-trailing capsule reflecting `TargetExtractCenter` state, so an
/// in-flight "Extract with AI" run — and its finished result — is visible and
/// actionable from every screen and survives navigation. Hidden when idle.
///
/// The `.failed` phase (Retry/Show-details capsule) renders via
/// `ExtractFailedCapsuleView.swift` — split out to keep this file's own
/// structural fan-out under the god-file gate.
struct ExtractIndicatorView: View {
    @Environment(AppState.self) private var appState
    @State private var showPreview = false
    @State var showDetails = false

    var body: some View {
        let center = appState.targetExtractCenter
        renderPhase(center)
            // The root lifts it above the recording indicator when both
            // share the bottom-trailing corner.
            .padding(16)
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
    private func renderPhase(_ center: TargetExtractCenter) -> some View {
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

    func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
    }
}
