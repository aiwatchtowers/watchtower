import SwiftUI
import WatchtowerCore

/// About you, once, after a Slack account was connected outside onboarding
/// (`AppState.offerLateAboutYou`): the onboarding step in a sheet, its exits
/// writing the profile only.
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
    }
}
