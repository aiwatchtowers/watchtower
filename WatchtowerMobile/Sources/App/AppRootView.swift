import SwiftUI

/// Onboarding while the phone has no link (or the Macs it holds that
/// could not be opened, with Forget), else the tabs (with the link
/// flow over them when a scan runs, and the link's notice above them).
/// Every link URL the system opens the app with lands here.
struct AppRootView: View {
    let root: AppRoot

    var body: some View {
        content
            .environment(root.env)
            .environment(root.linking)
            .opensLinkURLs(with: root)
    }

    @ViewBuilder private var content: some View {
        if root.showsOnboarding {
            Group {
                if root.showsUnopenedMacs, root.linking.phase == .idle {
                    UnopenedMacsView { await root.reopenHubs() }
                } else {
                    OnboardingView()
                }
            }
            // The tabs are gone: the removed hub's session they read can
            // close its replica now (#222).
            .onAppear { root.env.releaseRetained() }
        } else {
            TabsWithNotice(notice: root.linking.notice)
                .fullScreenCover(isPresented: Binding(
                    get: { root.linking.phase != .idle },
                    set: { presented in
                        if !presented { root.linking.dismiss() }
                    }
                )) {
                    OnboardingView()
                        .environment(root.env)
                        .environment(root.linking)
                }
        }
    }
}

/// The tabs with the link's notice above them. The notice takes its own band under the status bar and the tabs start
/// below it, so their navigation bars never draw over it (iOS 26's floating toolbar glass would cover a safe-area
/// inset; relay client Phase 3 Task 10, mockup 7.5).
struct TabsWithNotice: View {
    let notice: LinkNotice?

    var body: some View {
        VStack(spacing: 0) {
            if let notice {
                LinkNoticeBanner(notice: notice)
            }
            RootTabView()
        }
    }
}

/// The link's notice above the tabs (spec §9): stale offers a new scan;
/// "<Mac> removed this phone", a "Not sent" or a kept-recording report can
/// be closed.
struct LinkNoticeBanner: View {
    @Environment(LinkingViewModel.self) private var linking
    let notice: LinkNotice

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch notice {
            case .stale, .encryptionReScan:
                // A large control: the bordered shape is the hit area, and
                // a frame outside it would not grow it to 44 pt.
                Button("Scan") { linking.startScan() }
                    .buttonStyle(BannerButtonStyle())
            case .macOnRelay, .finishingInBackground, .needsOwner:
                Button(notice.dismissTitle ?? "") { linking.dismissNotice() }
                    .buttonStyle(BannerButtonStyle())
            case .removed, .notSent, .recordingKept, .recordingsProblem:
                Button {
                    linking.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: PhoneMetrics.minTouch, height: PhoneMetrics.minTouch)
                }
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.small)
        .background(Fill.card)
        .overlay(alignment: .bottom) { CardRowDivider() }
    }
}

/// A banner's small action (mockups' quiet button): accent label on the
/// card fill under a hairline, a 44 pt hit area.
struct BannerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        configuration.label
            .font(TypeScale.kind)
            .foregroundStyle(PhoneTone.accent.color)
            .padding(.horizontal, Spacing.medium)
            .frame(minHeight: PhoneMetrics.minTouch)
            .background(Fill.card, in: shape)
            .overlay(shape.strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
            .opacity(configuration.isPressed ? PhoneOpacity.pressed : 1)
            .contentShape(shape)
    }
}
