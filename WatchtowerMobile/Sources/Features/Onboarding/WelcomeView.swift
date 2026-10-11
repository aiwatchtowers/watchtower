import SwiftUI

/// The link flow's screens by phase (spec §2.3): Welcome, the camera, the
/// checks and the grant wait, the switch prompt, a failure, Linked.
struct OnboardingView: View {
    @Environment(LinkingViewModel.self) private var linking

    var body: some View {
        switch linking.phase {
        case .idle:
            WelcomeView()
        case .scanning:
            ScanView(
                onCode: { code in Task { await linking.scanned(code) } },
                onCancel: { linking.dismiss() }
            )
        case .checking:
            LinkProgressView(text: "Checking the code…")
        case let .waiting(macName):
            LinkProgressView(text: "Waiting for \(macName) to confirm…")
        case .unlinking:
            LinkProgressView(text: "Unlinking…")
        case let .confirmSwitch(old, new):
            SwitchMacView(old: old, new: new)
        case let .failed(failure):
            LinkFailureView(failure: failure)
        case let .linked(macName):
            LinkedView(macName: macName)
        }
    }
}

/// First run, and after an unlink: what Watchtower is, the scan, and the
/// checklist for a Mac that shows no code.
struct WelcomeView: View {
    @Environment(LinkingViewModel.self) private var linking

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "desktopcomputer.and.iphone")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("Watchtower")
                        .font(.largeTitle.bold())
                    Text("Your Mac's Watchtower on this iPhone: asks, sessions, the board and your meetings.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                if let notice = linking.notice {
                    Text(notice.message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                VStack(spacing: 12) {
                    Text("On your Mac: Settings → Mobile → Use Watchtower on iPhone.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button {
                        linking.startScan()
                    } label: {
                        Label("Scan the code on your Mac", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    NavigationLink {
                        MacNotShowingView()
                    } label: {
                        Text("The Mac doesn't show up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .padding()
        }
    }
}

/// Steps 1–5 running.
struct LinkProgressView: View {
    let text: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
