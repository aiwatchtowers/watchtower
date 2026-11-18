import SwiftUI
import WatchtowerCore

/// The background AI consent (#1886, spec §5): onboarding's last step or the
/// sheet (after an upgrade, or opened from Settings, Home, an empty state or
/// Automations). Allow and Not now write the answer through the CLI;
/// `onAnswered` runs only once it is saved, with the buttons still off. A
/// failed write keeps the screen with the error line under the buttons.
struct BackgroundAIConsentView: View {
    enum Host {
        /// Onboarding's step: Back, and the step indicator above it (drawn by
        /// `OnboardingV2View`).
        case step(onBack: () -> Void)
        /// The sheet: no Back, no close button, Esc does nothing.
        case sheet
    }

    let model: BackgroundAIConsentModel
    let host: Host
    /// The host's follow-up once the answer is saved; false keeps the
    /// screen with a retry of the follow-up only.
    let onAnswered: @MainActor () async -> Bool

    private typealias Copy = BackgroundAIConsentCopy
    private static let sheetWidth: CGFloat = 560

    private static let rowIcons = [
        "arrow.triangle.2.circlepath", "clock", "sun.max", "clock.arrow.circlepath", "bolt"
    ]

    var body: some View {
        switch host {
        case .step:
            content
        case .sheet:
            content
                .padding(Spacing.wide)
                .frame(width: Self.sheetWidth)
                .interactiveDismissDisabled()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            explanation
            buttons.padding(.top, isStep ? Spacing.regular : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isStep: Bool {
        if case .step = host { return true }
        return false
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(Copy.title).font(.title2.weight(.semibold))
            Text(Copy.intro(model.agent)).fixedSize(horizontal: false, vertical: true)
            ForEach(model.planLines, id: \.self) { line in
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
            whatRuns
            Text(Copy.userStarted).font(.caption).foregroundStyle(.secondary)
            Text(Copy.changeLater).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var whatRuns: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(Copy.whatRunsTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(zip(Self.rowIcons, model.whatRuns)), id: \.1) { icon, row in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: IconSize.composer)
                    Text(row).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var buttons: some View {
        VStack(alignment: .trailing, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                if case .step(let onBack) = host {
                    Button(Copy.back, action: onBack)
                        .buttonStyle(.kitQuiet)
                        .disabled(model.isBusy || model.needsFinishRetry)
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(Copy.saving).font(.caption).foregroundStyle(.secondary)
                }
                if model.needsFinishRetry {
                    // The answer is saved; only the follow-up runs again.
                    Button(Copy.finishRetry) { Task { await model.retryFinish(onAnswered) } }
                        .buttonStyle(.kitPrimary)
                        .disabled(model.isBusy)
                } else {
                    Button(Copy.notNow) { Task { await model.answer(.notNow, finish: onAnswered) } }
                        .buttonStyle(.kitSecondary)
                        .disabled(model.isBusy)
                    Button(Copy.allow) { Task { await model.answer(.allow, finish: onAnswered) } }
                        .buttonStyle(.kitPrimary)
                        .disabled(model.isBusy)
                }
            }
            .controlSize(isStep ? .large : .regular)
            Text(model.errorLine ?? Copy.notNowNote)
                .font(.caption)
                .foregroundStyle(model.errorLine == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.error))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Onboarding's consent step with its own model, made once when it appears
/// (so its saving and error state survive re-renders). While config.yaml
/// cannot be read there is no model: the config error shows with Back.
struct BackgroundAIConsentStep: View {
    let onBack: () -> Void
    /// Onboarding's finish once the answer is saved; false keeps the step
    /// with a retry of the finish only.
    let onAnswered: @MainActor () async -> Bool

    @Environment(AppState.self) private var appState
    @State private var load = BackgroundAIConsentStepLoad.pending

    var body: some View {
        Group {
            switch load {
            case .pending:
                Color.clear.frame(width: 1, height: 1)
            case .ready(let model):
                BackgroundAIConsentView(model: model, host: .step(onBack: onBack), onAnswered: onAnswered)
            case .unreadable:
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    Text(BackgroundAIConsentCopy.configUnreadableTitle).font(.title2.weight(.semibold))
                    Text(BackgroundAIConsentCopy.configUnreadable).foregroundStyle(Tone.error)
                    HStack(spacing: Spacing.regular) {
                        Button(BackgroundAIConsentCopy.back, action: onBack).buttonStyle(.kitQuiet)
                        Spacer()
                        // Re-reads config.yaml once the owner fixed it.
                        Button(BackgroundAIConsentCopy.finishRetry) {
                            load.load { appState.makeBackgroundAIConsentModel() }
                        }
                        .buttonStyle(.kitPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            guard case .pending = load else { return }
            load.load { appState.makeBackgroundAIConsentModel() }
        }
    }
}
