import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Mac side of the iPhone chat (spec 2026-11-15 §5, mockup 4b): the Chat
/// toggle in Settings → Mobile (`settings-mobile-phone-chat`). A phone's turn
/// in the open chat is `chat-remote-turn-live` since the unified chat (T8).
/// Synthetic data only.
@MainActor
enum IPhoneChatShotFixtures {
    static func cleanUp() {}

    static var shots: [DesignShot] {
        [
            DesignShot(name: "settings-mobile-phone-chat", size: NSSize(width: 640, height: 640)) { settingsChat() }
        ]
    }

    /// 4b: one phone on a Relay hub, its grants on, Chat among them.
    static func settingsChat() -> AnyView {
        let now = MobileSettingsShotFixtures.now
        let defaults = UserDefaults(suiteName: "WatchtowerDesktopShots.iphoneChat") ?? .standard
        let clock: () -> Date = { now }
        let model = MobileSettingsModel(cli: ParkedCLI(), defaults: defaults, now: clock)
        let phone = MobileHubCLI.Phone(
            deviceID: "AAAA0001", name: "Phone A", scope: "shared", linkedAt: now.addingTimeInterval(-21 * 86_400),
            typingAllowed: true, typingRequested: false, permissionsAllowed: true, permissionsRequested: false,
            startSessionsAllowed: true, startSessionsGranted: true, transport: "relay", chatAllowed: true
        )
        model.present(status: MobileSettingsShotFixtures.running(), phones: [phone], jobs: nil)
        return AnyView(MobileSettingsView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }
}

/// A CLI whose every call waits until it is cancelled: the shot keeps the
/// read it was shown.
private struct ParkedCLI: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
