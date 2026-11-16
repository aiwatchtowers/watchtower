import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// The tray menu with Pause Sync (mobile Inbox spec §3, mockup §8 "Tray
/// menu, running" and "paused"): `TrayMenuContent` laid out as the menu's
/// items, since a native menu does not render off screen.
@MainActor
enum TrayPauseShotFixtures {
    static func menu(paused: Bool) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: Spacing.small) {
            TrayMenuContent(
                isRunning: true, syncPaused: paused, syncProgress: nil, daemonError: nil, cliStoreError: nil,
                voicesPendingCount: 0, updateVersion: nil, updateAction: {}, syncNowAction: {},
                quickCaptureAction: {}, voicesAction: {}, reviewVoicesAction: {}, trainVoicesAction: {},
                openAction: {}, settingsAction: {})
        }
        .buttonStyle(.borderless)
        .padding(Spacing.medium)
        .frame(width: 260, alignment: .leading)
        .background(Surface.window, in: RoundedRectangle(cornerRadius: Radius.container))
        .overlay(RoundedRectangle(cornerRadius: Radius.container).strokeBorder(Fill.hover, lineWidth: Stroke.hairline))
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }
}
