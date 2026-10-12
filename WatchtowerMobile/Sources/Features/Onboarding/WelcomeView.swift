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
            LinkStepsScreen(macName: nil)
        case let .waiting(macName):
            LinkStepsScreen(macName: macName)
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

/// O2's steps, re-read every second so the 20 s hint appears on time.
private struct LinkStepsScreen: View {
    @Environment(LinkingViewModel.self) private var linking
    let macName: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            LinkStepsView(model: LinkStepsModel(waitingFor: macName, waited: linking.phaseElapsed()))
        }
    }
}

/// One line of Welcome's "what the phone does" (design pass O1).
struct WelcomeFeature: Equatable {
    let symbol: String
    let text: String

    static let all: [Self] = [
        Self(symbol: "questionmark.bubble", text: "Answer your agents' asks"),
        Self(symbol: "terminal", text: "Follow and start sessions"),
        Self(symbol: "calendar", text: "Record and recap meetings")
    ]
}

/// First run, and after an unlink: what Watchtower is, the scan, and the
/// checklist for a Mac that shows no code.
struct WelcomeView: View {
    @Environment(LinkingViewModel.self) private var linking

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scrolls at accessibility text sizes; the buttons stay pinned.
                ScrollView {
                    content
                        .padding(.horizontal, Spacing.page)
                        .padding(.top, Spacing.large)
                }
                .scrollBounceBehavior(.basedOnSize)
                buttons
                    .padding(.horizontal, Spacing.page)
                    .padding(.vertical, Spacing.large)
            }
        }
    }

    private var content: some View {
        VStack(spacing: Spacing.page) {
            Image("AppIconImage")
                .resizable()
                .frame(width: 72, height: 72)
                // The app icon's own corner (O1), not a card radius.
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: Spacing.regular) {
                Text("Watchtower")
                    .font(.largeTitle.bold())
                Text("Your Mac's Watchtower on this iPhone: asks, sessions, the board and your meetings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(WelcomeFeature.all, id: \.text) { feature in
                    FlatRow(icon: .symbol(feature.symbol, tone: .accent), title: feature.text, insets: EdgeInsets()) {
                        EmptyView()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let notice = linking.notice {
                Text(notice.message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .card(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var buttons: some View {
        VStack(spacing: Spacing.medium) {
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
}

/// Unlinking: a spinner and its line.
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
