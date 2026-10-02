import SwiftUI
import WatchtowerCore

/// About you, once, after the first Slack account was connected outside
/// onboarding (`AppState.offerLateAboutYou`), over the Settings window: the
/// onboarding step in a sheet. Done writes the profile only; Later closes.
struct LateAboutYouSheet: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingAboutYouStepView(
                onBack: nil,
                onFinish: { about in await appState.finishLateAboutYou(about) },
                isBusy: appState.isSavingLateAboutYou
            )
            if let error = appState.lateAboutYouError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 760, height: 460)
        .interactiveDismissDisabled(appState.isSavingLateAboutYou)
        .onAppear { appState.markAboutYouShown() }
    }
}
