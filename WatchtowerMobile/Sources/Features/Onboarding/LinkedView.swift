import SwiftUI

/// Step 6: "Linked to <Mac name>". Continue asks for notification
/// permission, then opens Now.
struct LinkedView: View {
    @Environment(LinkingViewModel.self) private var linking
    let macName: String

    var body: some View {
        LinkOutcomeLayout(systemImage: "checkmark.circle", title: "Linked to \(macName)") {
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
        LinkOutcomeLayout(systemImage: "exclamationmark.triangle", title: failure.message) {
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

/// An icon, a title, an optional detail line, and the actions at the
/// bottom.
private struct LinkOutcomeLayout<Actions: View>: View {
    let systemImage: String
    let title: String
    var detail: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 12) {
                actions
            }
        }
        .padding()
    }
}
