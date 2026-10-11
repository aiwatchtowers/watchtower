import SwiftUI

/// Onboarding while the phone has no link, else the tabs (with the link
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
        if let failure = root.failure {
            BootFailureView(message: failure)
        } else if root.showsOnboarding {
            OnboardingView()
        } else {
            RootTabView()
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let notice = root.linking.notice {
                        LinkNoticeBanner(notice: notice)
                    }
                }
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

/// The link's notice above the tabs (spec §9): moved and stale offer a
/// new scan; a "Not sent" report can be closed.
struct LinkNoticeBanner: View {
    @Environment(LinkingViewModel.self) private var linking
    let notice: LinkNotice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text(notice.message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch notice {
            case .moved, .stale:
                Button("Scan") { linking.startScan() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            case .removed, .notSent:
                Button {
                    linking.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
