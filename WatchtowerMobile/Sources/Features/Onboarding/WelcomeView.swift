import SwiftUI

/// The link flow's screens by phase (spec §2.3): Welcome, the camera, the
/// checks and the grant wait, a failure, Linked.
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
            LinkStepsView(model: LinkStepsModel(
                waitingFor: macName, code: linking.linkCode, macSeesPhone: linking.macSeesPhone,
                waited: linking.phaseElapsed()
            ))
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
    @Environment(\.startDemoTour) private var startDemoTour

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
                .frame(width: PhoneMetrics.appIcon, height: PhoneMetrics.appIcon)
                // The app icon's own corner (O1), not a card radius.
                .clipShape(RoundedRectangle(cornerRadius: PhoneMetrics.appIcon * Self.iconCorner, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: Spacing.regular) {
                Text("Watchtower")
                    .font(.largeTitle.bold())
                Text("Your Mac's Watchtower on this iPhone: asks, sessions, the board and your meetings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(WelcomeFeature.all.enumerated()), id: \.element.text) { index, feature in
                    if index > 0 { CardRowDivider() }
                    FlatRow(icon: .symbol(feature.symbol, tone: .accent), title: feature.text, insets: EdgeInsets()) {
                        EmptyView()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .card(.plain)
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

    /// The icon's corner as a share of its side (the system's squircle).
    private static let iconCorner = 0.22

    /// The scan is the one prominent action; the help and the demo are
    /// quiet links (mockup 17).
    private var buttons: some View {
        VStack(spacing: Spacing.regular) {
            Text("On your Mac: Settings → Mobile → Use Watchtower on iPhone.")
                .font(TypeScale.meta)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.bottom, Spacing.regular)
            Button {
                linking.startScan()
            } label: {
                Label("Scan the code on your Mac", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(ProminentActionStyle())
            NavigationLink {
                MacNotShowingView()
            } label: {
                QuietLinkLabel(text: "The Mac doesn't show up")
            }
            // No Mac at hand (App Review has none): the demo Macs (#174).
            if let startDemoTour {
                Button {
                    startDemoTour()
                } label: {
                    QuietLinkLabel(text: "Try the Demo")
                }
            }
        }
    }
}

/// A quiet link: accent text, no plate, a 44 pt hit area.
private struct QuietLinkLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TypeScale.rowTitle)
            .foregroundStyle(PhoneTone.accent.color)
            .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch)
            .contentShape(Rectangle())
    }
}

/// Unlinking: a spinner and its line.
struct LinkProgressView: View {
    let text: String

    var body: some View {
        VStack(spacing: Spacing.large) {
            ProgressView()
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
