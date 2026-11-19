import Foundation

/// Every string of the Software Update window (`UpdateAvailableView`) and of
/// Settings → System → Update's offer line, including the required-update
/// copy (`UpdateService.requiredMinVersion`, #2096). Pinned by
/// `UpdateWindowCopyTests`.
package enum UpdateWindowCopy {
    /// The window's title: the offer (required or not), else the release
    /// just installed, else up to date.
    package static func title(offered: String?, installed: String?, required: Bool) -> String {
        if let offered {
            return required ? "Update required: Watchtower \(offered)" : "Watchtower \(offered) is available"
        }
        if let installed { return "What's New in Watchtower \(installed)" }
        return "Watchtower is up to date"
    }

    package static func subtitle(running: String, showingInstalled: Bool) -> String {
        showingInstalled ? "Watchtower was updated." : "You have \(running)."
    }

    /// Why the update cannot wait, in one sentence.
    package static func requiredReason(minimum: String) -> String {
        "Versions older than \(minimum) stop working with the services Watchtower connects to, "
            + "so this update cannot be postponed."
    }

    package static func settingsOffer(version: String, required: Bool) -> String {
        "Version \(version) \(required ? "required" : "available")"
    }

    package static let noNotes = "No release notes for this version."
    package static let later = "Later"
    package static let updateNow = "Update Now"
    package static let downloading = "Downloading..."
    package static let readyToInstall = "Ready to install"
    package static let installAndRestart = "Install & Restart"
    package static let installing = "Installing update..."
    package static let restarting = "Restarting Watchtower..."
    package static let restartRequired = "Update installed — restart Watchtower to finish"
    package static let restartNow = "Restart Now"
    package static let errorTitle = "Update error"
    package static let close = "Close"
    package static let retry = "Retry"
    package static let checkAgain = "Check Again"
    package static let quit = "Quit Watchtower"
}
