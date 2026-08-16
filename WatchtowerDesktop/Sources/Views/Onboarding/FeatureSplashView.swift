import SwiftUI
import WatchtowerCore

/// Placeholder for the selling feature splash — replaced by the real view in
/// the next commit (Task 4). Keeps `.features` a working, self-completing
/// step in the meantime so the onboarding flow rewired in this commit still
/// runs end to end.
struct FeatureSplashView: View {
    let onFinish: () async -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Setting up your personalized experience...")
                .foregroundStyle(.secondary)
        }
        .task { await onFinish() }
    }
}
