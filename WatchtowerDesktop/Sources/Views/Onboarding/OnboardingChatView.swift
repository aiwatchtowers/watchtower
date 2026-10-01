import SwiftUI
import WatchtowerCore

/// Chat view for the onboarding flow — AI learns about the user, on the
/// shared embedded chat component. Role questions appear as chat bubbles
/// with quick-reply buttons (the composer is hidden meanwhile), then the
/// free-form interview; Continue appears once the assistant is ready, and
/// "Skip interview" is always reachable.
struct OnboardingChatView: View {
    @Bindable var viewModel: OnboardingChatViewModel
    let onComplete: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            EmbeddedChatView(
                engine: viewModel.engine,
                placeholder: viewModel.loc("placeholder"),
                showsComposer: viewModel.quickReplies.isEmpty,
                accessory: { _ in EmptyView() },
                footer: { footer }
            )
            skipButton
        }
        .task {
            viewModel.startQuestionnaire()
        }
    }

    private var chatHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text(viewModel.loc("header"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(viewModel.loc("subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
        .padding(.horizontal, 40)
    }

    /// Above the composer: the questionnaire's quick replies, or Continue
    /// once the interview has what it needs.
    @ViewBuilder
    private var footer: some View {
        if !viewModel.quickReplies.isEmpty {
            HStack(spacing: 8) {
                ForEach(viewModel.quickReplies) { reply in
                    Button(reply.label) {
                        reply.action()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } else if viewModel.chatReady {
            continueButton
        }
    }

    // Escape hatch: always reachable, including during the quick-reply
    // questionnaire and while streaming — the interview must never be a
    // dead end when the AI provider is missing or broken.
    private var skipButton: some View {
        Button("Skip interview") {
            viewModel.skipChat()
            onSkip()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var continueButton: some View {
        Button {
            Task {
                await viewModel.finishChat()
                onComplete()
            }
        } label: {
            if viewModel.isExtractingProfile {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing...")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            } else {
                Label(viewModel.loc("continue"), systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.isExtractingProfile)
        .padding(.horizontal, 40)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}
