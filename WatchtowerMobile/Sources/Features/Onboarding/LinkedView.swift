import SwiftUI

/// Step 6: "Linked to <Mac name>". Continue asks for notification
/// permission, then opens Now.
struct LinkedView: View {
    @Environment(LinkingViewModel.self) private var linking
    let macName: String

    var body: some View {
        LinkOutcomeLayout(systemImage: "checkmark.circle.fill", tone: .green, title: "Linked to \(macName)") {
            Button {
                Task { await linking.finish() }
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Step 6's prompt: the phone is linked to another Mac.
struct SwitchMacView: View {
    @Environment(LinkingViewModel.self) private var linking
    let old: String
    let new: String

    var body: some View {
        LinkOutcomeLayout(
            systemImage: "arrow.left.arrow.right",
            title: LinkingViewModel.switchPrompt(from: old, to: new),
            detail: "This phone unlinks from \(old) first. Changes still waiting for it are not sent."
        ) {
            Button {
                Task { await linking.confirmSwitch(true) }
            } label: {
                Text("Switch")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            Button {
                Task { await linking.confirmSwitch(false) }
            } label: {
                Text("Keep \(old)")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }
}

/// Why the scan did not link, with a new scan when one can help.
struct LinkFailureView: View {
    @Environment(LinkingViewModel.self) private var linking
    let failure: LinkFailure

    var body: some View {
        LinkOutcomeLayout(systemImage: "exclamationmark.triangle", title: failure.title, detail: failure.hint) {
            if failure.offersScan {
                Button {
                    linking.startScan()
                } label: {
                    Text("Scan again")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                linking.dismiss()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }
}

/// An icon in its tone, a title, an optional detail line under it, and the
/// actions at the bottom.
private struct LinkOutcomeLayout<Actions: View>: View {
    let systemImage: String
    var tone: PhoneTone = .secondary
    let title: String
    var detail: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: Spacing.page) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(tone.color)
            VStack(spacing: Spacing.regular) {
                Text(title)
                    .font(TypeScale.screenTitle)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(spacing: Spacing.medium) {
                actions
            }
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.large)
    }
}
