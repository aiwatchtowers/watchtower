import AppKit
import DesignKit
import SwiftUI
@testable import WatchtowerDesktop

/// The Software Update window (`UpdateAvailableView`): a plain offer and the
/// required update (#2096) at rest, downloading and after a failed download.
/// Sample data only.
@MainActor
enum SoftwareUpdateShotFixtures {
    static var shots: [DesignShot] {
        [
            shot("update-window-available", minimum: nil),
            shot("update-window-available-categorised", minimum: nil, notes: categorisedNotes),
            shot("update-window-required", minimum: "0.30.0"),
            shot("update-window-required-downloading", minimum: "0.30.0", then: .downloading(progress: 0.4)),
            shot("update-window-required-error", minimum: "0.30.0",
                 then: .error("Download failed: The network connection was lost.")),
            shot("update-window-required-ready", minimum: "0.30.0",
                 then: .readyToInstall(appPath: URL(fileURLWithPath: "/tmp/Watchtower.app")))
        ]
    }

    private static let notes = """
    ## What's New

    ### Improvements
    - Slack sign-in moves to a safer flow.
    - Faster Inbox on large workspaces.

    ### Bug Fixes
    - The tray icon no longer flickers after sleep.
    """

    /// Notes in the categorised format `/release` writes; the window draws a
    /// badge per section.
    private static let categorisedNotes = """
    ## What's New

    ### ⚠️ Requirements
    - Needs macOS 15 or later. (Mac)

    ### ✨ New
    - Inbox folders: group threads your way. (Mac)

    ### 💅 Improved
    - Faster Inbox on large workspaces.

    ### 🔒 Security
    - Tightened how shared links are validated.

    ### 🐞 Fixed
    - The tray icon no longer flickers after sleep.

    **Full Changelog**: v0.29.0...v0.31.0
    """

    private static func shot(
        _ name: String,
        minimum: String?,
        notes: String = Self.notes,
        then state: UpdateService.UpdateState? = nil
    ) -> DesignShot {
        DesignShot(name: name, prepare: {
            let appState = AppState(workbenchDefaults: AppState.isolatedDefaults)
            let service = appState.updateService
            service.runningVersion = "0.29.0"
            service.defaults = AppState.isolatedDefaults
            service.announce = { _ in true }
            service.presentUpdateWindow = nil
            let url = URL(string: "https://example.com/Watchtower-0.31.0-arm64.zip")!
            await service.applyCheckResult(
                .found(.init(version: "0.31.0", notes: notes, downloadURL: url, gated: nil, minVersion: minimum)),
                previous: .idle, background: false
            )
            if let state { service.state = state }
            return AnyView(UpdateAvailableView().background(Surface.window).environment(appState))
        }, size: NSSize(width: 520, height: 0))
    }
}
