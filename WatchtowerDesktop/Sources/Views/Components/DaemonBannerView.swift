import SwiftUI
import WatchtowerCore

/// The app-wide daemon banner above every tab (`AppState.daemonBanner`):
/// "Watchtower isn't running" with Start and Dismiss, or a failed start's
/// reason with Retry, Open Logs and Dismiss. Values and closures only, for ViewInspector.
struct DaemonBannerView: View {
    let banner: DaemonBanner
    let onStart: () -> Void
    let onOpenLogs: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            switch banner {
            case .stopped:
                Text("Watchtower isn't running, so nothing new arrives.").font(.callout).lineLimit(2)
                Spacer()
                Button("Start", action: onStart)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
            case .failed(let reason):
                Text(reason).font(.callout).lineLimit(2)
                Spacer()
                Button("Retry", action: onStart)
                Button("Open Logs", action: onOpenLogs)
                    .buttonStyle(.borderless)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
