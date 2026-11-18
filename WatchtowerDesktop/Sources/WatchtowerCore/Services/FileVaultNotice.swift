import Foundation

/// The FileVault-off line of Privacy and Connections → Slack (#1769). Shown
/// only for a definite `.off`.
public enum FileVaultNotice {
    public static let text = "FileVault is off, so Slack data on this Mac is not encrypted at rest. "
        + "Turn it on in System Settings → Privacy & Security → FileVault."
    public static let action = "Open FileVault settings"
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?FileVault"

    public static func isShown(_ state: FileVaultState) -> Bool { state == .off }
}
