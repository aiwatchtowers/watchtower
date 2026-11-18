import SwiftUI
import WatchtowerCore
import DesignKit

/// Onboarding's Slack card when the build has no Slack app of its own
/// (`builtin_app` false, plan B A13): the connect section (MDM rows, the
/// link-or-code field, **Set up for my company**) in a sheet. Once a flow
/// runs, the sheet shows the flow's own steps (browser, connected, failed);
/// **Done** closes it. Strings: `SlackConnectFlowModel.onboarding*` and the
/// section's (`SlackModePresentation.ConnectSection`).
struct SlackOnboardingConnectSheet: View {
    let section: SlackModePresentation.ConnectSection
    @Bindable var flow: SlackConnectFlowModel
    /// The company setup runs in its own sheet; while it shows, its admin
    /// connect is a step of that sheet, not of this one.
    var setupPresented = false
    var blocked = false
    let setUpForCompany: () -> Void
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if let content = flow.sheet, !setupPresented {
            TimelineView(.everyMinute) { context in
                SlackConnectSheet(
                    content: content,
                    waitingLine: flow.waitingLine(at: context.date),
                    connectEnabled: !flow.externalBusy(),
                    perform: perform)
            }
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(SlackConnectFlowModel.onboardingTitle).font(.title3.weight(.semibold))
                Text(SlackConnectFlowModel.onboardingCaption)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SlackConnectFields(section: section, flow: flow, blocked: blocked, setUpForCompany: setUpForCompany,
                               fieldFocused: $fieldFocused)
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            Text(SlackConnectFlowModel.onboardingLiveHint)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(SlackConnectFlowModel.onboardingSkip, action: close)
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private func perform(_ action: SlackConnectSheetContent.Action) {
        switch action {
        case .cancel: flow.cancel()
        case .connect: flow.confirm()
        case .close: flow.dismiss()
        case .startAgain: flow.startAgain()
        case .done:
            flow.dismiss()
            close()
        }
    }
}
