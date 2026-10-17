import XCTest

/// Board #592: chat start, session cleanup and the settings screens never
/// wait on the login-shell probe (`Constants.resolvedEnvironment()`, up to
/// 5 s) synchronously — on the main thread or on a pool thread. They take
/// `resolvedEnvironmentAsync()` (async sites) or
/// `resolvedEnvironmentIfReady()` (the chat's main-actor spawn).
final class LoginEnvironmentCallSiteTests: XCTestCase {
    private static let files = [
        "Services/Chat/ChatSessionClient.swift",
        "Services/SessionCleanupCenter.swift",
        "Views/Settings/JiraFeaturesSettingsView.swift",
        "Views/Settings/SlackConnectionDetail.swift",
        "Views/Settings/JiraBoardsSettingsView.swift",
        "Views/Settings/JiraUserMappingSettingsView.swift",
        "Views/Settings/SystemSettings.swift"
    ]

    func testNoBlockingLoginEnvironmentCall() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        for file in Self.files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("Constants.resolvedEnvironment()"),
                           "\(file) waits on the login-shell probe; use resolvedEnvironmentAsync()/IfReady()")
            XCTAssertTrue(text.contains("resolvedEnvironmentAsync()") || text.contains("resolvedEnvironmentIfReady()"),
                          "\(file): the scan found no environment call — wrong path?")
        }
    }
}
