import SwiftUI
import WatchtowerCore

/// The background AI consent (#1886, spec §5): onboarding's last step or the
/// sheet (after an upgrade, or opened from Settings, Home, an empty state or
/// Automations). Allow and Not now write the answer through the CLI;
/// `onAnswered` runs only once it is saved. A failed write keeps the screen
/// with the error line under the buttons.
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
    let onAnswered: () async -> Void

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
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
    }

    private var buttons: some View {
        VStack(alignment: .trailing, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                if case .step(let onBack) = host {
                    Button(Copy.back, action: onBack).buttonStyle(.kitQuiet).disabled(model.isSaving)
                }
                Spacer()
                if model.isSaving {
                    ProgressView().controlSize(.small)
                    Text(Copy.saving).font(.caption).foregroundStyle(.secondary)
                }
                Button(Copy.notNow) { answer(model.notNow) }
                    .buttonStyle(.kitSecondary)
                    .disabled(model.isSaving)
                Button(Copy.allow) { answer(model.allow) }
                    .buttonStyle(.kitPrimary)
                    .disabled(model.isSaving)
            }
            .controlSize(isStep ? .large : .regular)
            Text(model.errorLine ?? Copy.notNowNote)
                .font(.caption)
                .foregroundStyle(model.errorLine == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.error))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func answer(_ write: @escaping @MainActor () async -> Bool) {
        Task {
            if await write() { await onAnswered() }
        }
    }
}

/// The consent screen with its own model, made once when it appears (one
/// model per showing, so its saving and error state survive re-renders).
struct BackgroundAIConsentHost: View {
    let host: BackgroundAIConsentView.Host
    let onAnswered: () async -> Void

    @Environment(AppState.self) private var appState
    @State private var model: BackgroundAIConsentModel?

    var body: some View {
        Group {
            if let model {
                BackgroundAIConsentView(model: model, host: host, onAnswered: onAnswered)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onAppear {
            if model == nil { model = appState.makeBackgroundAIConsentModel() }
        }
    }
}
